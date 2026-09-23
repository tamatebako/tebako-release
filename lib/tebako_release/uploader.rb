# frozen_string_literal: true

# Copyright (c) 2025-2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

require "octokit"
require "digest"
require "json"
require "pathname"
require "tmpdir"
require "yaml"

module TebakoRelease
  # Upload release manager for the tebako factory build workflows — the
  # ONE implementation every runtime factory consumes (spec 00 §10: the
  # machinery has exactly one owner; factories declare identity + policy
  # through TebakoRelease.configure and never carry a copy).
  #
  # Lifted from tebako-runtime-ruby's scripts/upload_release.rb, where
  # every convergence/retry rule below was earned against a named incident
  # (the comments carry the dates); the factory-specific seams — repo,
  # language version key/grammar, capability gates, DLL naming — flow
  # through the Config/Adapter.
  class Uploader # rubocop:disable Metrics/ClassLength
    # Named error (spec 00: named errors, never silent fallbacks): a release
    # asset's deletion did not stop the name from being listed within the
    # propagation deadline — the name stays 422-blocked server-side.
    class DeletionPropagationTimeout < StandardError; end

    # The rate-limit ride-out has a bound: two full hourly windows waited in
    # one process means something is systemically wrong — give up loudly
    # instead of blocking the runner forever.
    class RateLimitBudgetExhausted < StandardError; end

    # The era-2 release card (spec 18 C2): every runtime package carries a
    # builder-emitted `<package>.contract.yaml` sidecar (contract_era,
    # image_layout, mount_root, built_from) that manifest_entry folds into
    # the manifest.json entry. A package without it — or one declaring an
    # era this pipeline does not speak — is refused by name (fail closed;
    # S11/S16): a manifest entry never goes out under-declared.
    CONTRACT_SIDECAR_SUFFIX = ".contract.yaml"
    CONTRACT_ERA = 2

    # Per-asset metadata, write-once, no shared name (the de-rendezvous —
    # spec 13 §2a): the release's asset listing IS the package index.
    # Every payload asset ships with a `<asset>.sha256` sidecar in the
    # store's trust-anchor shape (spec 00 §8: "<sha256>  <filename>\n"),
    # and every package with a `<stem>.manifest.json` shard carrying
    # exactly its manifest entry (on signing-enabled lines also declaring
    # each artifact's `signature` block — spec 09 §5). The leg that built
    # a package uploads its own assets and metadata and nothing else — the
    # monolithic manifest.json / SHA256SUMS.txt are NEVER release assets
    # (they are consumer-side derivations from the shards + the asset
    # listing), the release notes are written once at creation, and no
    # invocation ever read-modify-writes a name another leg owns (the
    # 2026-08-29 partial-merge + 422-wedge incident; the 2026-09-12
    # finalize wedge — same physics: aggregation forces mutation, mutation
    # forces delete-then-replace, replace is the wedge). BACKFILL_METADATA
    # is the one-shot migration that writes shards/sidecars onto a
    # pre-shard release.
    SHARD_SUFFIX = ".manifest.json"
    SIDECAR_SUFFIX = ".sha256"

    # Upload-sized request timeouts: the release assets are 50–200 MB and
    # the runner→uploads.github.com link has written slower than the
    # 60 s Faraday default twice in one publish day (the v0.16.3 gnu/musl
    # retries). Ten minutes of write patience; open/read ride along. The
    # retry budget above rides OUT the failures; this makes them rare.
    CLIENT_CONNECTION_OPTIONS = {
      request: { open_timeout: 30, timeout: 600, write_timeout: 600 }
    }.freeze

    def initialize(client: nil, config: nil)
      @config = config || TebakoRelease.config
      validate_environment
      # A fresh copy per client: Octokit/Faraday mutate the request options
      # mid-request ("can't modify frozen Hash" killed the musl publish).
      @client = client || Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"), auto_paginate: true,
                                              connection_options: { request: CLIENT_CONNECTION_OPTIONS[:request].dup })
      @version = ENV.fetch("TEBAKO_VERSION")
      @tag = "v#{@version}"
      @release_title = "#{@config.title_prefix} #{@tag}"
      @contract_version = load_contract_version
    end

    # Fail closed: a release whose manifest cannot name the runtime contract
    # version never ships (the bootstrap negotiates on this field).
    def load_contract_version
      data = YAML.load_file(@config.contract_yml)
      version = data.is_a?(Hash) ? data["contract_version"] : nil
      return version if version.is_a?(Integer) && version.positive?

      raise "#{@config.contract_yml} does not define a positive integer contract_version"
    end

    # One manifest entry per runtime PACKAGE (the executable). A sibling
    # filesystem image (<package>.tfs, item 30) is folded into the
    # package's entry as an additive `image` key -- top-level entries stay
    # one-per-package so existing consumers (which match on the language
    # version / platform / filename) are unaffected, and a .tfs file never
    # becomes a top-level entry of its own. The additive `contract_version`
    # key follows the same compat rule, and so does the windows runtime
    # DLL (<package>.dll) folded as `dll` with the PE name the store entry
    # materializes (`install_as`).
    def build_manifest_entries(packages) # rubocop:disable Metrics/AbcSize
      executables, images, dlls = partition_packages(packages)
      executables.sort_by { |package| package.basename.to_s }.map do |package|
        image = images.find { |candidate| candidate.basename.to_s == image_name_for(package) }
        dll = dlls.find { |candidate| candidate.basename.to_s == dll_name_for(package) }
        manifest_entry(package, image, dll)
      end
    end

    # Three-way split: executables (manifest entries of their own), the
    # .tfs filesystem images and the windows runtime DLLs (both facets of
    # their package's entry). A DLL never parses as an executable.
    def partition_packages(packages)
      dlls, rest = packages.partition { |package| dll_file?(package) }
      images, executables = rest.partition { |package| image_file?(package) }
      [executables, images, dlls]
    end

    # The byte-immutable keep machinery's previous-entry source,
    # shards-first (spec 13 §2a): the release's per-package shards ARE the
    # authority, and this invocation reads only the shards THIS leg's
    # expected matrix can name (an unscoped invocation — no matrix — reads
    # them all). A stem no shard covers falls back to the monolithic
    # manifest.json loudly (the pre-de-rendezvous migration window) —
    # never an error: a stem neither source covers simply has no previous
    # entry, and a first publish is exactly that.
    def previous_manifest_entries # rubocop:disable Metrics/MethodLength
      @previous_manifest_entries ||= begin
        release = find_release
        if release.nil?
          []
        else
          entries = relevant_shard_entries(release)
          entries.concat(monolith_fallback_entries(covered_stems(entries)))
          entries
        end
      rescue StandardError => e
        puts "::warning::could not read the release's previous entries (#{e.class}: #{e.message}) — merging nothing"
        []
      end
    end

    # This leg's shards, downloaded and symbolized. Scoped to the expected
    # matrix BEFORE downloading (the shard's stem is in its asset name);
    # an invocation without a matrix (ad-hoc) reads every shard.
    def relevant_shard_entries(release)
      assets = shard_assets(release)
      expected = expected_package_names
      unless expected.empty?
        assets = assets.select do |asset|
          expected.include?(asset.name.delete_suffix(SHARD_SUFFIX))
        end
      end
      assets.map { |asset| download_shard_entry(asset) }
    end

    # The migration window: a package stem no shard covers can still have
    # its previous entry in the monolithic manifest.json (the pre-shard
    # index — never written anymore, immutable forever). Scoped to this
    # invocation's expected matrix; an invocation WITHOUT a matrix covers
    # every shard-less monolith stem (the pre-de-rendezvous behavior).
    # Loud when used, never an error.
    def monolith_fallback_entries(shard_covered) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      monolith = previous_monolith_entries.reject do |entry|
        shard_covered.include?(package_stem(entry[:filename].to_s))
      end
      return [] if monolith.empty?

      expected = expected_package_names
      found = expected.empty? ? monolith : monolith.select { |e| expected.include?(package_stem(e[:filename].to_s)) }
      return [] if found.empty?

      puts "::warning::#{found.size} package(s) carry no #{SHARD_SUFFIX} shard — reading their previous entries from " \
           "the monolithic manifest.json (the pre-de-rendezvous migration window): " \
           "#{found.map { |entry| entry[:filename] }.sort.join(", ")}"
      found
    end

    # The release's monolithic manifest.json, symbolized (entry[:image]
    # included), [] when absent/unreadable (a named warning, never a
    # crash — the completeness gate is the arbiter). The monolith is a
    # PRE-de-rendezvous artifact: two readers remain — the migration-window
    # fallback above and the BACKFILL_METADATA repair pass (its shard
    # source). Nothing ever writes it again (spec 13 §2a).
    def previous_monolith_entries
      @previous_monolith_entries ||= begin
        data = read_previous_manifest
        data.is_a?(Array) ? data.map { |entry| deep_symbolize(entry) } : []
      rescue StandardError => e
        puts "::warning::could not read the previous manifest.json (#{e.class}: #{e.message}) — merging nothing"
        []
      end
    end

    # The release's existing manifest.json as parsed JSON; nil when the tag
    # has no release or the release carries no manifest asset.
    def read_previous_manifest
      release = find_release
      asset = release && find_asset(release, "manifest.json")
      asset && with_transient_retries { download_asset_json(asset) }
    end

    def deep_symbolize(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = deep_symbolize(v) }
      when Array then value.map { |item| deep_symbolize(item) }
      else value
      end
    end

    def download_asset_json(asset)
      JSON.parse(with_transient_retries { @client.get(asset.browser_download_url) }.to_s)
    end

    def expected_package_names # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      env_json, version_json = ENV.values_at("EXPECTED_ENV_MATRIX", @config.version_matrix_env)
      return [] unless env_json && version_json

      versions = @config.adapter.expected_versions(JSON.parse(version_json))
      JSON.parse(env_json).product(versions).filter_map do |env, version|
        next unless @config.adapter.capable_pair?(env["os"], env["arch"], version)

        platform = Platform.host_id_for(env["os"], env["arch"])
        "tebako-runtime-#{@version}-#{version}-#{platform}"
      end
    rescue JSON::ParserError => e
      puts "::warning::Could not compute expected package list: #{e.message}"
      []
    end

    # Metadata files always REPLACE on drift (payload assets never do):
    # unlike payload assets (byte-immutable per name), every metadata file
    # is DERIVABLE — a pure function of the packages' served bytes — so a
    # same-named metadata asset with different bytes is debris from an
    # interrupted publish, never a keep. Already-current metadata (the
    # listing's digest matches) is never re-uploaded.
    #
    # The metadata CONVERGENCE loop (2026-08-03, proven live): the release
    # backend's mutation propagation flaps over minutes — a deleted name
    # 422'd re-uploads for >25 min while replicas disagreed about the
    # listing. Each cycle: read-first (served bytes already ours → done),
    # delete when listed, wait for absence, upload with the short budget
    # (422s resolve by content inside perform_upload), then verify what the
    # edge serves. The loop repeats until the edge converges or the budget
    # runs out — a metadata rewrite never dies on the first bad cycle.
    # The convergence cycle sleeps, ~46 min of patience. Tonight's backend
    # (2026-08-03) blocked a deleted name's re-upload for 4.5+ HOURS.
    # Since the de-rendezvous (spec 13 §2a) a leg rewrites only
    # its OWN packages' shards/sidecars — every name it touches is one it
    # owns, so a convergence grind can never rendezvous with another leg;
    # an incident night is an incident night, and the legs run concurrently.
    METADATA_CONVERGENCE_DELAYS = [5, 15, 30, 60, 120, 240, 480, 600, 600, 600].freeze

    def force_upload(release, file, delays: METADATA_CONVERGENCE_DELAYS)
      filename = file.basename.to_s
      sha = Digest::SHA256.file(file).hexdigest
      converged = false
      delays.each do |pause|
        converged = metadata_converged?(release, file, filename, sha)
        break if converged

        puts "#{filename} has not converged on the release yet; cycling in #{pause}s"
        sleep pause
      end
      raise "could not converge #{filename} on the release within the metadata budget" unless converged
    end

    # One convergence cycle: read-first (the edge already serves our bytes
    # → done), replace when listed, upload with the short budget (422s
    # resolve by content inside perform_upload), then verify what the edge
    # serves. true when the release serves our bytes.
    def metadata_converged?(release, file, filename, sha)
      return true if served_content_matches?(release, filename, sha)

      remove_existing_asset(release, filename) if find_asset(release, filename)
      begin
        perform_upload(release, file, filename, delays: [5, 10, 20])
      rescue Octokit::UnprocessableEntity
        # the name is still taken server-side; the next cycle re-reads
      end
      served_content_matches?(release, filename, sha)
    end

    # Does the release already hold these exact bytes? The listing's
    # server-computed digest is the authority (never edge-lagged); the
    # download-edge read is the fallback for digest-less listings (an
    # unreadable edge proves nothing → false → the mutation path runs).
    def served_content_matches?(release, filename, sha)
      digest = listed_digest(release, filename)
      unless digest.nil?
        matched = digest == sha
        if matched
          puts "#{filename} is already current on the release — canonical metadata unchanged — skipping refresh"
        end
        return matched
      end

      edge_content_matches?(filename, sha)
    end

    # The download-edge fallback for digest-less listings: an unreadable
    # edge proves nothing → false → the mutation path runs.
    def edge_content_matches?(filename, sha)
      served = safely_served_content(filename)
      return false if served.nil? || served.empty?

      if Digest::SHA256.hexdigest(served) == sha
        puts "#{filename} is already current on the release — canonical metadata unchanged — skipping refresh"
        true
      else
        false
      end
    end

    # The canonical download URL's currently-served bytes; nil when the edge
    # has no such asset. The download edge lags behind the API on mutations,
    # so this is a hint, never an authority — matching bytes are always a
    # correct accept (content is content); absent/stale bytes only mean
    # "take the mutation path".
    def served_content(filename)
      with_transient_retries { @client.get(download_url(filename)) }.to_s
    rescue Octokit::NotFound
      nil
    end

    # served_content that never raises: an unreadable edge just means the
    # mutation path runs.
    def safely_served_content(filename)
      served_content(filename)
    rescue StandardError
      nil
    end

    def download_url(filename)
      "https://github.com/#{@config.repo}/releases/download/#{@tag}/#{filename}"
    end

    # The release notes are written ONCE at release creation and never
    # rewritten (spec 13 §2a — no shared mutable name; an asset-derived
    # body would be the retired finalize pass's read-modify-write in
    # disguise). They point at the per-package shards + sidecars (the
    # authority), the consumer-side index derivation, and the in-repo
    # registry — nothing in them enumerates the release's assets.
    def release_notes
      <<~BODY
        ## #{@config.title_prefix}

        Release version: #{@tag}

        Every runtime package (the interpreter executable + its `.tfs` env image + the
        windows runtime DLL) ships with its own metadata, written once by the build leg that
        produced it (spec 13 §2a): the `<asset>.sha256` sidecar next to every asset is the
        trust anchor (the tebako store's own sidecar shape, spec 00 §8), and the
        `<package>.manifest.json` shard next to every package carries exactly its
        release-index entry. On signing-enabled lines every served name also carries its
        own detached `.asc` (spec 09 §5).

        There is no monolithic `manifest.json` / `SHA256SUMS.txt` release asset: both are
        derivable conveniences, computed consumer-side from the shards + the asset listing.
        The machine-readable resolution index is the publishing repo's
        `tpkg-registry.yaml` (spec 04 §2).
      BODY
    end

    # The release is created by the FIRST leg that finds it missing — the
    # matrix legs of one publish run race here (spec 13 §2a's
    # de-rendezvous: no leg waits on another). The loser's create 422s on
    # the taken tag; it polls for the winner's release to become visible
    # and rides it. Creation is write-once, never a wedge.
    RELEASE_CREATE_POLL_DELAYS = [5, 5, 5, 5, 5, 5].freeze

    def get_or_create_release # rubocop:disable Naming/AccessorMethodName
      puts "Looking for release with tag: #{@tag}"
      @client.release_for_tag(@config.repo, @tag)
    rescue Octokit::NotFound
      create_release_race_safe
    end

    # A rescue clause's own exceptions never re-enter the sibling rescues —
    # the create's 422 handling lives in its own method.
    def create_release_race_safe # rubocop:disable Metrics/MethodLength
      puts "Creating new release for tag: #{@tag}"
      @client.create_release(@config.repo, @tag,
                             name: @release_title,
                             body: release_notes)
    rescue Octokit::UnprocessableEntity
      # A concurrent leg won the create. Poll for its release to become
      # visible, then ride it — never re-attempt the create.
      RELEASE_CREATE_POLL_DELAYS.each do |pause|
        sleep pause
        release = find_release
        return release if release
      end
      raise "the release for #{@tag} rejected the create (tag already exists) but never became visible — " \
            "another leg's creation is wedged; re-run this leg"
    end

    # The read-only lookup (the previous-entry reads + the audit read the
    # existing release): nil when the tag has no release, never creates one.
    def find_release
      with_transient_retries { @client.release_for_tag(@config.repo, @tag) }
    rescue Octokit::NotFound
      nil
    end

    def manifest_entry(package, image = nil, dll = nil) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      runtime_version, platform = parse_package_filename(package.basename.to_s)
      contract = contract_sidecar(package)
      filename = package.basename.to_s
      sha256 = Digest::SHA256.file(package).hexdigest
      # The idempotent upload skip reads these (same name + same sha = kept).
      current_shas[filename] = sha256
      current_shas[image_name_for(package)] = Digest::SHA256.file(image).hexdigest if image
      current_shas[dll_name_for(package)] = Digest::SHA256.file(dll).hexdigest if dll
      {
        tebako_version: @version,
        contract_era: contract.fetch("contract_era"),
        contract_version: @contract_version,
        @config.version_key => runtime_version,
        platform: platform,
        filename: filename,
        sha256: sha256,
        size_bytes: package.size,
        mount_root: contract.fetch("mount_root"),
        image_layout: contract.fetch("image_layout"),
        built_from: contract.fetch("built_from")
      }.tap do |entry|
        # The additive abi line (spec 05 §5): the runtime's own platform
        # string, emitted by build_runtime as <package>.abi. Consumers that
        # predate the key ignore it (the compat window).
        sidecar = Pathname.new("#{package.sub(/\.exe\z/, "")}.abi")
        entry[:abi] = sidecar.read.strip if sidecar.file?
        # The additive capabilities line (versions catalog plan 04): display
        # metadata owned by the factory that compiled the runtime — never a
        # selector axis. Sourced from the factory's adapter (the same truth
        # its boot smoke asserts), so manifest and smoke can never disagree.
        entry[:capabilities] = @config.adapter.capabilities(version: runtime_version, platform_id: platform)
        entry[:image] = image_entry(image) if image
        entry[:dll] = dll_entry(dll, runtime_version, platform) if dll
        declare_signatures(entry)
      end
    end

    # Spec 13 §2a / spec 09 §5: on signing-enabled lines every artifact the
    # entry names declares its own `signature` block — {keyid, asc}: the
    # signer's 16-lowercase-hex PRIMARY keyid (spec 09 §9) and the exact
    # `.asc` asset name within this release, declared by the factory and
    # flowed verbatim by consumers (never synthesized — the same SSOT rule
    # as `filename`). A declaration the in-leg sign pass does not fulfill
    # fails the leg (the signer asserts coverage), never ships.
    def declare_signatures(entry)
      return unless signing_enabled?

      keyid = signing_keyid
      entry[:signature] = { keyid: keyid, asc: "#{entry[:filename]}.asc" }
      %i[image dll].each do |facet|
        block = entry[facet]
        block[:signature] = { keyid: keyid, asc: "#{block[:filename]}.asc" } if block
      end
    end

    # The signing arm (spec 09 §5's house style): TEBAKO_RELEASE_SIGNING_ENABLED=true
    # marks the line signing-enabled — the publish declares the signature
    # blocks and the leg's sign pass produces the `.asc` assets.
    def signing_enabled?
      ENV["TEBAKO_RELEASE_SIGNING_ENABLED"] == "true"
    end

    # The declared keyid: the signer's PRIMARY keyid, 16 lowercase hex —
    # validated, never guessed (a malformed keyid in a shard is an invalid
    # signing state shipped).
    def signing_keyid
      keyid = ENV.fetch("TEBAKO_RELEASE_SIGNING_KEYID", "").strip
      return keyid if keyid.match?(/\A[0-9a-f]{16}\z/)

      raise "TEBAKO_RELEASE_SIGNING_KEYID must be the signer's 16-lowercase-hex PRIMARY keyid " \
            "(spec 09 §9), got #{keyid.inspect}"
    end

    def current_shas
      @current_shas ||= {}
    end

    # The package's builder-emitted contract sidecar (the era-2 release
    # card's provenance half), fail-closed: a missing file, missing keys,
    # or a declared era this pipeline does not speak are named refusals —
    # never a silently under-declared manifest entry (spec 18 C2/S11/S16).
    def contract_sidecar(package) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      path = Pathname.new("#{package.sub(/\.exe\z/, "")}#{CONTRACT_SIDECAR_SUFFIX}")
      unless path.file?
        raise "runtime package #{package.basename} carries no #{CONTRACT_SIDECAR_SUFFIX} contract sidecar — " \
              "it was built by a pre-era factory; rebuild it with the current #{@config.repo} (spec 18 C2)"
      end

      data = YAML.load_file(path)
      data = nil unless data.is_a?(Hash)
      missing = %w[contract_era mount_root image_layout built_from] - (data || {}).keys
      unless missing.empty?
        raise "contract sidecar #{path.basename} is missing #{missing.join(", ")} — " \
              "rebuild the package with the current #{@config.repo} (spec 18 C2)"
      end

      era = data.fetch("contract_era")
      unless era == CONTRACT_ERA
        raise "contract sidecar #{path.basename} declares contract_era #{era.inspect} but this release pipeline " \
              "speaks #{CONTRACT_ERA} — upgrade #{@config.repo}"
      end

      data
    end

    # The additive image metadata: name, sha256, size (consumers ignoring the
    # `image` key keep working; item 30's compat rule).
    def image_entry(image)
      {
        filename: image.basename.to_s,
        sha256: Digest::SHA256.file(image).hexdigest,
        size_bytes: image.size
      }
    end

    # The additive runtime-DLL metadata (windows): the asset rides under
    # the package's unique name; `install_as` is the PE name the store
    # entry materializes next to the exe so the exe's imports resolve (the
    # single owner of that name is the factory's version model, behind the
    # adapter — consumers ignore the `dll` key in the compat window).
    def dll_entry(dll, runtime_version, host_id)
      {
        filename: dll.basename.to_s,
        install_as: @config.adapter.dll_install_name(runtime_version, host_id),
        sha256: Digest::SHA256.file(dll).hexdigest,
        size_bytes: dll.size
      }
    end

    def image_file?(package)
      package.basename.to_s.end_with?(".tfs")
    end

    def dll_file?(package)
      package.basename.to_s.end_with?(".dll")
    end

    def image_name_for(package)
      "#{package.basename.to_s.sub(/\.exe\z/, "")}.tfs"
    end

    def dll_name_for(package)
      "#{package.basename.to_s.sub(/\.exe\z/, "")}.dll"
    end

    def parse_package_filename(filename)
      grammar = @config.adapter.version_grammar_source
      match = /\Atebako-runtime-#{Regexp.escape(@version)}-(#{grammar})-(.+?)(?:\.exe)?\z/.match(filename)
      unless match
        puts "::warning::Cannot infer version/platform from package filename: #{filename}"
        return [nil, nil]
      end

      [match[1], match[2]]
    end

    # The upload retry budget: escalating delays, ~4.5 minutes of patience.
    # Flat 5 s retries cannot ride out the release backend's propagation
    # lag (observed 2026-08-03: the upload validator 422d a name for
    # minutes after the delete committed on the primary).
    UPLOAD_RETRY_DELAYS = [5, 10, 20, 40, 80, 120].freeze

    # The per-asset wall-clock cap: one wedged asset must never consume the
    # whole job. On the 2026-08-20 publish a single wedged exe/.tfs pair
    # burned the full 150-minute step timeout across the per-platform
    # invocations — every retry cycle's delete-wait and backoff re-armed
    # with no overall bound. The cap is checked BETWEEN attempts: an
    # in-flight POST (a healthy 200 MB upload can legitimately write for
    # minutes against the 600 s request timeout) is never cut off.
    PER_ASSET_UPLOAD_BUDGET = 300

    def perform_upload(release, package, filename, delays: UPLOAD_RETRY_DELAYS.dup, # rubocop:disable Metrics/MethodLength
                       budget: PER_ASSET_UPLOAD_BUDGET)
      deadline = monotonic_now + budget
      loop do
        puts "Uploading #{filename}"
        begin
          upload_once(release, package, filename)
          return
        rescue Octokit::UnprocessableEntity, *TRANSIENT_ERRORS => e
          # A 422 means the asset name is taken. Two distinct causes: the
          # eventual-consistency race after a same-name delete (the
          # content-changed recovery paths), or a previous attempt's
          # POST that timed out but LANDED server-side — the retry then 422s
          # (the v0.16.1 publish died on exactly this). Resolve by content,
          # first: a name-only check would misread the delete-race, where
          # the STALE asset is still listed.
          return if landed_duplicate?(release, filename, package, e)

          # A 422 whose landed bytes DISAGREE with ours is a partial (a
          # timed-out POST that landed incomplete) or a stale same-name
          # asset: retrying the POST blindly can never win — delete the
          # conflict so the retry lands (the v0.16.3 publish exhausted its
          # budget exactly here). The delete's listing-propagation lag rides
          # the retry budget below.
          delete_conflicting_asset(release, filename) if e.is_a?(Octokit::UnprocessableEntity)

          delay = delays.shift
          raise if delay.nil?

          if monotonic_now >= deadline
            puts "#{filename}: the per-asset upload budget (#{budget}s) is exhausted — " \
                 "the replace cannot land tonight"
            raise
          end

          backoff(e, filename, delay)
        end
      end
    end

    # Remove the same-name asset whose content disagrees with ours (a
    # partial upload or a stale build). No listed asset means our own delete
    # already left the listing — yet the POST 422'd already_exists: the name
    # stays blocked on the upload validator's lagging replica past the
    # listing's truth (the 0.16.8 wedge — the name freed ~15 s after the
    # absence showed). Re-run the delete+poll cycle once more: the delete is
    # a no-op and the poll is trivially green, so the operative half is the
    # post-absence grace — then the retry's POST lands.
    def delete_conflicting_asset(release, filename)
      asset = find_asset(release, filename)
      if asset.nil?
        name_release_grace(filename)
        return
      end

      puts "#{filename}: the landed asset's content disagrees — deleting the partial/stale asset before the retry"
      with_transient_retries { @client.delete_release_asset(asset.id) }
      drop_asset_from_memo(asset.id) # the deleted asset leaves the listing
      # The name stays 422-blocked until the delete propagates — poll for
      # the absence so the retry's POST actually lands (the v0.16.3 gnu
      # publish looped blind POSTs into the held name).
      wait_for_absence_best_effort(release, filename, asset)
    end

    # Did an earlier attempt's POST land despite the error? Accepts (loudly)
    # only when the landed asset's content matches ours byte-for-byte.
    def landed_duplicate?(release, filename, package, error)
      return false unless error.is_a?(Octokit::UnprocessableEntity)
      return false unless landed_with_same_content?(release, filename, package)

      puts "#{filename} is already on the release with matching content (a timed-out attempt landed it)"
      true
    end

    # Truthful by content: the landed asset's sha256 vs the local file's.
    # The API listing's digest is the authority (the download edge lags
    # behind mutations — it served a deleted partial for hours on the
    # v0.16.3 publish, and a stale read must never delete a good upload);
    # the byte read is only the pre-digest fallback. Anything unreadable
    # proves nothing: treat as not landed and keep backing off.
    def landed_with_same_content?(release, filename, package)
      sha = Digest::SHA256.file(package).hexdigest
      digest = listed_digest(release, filename)
      return digest == sha unless digest.nil?

      landed = landed_content(release, filename)
      return false if landed.nil? || landed.empty?

      Digest::SHA256.hexdigest(landed) == sha
    rescue StandardError
      false
    end

    # The API listing's server-computed sha256 (the asset `digest` field) —
    # the authority that never lags the way the download edge does. nil
    # when the listing carries no digest (a pre-digest API or a fake).
    def listed_digest(release, filename)
      asset = find_asset(release, filename)
      digest = asset.respond_to?(:digest) ? asset.digest : nil
      digest&.start_with?("sha256:") ? digest.delete_prefix("sha256:") : nil
    end

    def landed_content(release, filename)
      asset = find_asset(release, filename)
      return with_transient_retries { @client.get(asset.browser_download_url) }.to_s if asset

      served_content(filename)
    rescue Octokit::NotFound
      served_content(filename)
    end

    def backoff(error, filename, delay)
      puts "#{error.class} uploading #{filename}; retrying in #{delay}s"
      sleep delay
    end

    # The POST rides rate-limit windows out like every other call; its
    # TRANSIENT retries (transport drops included — octokit's internal
    # release GET inside upload_asset died to a stale-keep-alive SSL EOF on
    # 2026-08-30) stay with perform_upload (escalating delays, 422-by-content
    # resolution, the per-asset budget) — ONE retry layer, not two.
    def upload_once(release, package, filename)
      asset = with_rate_limit_rideout do
        @client.upload_asset(release.url, package.to_s,
                             content_type: "application/octet-stream",
                             name: filename)
      end
      record_asset_upload(asset) # the landed asset joins the listing
    end

    def process_release
      return audit_release if audit_only?
      return backfill_release if backfill_only?

      release = get_or_create_release
      puts "Working with release ID: #{release.id}"

      packages = validate_packages_directory
      report_missing_packages(packages)
      # Entries BEFORE uploads: the sha256s they compute feed the idempotent
      # upload skip (same name + same sha = no re-upload). This leg's
      # entries only — nothing merges.
      entries = build_manifest_entries(packages)
      publish_release(release, packages, entries)
      # The leg signs AFTER its own publish (the .asc assets land in the
      # same leg — spec 13 §2a), so the publish-time gate cannot require
      # them; the coordinator's release-job audit does.
      verify_completeness(release)
    end

    # AUDIT_ONLY (the coordinator's release job / a publish dry run):
    # strictly read-only — finds the release (never creates one), needs no
    # local packages, uploads nothing, touches no notes; the release's
    # assets are verified against the expected matrix. The release IS the
    # truth. On signing-enabled lines the audit also requires every served
    # name's `.asc` (spec 09 §5's no-fold rule).
    def audit_release
      release = find_release
      raise "AUDIT: no release found for tag #{@tag} — nothing to audit" unless release

      puts "Working with release ID: #{release.id} (AUDIT mode: no uploads, no notes)"
      verify_completeness(release, require_signatures: signing_enabled?)
      nil
    end

    # A leg's publish writes ONLY names this leg owns (the de-rendezvous —
    # spec 13 §2a): the payload assets (byte-immutable per name,
    # absolutely) and each package's own metadata — its
    # `<asset>.sha256` sidecars and its `<stem>.manifest.json` shard. No
    # shared file exists: the monoliths are consumer-side derivations and
    # the release notes are written once at creation.
    def publish_release(release, packages, entries)
      packages.each { |package| upload_package(release, package) }
      entries.each { |entry| ensure_package_metadata(release, entry) }
      print_settled_summary
    end

    # The package's metadata assets, byte-truthful for the SERVED bytes: a
    # settled package (the byte-immutable keep, or a wedged recovery
    # replace) publishes the PREVIOUS entry's shard and sidecars — the
    # metadata describes what the release serves, never the fresh bytes
    # that did not land.
    def ensure_package_metadata(release, entry)
      effective = effective_entry(entry)
      ensure_metadata_asset(release, shard_name_for(effective), "#{JSON.pretty_generate(effective)}\n")
      metadata_assets(effective).each do |name, sha|
        ensure_metadata_asset(release, "#{name}#{SIDECAR_SUFFIX}", "#{sha}  #{name}\n")
      end
    end

    # The asset name -> sha256 pairs a package's metadata covers: the exe,
    # its .tfs image and its .dll facet.
    def metadata_assets(entry)
      { entry[:filename] => entry[:sha256] }
        .merge(entry[:image] ? { entry[:image][:filename] => entry[:image][:sha256] } : {})
        .merge(entry[:dll] ? { entry[:dll][:filename] => entry[:dll][:sha256] } : {})
    end

    def shard_name_for(entry)
      "#{package_stem(entry[:filename])}#{SHARD_SUFFIX}"
    end

    # A settled package (any of its assets kept their previous bytes) speaks
    # with the previous entry's voice; a never-published settle has nothing
    # truthful to keep and never reaches here (upload_package re-raised).
    def effective_entry(entry)
      names = [entry[:filename], entry.dig(:image, :filename), entry.dig(:dll, :filename)].compact
      return entry unless names.any? { |name| settled?(name) }

      previous_entry_for(entry[:filename]) || entry
    end

    # One metadata asset, converged: already-current bytes (the listing's
    # digest matches) never re-upload; drift replaces through the
    # convergence loop. Metadata uploads are tiny — the scratch file only
    # exists to give force_upload a basename.
    def ensure_metadata_asset(release, name, content)
      if listed_digest(release, name) == Digest::SHA256.hexdigest(content)
        puts "#{name} is already current on the release — skipping"
        return
      end

      Dir.mktmpdir do |dir|
        file = Pathname.new(dir).join(name).tap { |path| path.write(content) }
        force_upload(release, file)
      end
    end

    def audit_only?
      ENV["AUDIT_ONLY"] == "true"
    end

    def backfill_only?
      ENV["BACKFILL_METADATA"] == "true"
    end

    def shard_assets(release)
      all_assets(release).select { |asset| asset.name.end_with?(SHARD_SUFFIX) }
    end

    def download_shard_entry(asset)
      deep_symbolize(JSON.parse(with_transient_retries { @client.get(asset.browser_download_url) }.to_s))
    end

    # The package stems a set of entries covers (exe + .tfs/.dll facets).
    def covered_stems(entries)
      entries.flat_map { |entry| metadata_assets(entry).keys }
             .map { |name| package_stem(name) }.uniq
    end

    # BACKFILL_METADATA=true — the one-shot migration / repair pass for a
    # release published before per-asset metadata: every listed payload
    # asset gets its sidecar (the listing's server-computed digest is the
    # served bytes' truth; the monolith's recorded sha is the digest-less
    # fallback, and a disagreement is named loudly) and every package its
    # shard (synthesized from the monolithic manifest.json — the only other
    # place the non-derivable fields live). It never touches a monolith or
    # the notes (spec 13 §2a: nothing derives them server-side anymore).
    def backfill_release
      release = find_release
      raise "BACKFILL: no release found for tag #{@tag}" unless release

      entries = previous_monolith_entries
      raise "BACKFILL needs the release's monolithic manifest.json as the shard source — none found" if entries.empty?

      backfill_sidecars(release, entries)
      backfill_shards(release, entries)
    end

    def backfill_sidecars(release, entries)
      all_assets(release).map(&:name)
                         .select { |name| name.start_with?("tebako-runtime-") }
                         .reject { |name| name.end_with?(SIDECAR_SUFFIX, SHARD_SUFFIX) }
                         .each { |name| backfill_sidecar(release, entries, name) }
    end

    def backfill_sidecar(release, entries, name)
      return if find_asset(release, "#{name}#{SIDECAR_SUFFIX}")

      entry = previous_entry_covering_in(entries, name)
      raise "BACKFILL: no manifest.json entry covers #{name}" unless entry

      sha = backfilled_sha(release, entry, name)
      ensure_metadata_asset(release, "#{name}#{SIDECAR_SUFFIX}", "#{sha}  #{name}\n")
    end

    # The sha a backfilled sidecar carries: the listing's server-computed
    # digest (the served bytes' truth) wins; the monolith's record is the
    # digest-less fallback; a disagreement between them is named loudly.
    def backfilled_sha(release, entry, name)
      recorded = previous_sha_for(entry, name)
      digest = listed_digest(release, name)
      if digest && recorded && digest != recorded
        puts "::warning::#{name}: the served bytes (#{digest[0, 12]}…) disagree with the manifest.json " \
             "record (#{recorded[0, 12]}…) — the sidecar follows the served bytes"
      end
      sha = digest || recorded
      raise "BACKFILL: no sha256 available for #{name} (no listing digest, no manifest.json record)" unless sha

      sha
    end

    def backfill_shards(release, entries)
      entries.each do |entry|
        next if find_asset(release, shard_name_for(entry))

        shard = "#{JSON.pretty_generate(digest_truthed_entry(release, entry))}\n"
        ensure_metadata_asset(release, shard_name_for(entry), shard)
      end
    end

    # The monolith entry with every sha field re-anchored to the listing's
    # server-computed digest (the served bytes' truth) when the two
    # disagree — the incident's hand repair proved the record can lie; the
    # digest never does. backfill_sidecars has already named every
    # disagreement loudly by the time this runs.
    def digest_truthed_entry(release, entry)
      truthed = entry.dup
      truthed[:sha256] = listed_digest(release, entry[:filename]) || entry[:sha256]
      %i[image dll].each do |facet|
        block = entry[facet]
        next unless block

        truthed[facet] = block.merge(sha256: listed_digest(release, block[:filename]) || block[:sha256])
      end
      truthed
    end

    # previous_entry_covering over a given entry list (the backfill's
    # monolith read), same facet-aware lookup.
    def previous_entry_covering_in(entries, filename)
      entries.find do |entry|
        metadata_assets(entry).keys.include?(filename)
      end
    end

    def report_missing_packages(packages)
      executables, images, dlls = package_names(packages)
      report_missing_executables(executables)
      report_image_gaps(executables, images)
      report_dll_gaps(executables, dlls)
    end

    def package_names(packages)
      executables, images, dlls = partition_packages(packages)
      [
        executables.map { |package| package.basename.to_s.sub(/\.exe\z/, "") },
        images.map { |package| package.basename.to_s.sub(/\.tfs\z/, "") },
        dlls.map { |package| package.basename.to_s.sub(/\.dll\z/, "") }
      ]
    end

    def report_missing_executables(found)
      missing = expected_package_names - found
      return if missing.empty?

      puts "::warning::Release incomplete: #{missing.size} expected runtime package(s) are missing"
      missing.sort.each { |name| puts "::warning::Missing runtime package: #{name}" }
      puts "Continuing with #{found.size} available package(s); the completeness check at " \
           "the end of the publish fails the run if these are still missing"
    end

    # The per-leg gate (also the audit's): a failed build leg simply never
    # lands its package — the release must not LOOK complete when it is
    # not. After the uploads, re-list the release assets (paginated) and
    # compare against this leg's expected set: every matrix package
    # (windows names may carry .exe), its filesystem image, its windows
    # runtime DLL, each landed file's .sha256 sidecar and the package's
    # .manifest.json shard.
    # Any gap fails the run loudly; without an expected matrix there is
    # nothing to verify against (warn and pass). With require_signatures
    # (the coordinator's audit on a signing-enabled line), every landed
    # name additionally owes its own `.asc` (spec 09 §5's no-fold rule) —
    # the publish-time gate passes false: the leg signs AFTER its upload.
    def verify_completeness(release, require_signatures: false)
      packages = expected_package_names
      if packages.empty?
        puts "::warning::No expected matrix available; release completeness is not verifiable"
        return
      end

      missing = missing_assets(release, packages, require_signatures: require_signatures)
      return if missing.empty?

      puts "::error::Release #{@tag} is incomplete: #{missing.size} expected asset(s) missing"
      missing.sort.each { |name| puts "::error::Missing asset: #{name}" }
      raise "Release #{@tag} is incomplete (#{missing.size} missing asset(s))"
    end

    def missing_assets(release, packages, require_signatures: false)
      present = all_assets(release).map(&:name)
      packages.flat_map { |name| missing_package_assets(present, name, require_signatures: require_signatures) }
    end

    # One expected package's gaps. Windows executables may or may not carry
    # the .exe suffix (the artifact naming is still settling), so the exe
    # expectation matches both. Metadata expectations ride on what actually
    # landed — a package whose exe never landed reports its own name only,
    # never a cascade of secondary sidecar/shard gaps (one error per gap).
    def missing_package_assets(present, name, require_signatures: false)
      exe = [name, "#{name}.exe"].find { |candidate| present.include?(candidate) }
      landed, missing = expected_facets(name).partition { |facet| present.include?(facet) }
      missing.unshift(name) unless exe
      return missing if exe.nil?

      missing + missing_metadata(present, name, [exe] + landed, require_signatures: require_signatures)
    end

    # The non-executable artifacts a package is expected to carry: the
    # filesystem image everywhere, the runtime DLL on windows.
    def expected_facets(name)
      facets = ["#{name}.tfs"]
      facets << "#{name}.dll" if name.include?("windows")
      facets
    end

    # The metadata a landed package owes: one sidecar per landed asset plus
    # its shard — and, when signatures are required (spec 09 §5: no
    # artifact is ever "covered by" another's signature), one `.asc` per
    # landed asset, per sidecar, and per shard.
    def missing_metadata(present, name, landed, require_signatures: false)
      expected = landed.map { |asset| "#{asset}#{SIDECAR_SUFFIX}" } + ["#{name}#{SHARD_SUFFIX}"]
      expected += (landed + expected).map { |asset| "#{asset}.asc" } if require_signatures
      expected.reject { |asset| present.include?(asset) }
    end

    # The windows legs ship the runtime DLL as a third artifact: a windows
    # executable without its DLL cannot load any native extension, and an
    # unowned DLL means a leg's upload never landed.
    def report_dll_gaps(executables, dlls)
      windows = executables.select { |name| name.include?("windows") }
      (windows - dlls).sort.each do |name|
        puts "::warning::Runtime package #{name} has no runtime DLL (#{name}.dll); " \
             "the windows runtime cannot load native extensions without it"
      end
      (dlls - executables).sort.each do |name|
        puts "::warning::Runtime DLL #{name}.dll has no matching runtime package; " \
             "it is uploaded but carries no manifest entry"
      end
    end

    def report_image_gaps(executables, images)
      (executables - images).sort.each do |name|
        puts "::warning::Runtime package #{name} has no filesystem image (#{name}.tfs); " \
             "the package stays consumable but the image-era lean flow cannot use it"
      end
      (images - executables).sort.each do |name|
        puts "::warning::Filesystem image #{name}.tfs has no matching runtime package; " \
             "it is uploaded but carries no manifest entry"
      end
    end

    def remove_existing_asset(release, filename)
      puts "Deleting existing asset #{filename}"
      existing = find_asset(release, filename)
      return unless existing

      with_transient_retries { @client.delete_release_asset(existing.id) }
      drop_asset_from_memo(existing.id) # the deleted asset leaves the listing
      wait_for_absence_best_effort(release, filename, existing)
    end

    # GitHub asset deletion is only eventually consistent: a same-name
    # re-upload 422s until the delete propagates (the v0.16.1 windows
    # publish lost SHA256SUMS.txt to exactly this — four retries inside
    # ~20 s never saw the absence). Poll for the absence, SLEEPING between
    # polls, under an overall wall-clock deadline; when propagation outlasts
    # the deadline the named error fires — the wait never spins and never
    # silently gives up (the 2026-08-20 publish burned its whole job timeout
    # on a wait whose outcome nobody could act on).
    # The deadline matches the OBSERVED propagation window: the 2026-08-29
    # publish watched a deleted name stay 422-blocked well past the old
    # 60 s — past the per-asset 300 s budget once. Three minutes of polling
    # (single-asset reads, never a re-listing) covers the incident class; a
    # name still held after that is wedged, and the caller's
    # retry/convergence budget rides it out.
    DELETION_PROPAGATION_POLL_INTERVAL = 2
    DELETION_PROPAGATION_DEADLINE = 180
    # The listing's truth frees the name BEFORE the upload validator's
    # replica does: on the 0.16.8 publish a same-name POST kept 422ing
    # (Validation Failed / code: already_exists / field: name) ~15 s PAST
    # the deletion's visible absence — the manual repair that worked was
    # "gone, grace, then upload". Every confirmed absence pays this grace
    # before the next POST.
    DELETION_PROPAGATION_GRACE = 15

    def wait_for_absence(release, filename, asset, deadline: DELETION_PROPAGATION_DEADLINE) # rubocop:disable Metrics/MethodLength
      started = monotonic_now
      loop do
        if asset_deleted?(release, asset)
          name_release_grace(filename)
          return
        end

        if monotonic_now - started >= deadline
          raise DeletionPropagationTimeout,
                "the deletion of #{filename} has not propagated within #{deadline}s — " \
                "the asset name stays 422-blocked server-side"
        end

        puts "Waiting for the deletion of #{filename} to propagate..."
        sleep DELETION_PROPAGATION_POLL_INTERVAL
      end
    end

    # The settle between "the deletion shows in the listing" and "the upload
    # validator lets the name go" (0.16.8: ~15 s past the script's own wait).
    def name_release_grace(filename)
      puts "#{filename} left the listing; giving the name #{DELETION_PROPAGATION_GRACE}s to free up server-side"
      sleep DELETION_PROPAGATION_GRACE
    end

    # The propagation poll is a bounded single-asset existence read by id:
    # one API call per poll. Re-listing ~4 asset pages per poll (the
    # previous shape) is what, at catalog size, drained the token's hourly
    # request window mid-publish. The real API always hands listed assets an
    # api url; the fallback rebuilds it from the release url.
    def asset_deleted?(release, asset)
      with_transient_retries { @client.release_asset(asset.url || "#{release.url}/assets/#{asset.id}") }
      false
    rescue Octokit::NotFound
      true
    end

    # The bounded wait after a delete, best-effort at the call sites that
    # have a retry budget behind them: over-deadline propagation is a loud
    # warning, and the upload's 422-by-content handler + per-asset budget
    # absorb the still-held name.
    def wait_for_absence_best_effort(release, filename, asset)
      wait_for_absence(release, filename, asset)
    rescue DeletionPropagationTimeout => e
      puts "::warning::#{e.message}"
    end

    # Wall-clock reads for the deadline accounting — monotonic, immune to
    # clock smear on the runner.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # release.assets is an embedded array capped at 30 entries, and a raw
    # rels[:assets].get is NOT auto-paginated either (auto_paginate covers
    # client methods, not Sawyer rel gets) — with 100+ assets most lookups
    # silently miss. Walk the pages explicitly, MEMOIZED per process: a full
    # publish fetches the listing once instead of ~3 pages per file (~1000
    # calls at catalog size — the reads that drained the tebako-ci token's
    # hourly window on the 0.16.6 publish). Our own mutations update the
    # memo IN PLACE (an upload appends the response's asset record, a delete
    # drops by id) — never a re-listing; another actor's mutations are
    # invisible by design — the global publish serialization means none
    # exist within a run.
    def all_assets(release)
      @all_assets ||= begin
        page = with_transient_retries { release.rels[:assets].get }
        assets = page.data
        while (nxt = page.rels[:next])
          page = with_transient_retries { nxt.get }
          assets += page.data
        end
        assets
      end
    end

    # In-place memo updates for our own mutations. A nil memo stays nil:
    # the next read fetches the listing fresh.
    def record_asset_upload(asset)
      @all_assets&.push(asset)
    end

    def drop_asset_from_memo(asset_id)
      @all_assets&.delete_if { |asset| asset.id == asset_id }
    end

    def find_asset(release, filename)
      all_assets(release).find { |a| a.name == filename }
    end

    # GET/DELETE/PUT calls other than the asset upload share the same
    # transient network failure modes; retry them (they are idempotent).
    # A 403 rate-limit response is not one of those modes: it rides the
    # window out and never consumes the transient attempts. Transport-level
    # drops (SSL EOF, TCP reset) belong here too: a stale keep-alive
    # connection answered with an SSL EOF is indistinguishable from a fresh
    # one that works — net-http retries those on EOFError but NOT on
    # OpenSSL::SSL::SSLError, so we do (the 2026-08-30 backfill crashed on
    # exactly that, on the verification GET right after a long upload POST).
    TRANSIENT_ERRORS = [
      Net::WriteTimeout, Net::ReadTimeout,
      Faraday::TimeoutError, Faraday::ConnectionFailed,
      OpenSSL::SSL::SSLError, EOFError, SystemCallError
    ].freeze

    def with_transient_retries(attempts: 4)
      with_rate_limit_rideout do
        yield
      rescue *TRANSIENT_ERRORS => e
        attempts -= 1
        raise if attempts <= 0

        delay = (5 * (4 - attempts)) + rand(5)
        puts "#{e.class}; retrying in #{delay}s (#{attempts} attempt(s) left)"
        sleep delay
        retry
      end
    end

    # A 403 rate-limit response must never kill the publish: the uploader
    # is one serialized actor, and sleeping until the window resets is the
    # CORRECT behavior (the 0.16.6 publish burned the tebako-ci token's
    # 5000-request hourly window in ~30 minutes and died at the finalize —
    # GET .../assets 403 — after all 334 payload assets had landed). The
    # upload POST rides this out too; its transient retries (escalating
    # delays, 422-by-content resolution, the per-asset budget) stay with
    # perform_upload.
    RATE_LIMIT_SETTLE = 5
    RATE_LIMIT_DEFAULT_WAIT = 60
    RATE_LIMIT_BUDGET = (2 * 3600) + 300

    def with_rate_limit_rideout
      yield
    rescue Octokit::TooManyRequests => e
      wait = rate_limit_wait(e)
      puts "#{e.class}; rate-limited — sleeping #{wait}s until the window resets"
      sleep wait
      retry
    end

    # The seconds to sleep before the next call, budget-checked: one full
    # hourly window is a legitimate wait; a wait that would push the process
    # past two windows means something is systemically wrong — give up
    # loudly instead of blocking the runner forever.
    def rate_limit_wait(error)
      wait = rate_limit_seconds(error)
      return wait if monotonic_now + wait <= rate_limit_deadline

      raise RateLimitBudgetExhausted,
            "the next GitHub rate-limit window is #{wait}s out but this publish has a #{RATE_LIMIT_BUDGET}s " \
            "ride-out budget — two full windows spent; giving up loudly instead of blocking forever"
    end

    def rate_limit_deadline
      @rate_limit_deadline ||= monotonic_now + RATE_LIMIT_BUDGET
    end

    # The reset header names the window's end as a wall-clock epoch (plus a
    # small settle); a stale or absent reset falls back to Retry-After,
    # then to a default minute. Faraday's real headers are case-insensitive;
    # read both spellings so a plain hash (the spec fake) serves the same
    # values.
    def rate_limit_seconds(error)
      headers = error.response_headers || {}
      reset = (headers["x-ratelimit-reset"] || headers["X-RateLimit-Reset"]).to_i
      return reset - Time.now.to_i + RATE_LIMIT_SETTLE if reset > Time.now.to_i

      retry_after = (headers["retry-after"] || headers["Retry-After"]).to_i
      return retry_after + RATE_LIMIT_SETTLE if retry_after.positive?

      RATE_LIMIT_DEFAULT_WAIT
    end

    def run
      process_release
    rescue StandardError => e
      puts "Error: #{e.message}"
      puts e.backtrace
      exit 1
    end

    def upload_package(release, package) # rubocop:disable Metrics/MethodLength
      filename = package.basename.to_s
      puts "Processing #{filename}..."
      if settled?(filename)
        puts "#{filename} kept its previous bytes earlier in this publish run — " \
             "the settled asset is never re-attempted; the refresh lands on a republish onto a recreated release object"
        return nil
      end
      return filename if skip_existing_asset?(release, filename)

      perform_upload(release, package, filename)
      filename
    rescue Octokit::UnprocessableEntity
      # The wedged-name class: a delete+recreate tonight 422s for hours —
      # the replace cannot land within the budget. Only the recovery
      # replaces reach this rescue now (byte-differing assets warn-keep in
      # skip_existing_asset? before any delete — byte-immutable per name,
      # absolutely: a forced republication recreates the release OBJECT
      # coordinator-side, never an asset here). Keep
      # the release's existing asset AND its previous manifest entry
      # (byte-truthful, never a mismatch) and complete the publish; the
      # refreshed bytes land on a later republish onto a recreated release
      # object. A
      # never-published asset has nothing to keep — that re-raises by name.
      # Facets count: the manifest keys a .tfs/.dll under its package's
      # entry, so the facet's previous bytes live in the package entry's
      # facet block (the 2026-08-20 publish died here — a wedged .tfs
      # re-raised, killing the platform's invocation and re-attempting the
      # same pair on the next).
      raise if previous_entry_covering(filename).nil?

      puts "::warning::#{filename} could not replace the wedged asset — " \
           "keeping the previous asset + manifest entry (byte-truthful); " \
           "the refresh lands on a recreated-object republish"
      settle_asset!(filename)
      nil
    end

    # The settled ledger — the durable half of warn-and-keep-previous. The
    # publish step runs the uploader once per platform (sequential
    # processes, one workspace); an asset settled in one invocation (the
    # byte-immutable keep, or a wedged recovery replace) must NEVER be
    # re-attempted by a later one (the 2026-08-20 publish re-attempted the
    # same wedged exe once per platform invocation and burned the whole
    # 150-minute job timeout doing it). The ledger file in the workspace
    # carries the settled package stems across the per-platform processes;
    # each job's fresh workspace starts it empty.
    SETTLED_LEDGER_ENV = "TEBAKO_PUBLISH_SETTLED_PATH"
    SETTLED_LEDGER_DEFAULT = ".tebako-publish-settled"

    def settled_ledger_path
      Pathname.new(ENV.fetch(SETTLED_LEDGER_ENV, SETTLED_LEDGER_DEFAULT))
    end

    # The settled package stems: this process's settles plus every earlier
    # invocation's, loaded once from the workspace ledger.
    def settled_stems
      @settled_stems ||= begin
        path = settled_ledger_path
        path.file? ? path.read.lines.map(&:chomp).reject(&:empty?).uniq : []
      end
    end

    # The package stem an asset name belongs to: the exe (with or without
    # .exe), its .tfs image and its .dll facet share one stem — settling is
    # package-scoped so a wedged exe also stands down its facets (a fresh
    # facet over previous package bytes would be a mixed-version package).
    def package_stem(filename)
      filename.sub(/\.(exe|tfs|dll)\z/, "")
    end

    def settled?(filename)
      settled_stems.include?(package_stem(filename))
    end

    def settle_asset!(filename)
      stem = package_stem(filename)
      return if settled_stems.include?(stem)

      settled_stems << stem
      settled_ledger_path.open("a") { |file| file.puts(stem) }
    end

    # The end-of-step summary: every package that kept its previous bytes
    # this run, in one loud block. The step still exits green — the design
    # is byte-truthful keep-previous, refresh on a recreated-object republish.
    def print_settled_summary
      return if settled_stems.empty?

      puts "=" * 78
      puts "Publish summary: #{settled_stems.size} package(s) kept their previous bytes this run"
      puts "(byte-immutable per name — byte-truthful keep-previous; the refresh lands on a recreated-object republish):"
      settled_stems.sort.each { |stem| puts "  - #{stem} (executable and its .tfs/.dll facets)" }
      puts "=" * 78
    end

    # A kept asset (the byte-immutable keep, or a wedged recovery
    # replace) keeps the release's previous bytes, so its published metadata
    # speaks with the previous ENTRY's voice (the served bytes' sha, never
    # the fresh one that did not land) — for the exe and its .tfs/.dll
    # facets alike. The ledger (not just this process's settles) decides: a
    # later per-platform invocation builds fresh entries for the kept
    # platform and must revert them too, or the shard/sidecars would
    # describe bytes the release does not serve. The revert itself lives in
    # effective_entry; this lookup is its source.
    def previous_entry_for(filename)
      previous_manifest_entries.find { |entry| entry[:filename] == filename }
    end

    # The warn-keep gate's lookup: the previous manifest entry whose bytes
    # cover this asset — the entry itself, or the entry whose image/dll
    # facet block names it (the manifest keys facets under their package).
    def previous_entry_covering(filename)
      previous_entry_covering_in(previous_manifest_entries, filename)
    end

    # An asset with the same name AND the same bytes is kept — an
    # unchanged artifact never re-uploads. A same-named asset whose bytes
    # DIFFER is kept too, loudly — a published release's payload assets
    # are byte-immutable per name, absolutely (owner-locked): the build
    # is not bit-reproducible, and the delete+re-upload of a differing
    # same-name asset is exactly what wedged names server-side on the
    # 0.16.6 re-publish — and the 0.16.28 republish (tebako-runtime-ruby#189):
    # a FORCE_REBUILD delete→re-upload wedged 51 legs at once, and only
    # recreating the release OBJECT freed the names. Force republication
    # therefore happens coordinator-side (the publish workflow deletes and
    # re-creates the release object before any leg fans out), never
    # per-asset here. Presence in the listing alone still proves
    # nothing (the v0.16.3 publish kept a never-committed "starter" stub
    # as "unchanged"): uncommitted stubs force the replace first, and a
    # digest-mismatched asset the previous manifest does not cover takes
    # the recovery replace (there is nothing truthful to keep).
    def skip_existing_asset?(release, filename)
      return false unless find_asset(release, filename)
      return false if uncommitted_asset?(release, filename)
      return true if keep_published_asset?(release, filename)
      return false if digest_mismatch_without_previous_entry?(release, filename)

      puts "Skipping upload of existing asset #{filename} (unchanged)"
      true
    end

    # A listed asset whose upload never committed (state "starter" — the
    # stub an interrupted publisher leaves behind) holds the name but
    # serves no bytes: delete it so the caller re-uploads.
    def uncommitted_asset?(release, filename)
      asset = find_asset(release, filename)
      return false unless asset.respond_to?(:state) && asset.state == "starter"

      puts "Re-uploading #{filename}: the listed asset never committed (state \"starter\") — it serves no bytes"
      remove_existing_asset(release, filename)
      true
    end

    # A name the previous manifest carries no entry for (a first publish,
    # an unreadable manifest, or a .tfs/.dll facet the manifest keys under
    # its package) is verified against the listing's server-computed
    # digest instead of trusted on presence; a digest-less listing keeps
    # (conservative, as before). Runs behind the byte-immutable keep: a
    # differing asset WITH previous coverage never reaches this replace.
    def digest_mismatch_without_previous_entry?(release, filename)
      return false unless previous_entry_for(filename).nil?

      digest = listed_digest(release, filename)
      current = current_shas[filename]
      return false unless digest && current && digest != current

      puts "Re-uploading #{filename}: no previous manifest entry and the listed digest " \
           "differs (#{digest[0, 12]}… → #{current[0, 12]}…)"
      remove_existing_asset(release, filename)
      true
    end

    # Byte-immutability keep (owner-locked): the release already carries an
    # asset under this name and its published bytes differ from the local
    # package's — the listing's server-computed digest is the authority,
    # the previous manifest's recorded sha the digest-less fallback. Keep
    # the published asset: warn with both shas and settle the package stem
    # so effective_entry reverts the published metadata to the previous
    # entry (byte-truthful for the published bytes) and no later
    # per-platform invocation re-attempts the replace. A name the previous
    # manifest does not cover has nothing truthful to keep — the digest
    # recovery gate above handles it; same bytes (or an unreadable
    # manifest) fail conservative, as before.
    def keep_published_asset?(release, filename)
      previous = previous_entry_covering(filename)
      return false if previous.nil?

      published = listed_digest(release, filename) || previous_sha_for(previous, filename)
      current = current_shas[filename]
      return false unless published && current && published != current

      puts "::warning::#{filename} exists on the release with different bytes " \
           "(published #{published[0, 12]}…, local #{current[0, 12]}…) — byte-immutable per name; keeping the " \
           "previous asset + manifest entry (byte-truthful); the refresh lands on a recreated-object republish"
      settle_asset!(filename)
      true
    end

    # The sha256 the previous manifest records for this asset: the entry's
    # own sha for the executable, the image/dll facet block's sha for a
    # facet (facets key under their package's entry).
    def previous_sha_for(entry, filename)
      if entry.dig(:image, :filename) == filename
        entry.dig(:image, :sha256)
      elsif entry.dig(:dll, :filename) == filename
        entry.dig(:dll, :sha256)
      else
        entry[:sha256]
      end
    end

    def validate_environment
      %w[GITHUB_TOKEN TEBAKO_VERSION].each do |var|
        raise "#{var} environment variable is required" unless ENV[var]
      end
      # Armed signing on a publish leg: the keyid must be present and sane
      # BEFORE any mutation — a shard's `signature` declaration names it
      # (spec 09 §5/§9), and a leg that cannot declare must fail before
      # uploading, never ship an under-declared shard. Audits/backfills
      # declare nothing, so they never gate on it.
      signing_keyid if signing_enabled? && !audit_only? && !backfill_only?
    end

    def validate_packages_directory
      packages_dir = Pathname.new("runtime-packages")
      raise "No runtime packages directory found" unless packages_dir.directory?

      packages = packages_dir.glob("*").reject { |p| support_file?(p) }
      raise "No packages found in runtime-packages directory" if packages.empty?

      puts "Found packages:\n#{packages.map(&:basename).join("\n")}"
      packages
    end

    # `.abi` sidecars (the runtime's platform string), `.contract.yaml`
    # sidecars (the era-2 release card provenance) and `.sha256` markers
    # (the image's store-layout trust anchor, spec 22 §6 — the boot
    # smoke's image-key input) are manifest inputs / build outputs read
    # in place — never packages of their own.
    def support_file?(path)
      path.extname == ".abi" || path.extname == ".sha256" ||
        path.basename.to_s.end_with?(CONTRACT_SIDECAR_SUFFIX)
    end
  end
end
