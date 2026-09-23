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
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

module TebakoRelease
  # Signs one factory release (tebako spec 09 §5, the no-fold rule): EVERY
  # served name carries its own detached OpenPGP .asc — the runtime
  # packages, the env images, the dll facets, AND the derived metadata
  # (the per-asset .sha256 sidecars, the per-package .manifest.json
  # shards, the .contract.yaml cards). Nothing folds into a signed
  # monolith: spec 13 §2a's de-rendezvous retired the monolithic
  # manifest.json and SHA256SUMS.txt as release assets (each shard IS its
  # release-index entry; consumers derive the monoliths from the shards),
  # so no monolith .asc exists either. Each build leg signs its own fresh
  # bytes in-leg, in the same invocation that published them — the
  # write-once names that leg owns alone.
  #
  # The signing tool is the LATEST tamatebako/tebako release's tebako-pkg
  # for THIS runner's platform (TEBAKO_PKG_HOST_ID overrides the
  # detection), pinned by asset name and sha256-verified against that
  # release's own sidecar before it runs. Every signed byte is
  # provenance-checked against the release listing's digest: the leg's
  # own workspace bytes are used only when they hash to the listed
  # digest; a download that disagrees with the listing is never signed.
  #
  # Gate (the spec 31 §5 house style): TEBAKO_RELEASE_SIGNING_ENABLED=true
  # arms the pass; armed + an empty TEBAKO_RELEASE_SIGNING_KEY is a fast
  # named failure; disarmed exits 0 and the release ships unsigned
  # (unsigned stays first-class — spec 09 §3). SIGN_ONLY_STEMS scopes the
  # pass to the caller's own write-once names (the in-leg case); empty
  # signs everything stale (the operator backfill case).
  #
  # The ONE implementation every factory consumes — lifted from
  # tebako-runtime-ruby's scripts/sign_release.rb; the consuming repo is
  # declared through TebakoRelease.configure (or TEBAKO_RELEASE_REPO),
  # never by editing a copy.
  class Signer # rubocop:disable Metrics/ClassLength
    # Armed-but-cannot, provenance, and coverage failures: the pass never
    # ships a partially signed release silently.
    class SigningGateError < StandardError; end

    # This run's fresh package bytes, materialized in the leg's workspace —
    # signing prefers them over a re-download, but only when they hash to
    # the release listing's digest (only a backfill onto an older release
    # downloads). SIGN_LOCAL_DIR points a consumer whose legs stage bytes
    # elsewhere (openjdk's out/<flavor>-<triplet>/) at this run's dir.
    LOCAL_PACKAGES_DIR = "runtime-packages"

    # upload convergence: a tiny metadata asset either lands or cycles;
    # three bounded polls then a named failure.
    CONVERGENCE_DELAYS = [5, 15, 30].freeze

    # served-bytes convergence: a young release object lists an asset before
    # the byte store serves it (the runtime-ruby 0.16.28 republish's
    # sign-step class — the listing had converged, the download 404ed as
    # "no assets"); bounded re-asks, then the named failure stands.
    SERVED_BYTES_DELAYS = [5, 10, 20, 40, 80].freeze

    def initialize(client: nil, executor: nil, env: ENV, config: nil)
      @env = env
      @config = config || TebakoRelease.config
      @client = client || Octokit::Client.new(access_token: @env.fetch("GITHUB_TOKEN"), auto_paginate: true)
      @executor = executor || ShellExecutor.new
      # TEBAKO_RELEASE_TAG decouples the target tag from the version
      # (the line-shard republication; asset names stay version-branded).
      @tag = @env.fetch("TEBAKO_RELEASE_TAG") { "v#{@env.fetch("TEBAKO_VERSION")}" }
    end

    # The one public verb. Returns :disarmed or :signed.
    def sign_release # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      unless enabled?
        puts "release signing disarmed (TEBAKO_RELEASE_SIGNING_ENABLED != 'true') — unsigned-first (spec 09 §3)"
        return :disarmed
      end
      if signing_key.empty?
        raise SigningGateError,
              "NAMED FAILURE: TEBAKO_RELEASE_SIGNING_ENABLED=true but the TEBAKO_RELEASE_SIGNING_KEY secret is not set"
      end

      release = find_release
      Dir.mktmpdir do |dir|
        work = Pathname.new(dir)
        tool = fetch_verified_tool(work)
        key_file = materialize_key(work)
        assets = @client.release_assets(release.url)
        targets = signature_targets(assets.map(&:name))
        stale = stale_targets(targets, assets)
        puts "#{@tag}: #{targets.size} signature targets, #{stale.size} need (re)signing"
        by_name = assets.to_h { |asset| [asset.name, asset] }
        stale.each do |name|
          digest = listed_sha(by_name.fetch(name))
          if digest.empty?
            raise SigningGateError,
                  "NAMED FAILURE: the release listing carries no digest for #{name} — " \
                  "signing needs the listing's sha256 to prove the signed bytes are the served bytes"
          end

          sign_one(work, key_file, tool, release, name, digest)
        end
        assert_coverage!(release, targets)
      end
      :signed
    end

    # The asset names that carry a .asc (spec 09 §5's no-fold rule): every
    # served name — payloads, .sha256 sidecars, .manifest.json shards,
    # .contract.yaml cards — except the .asc files themselves. SIGN_ONLY_STEMS
    # scopes the set to the caller's write-once names: a name matches when it
    # IS the stem or starts with "<stem>." (stems end in the platform id, so
    # one package's stem can never swallow another package's names).
    def signature_targets(asset_names)
      names = asset_names.reject { |name| name.end_with?(".asc") }
      stems = sign_only_stems
      return names.sort if stems.empty?

      names.select { |name| stems.any? { |stem| name == stem || name.start_with?("#{stem}.") } }.sort
    end

    # The targets whose .asc is absent or older than the asset itself: a
    # replaced asset invalidates its signature (new bytes), an untouched
    # asset keeps it (a detached signature over unchanged bytes stays
    # valid — re-signing would only churn the release).
    def stale_targets(targets, assets)
      by_name = assets.to_h { |asset| [asset.name, asset] }
      targets.select do |name|
        asc = by_name["#{name}.asc"]
        asc.nil? || asc.updated_at < by_name.fetch(name).updated_at
      end
    end

    private

    def enabled?
      @env["TEBAKO_RELEASE_SIGNING_ENABLED"] == "true"
    end

    def signing_key
      (@env["TEBAKO_RELEASE_SIGNING_KEY"] || "").strip
    end

    # The in-leg scope: comma/space-separated package stems this invocation
    # owns (e.g. "tebako-runtime-0.17.0-3.4.2-macos-arm64"). Empty means the
    # operator backfill case — every stale target on the release.
    def sign_only_stems
      (@env["SIGN_ONLY_STEMS"] || "").split(/[\s,]+/)
    end

    # This run's fresh-bytes dir (the LOCAL_PACKAGES_DIR constant's
    # rationale): SIGN_LOCAL_DIR overrides it for consumers whose legs
    # stage their publish bytes outside runtime-packages/.
    def local_packages_dir
      @env["SIGN_LOCAL_DIR"] || LOCAL_PACKAGES_DIR
    end

    # The platform this pass runs on — the signing tool's asset name flows
    # from it (TEBAKO_PKG_HOST_ID pins it in CI/specs; the Platform model
    # detects it otherwise).
    def tool_host_id
      @tool_host_id ||= @env["TEBAKO_PKG_HOST_ID"] || Platform.new.host_id
    end

    # The tebako-pkg asset name grammar on a tamatebako/tebako release, for
    # this runner's platform (windows carries the .exe suffix).
    def tool_asset_pattern
      suffix = tool_host_id.start_with?("windows") ? ".exe" : ""
      /\Atebako-pkg-\d+\.\d+\.\d+-#{Regexp.escape(tool_host_id)}#{Regexp.escape(suffix)}\z/
    end

    def find_release
      @client.release_for_tag(@config.repo, @tag)
    rescue Octokit::NotFound
      raise SigningGateError, "NAMED FAILURE: no release found for tag #{@tag} — nothing to sign"
    end

    # The signing subkey export, base64-decoded to a 0600 file that lives
    # and dies with the pass's tmpdir. The secret IS the base64 text —
    # `[key].pack("m0")` (Array#pack) would ENCODE it a second time and an
    # armed run could only die on rnp's BadFormat; the python factory's
    # rehearsal (real tebako-pkg, throwaway key) caught it — the spec
    # fakes never run real rnp. Garbage secrets fail named, never raw.
    def materialize_key(work)
      key_file = work.join("release-key.asc")
      begin
        key_file.write(signing_key.unpack1("m0"))
      rescue ArgumentError
        raise SigningGateError, "NAMED FAILURE: the TEBAKO_RELEASE_SIGNING_KEY secret is not valid base64"
      end
      key_file.chmod(0o600)
      key_file
    end

    # The latest tebako release's tebako-pkg for this runner's platform,
    # provenance-pinned: downloaded with its .sha256 sidecar and executed
    # only when the digest matches.
    def fetch_verified_tool(work) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      latest = @client.latest_release(@config.tool_repo)
      names = @client.release_assets(latest.url).map(&:name)
      tool_name = names.find { |name| name.match?(tool_asset_pattern) }
      unless tool_name
        raise SigningGateError,
              "NAMED FAILURE: no tebako-pkg #{tool_host_id} asset on #{latest.tag_name}"
      end

      tool_dir = work.join("tool")
      FileUtils.mkdir_p(tool_dir)
      @executor.run("gh", "release", "download", latest.tag_name, "--repo", @config.tool_repo,
                    "--pattern", tool_name, "--pattern", "#{tool_name}.sha256",
                    "--dir", tool_dir.to_s, "--clobber")
      tool = tool_dir.join(tool_name)
      want = tool_dir.join("#{tool_name}.sha256").read.split.first
      actual = Digest::SHA256.file(tool).hexdigest
      unless want == actual
        raise SigningGateError,
              "NAMED FAILURE: the signing tool #{tool_name} failed its provenance check " \
              "(expected #{want}, got #{actual})"
      end

      tool.chmod(0o755)
      tool.to_s
    end

    # One stale target: the leg's own workspace bytes when they hash to the
    # release listing's digest, otherwise a digest-verified download; sign,
    # verify against the freshly registered key, then converge the .asc onto
    # the release. The digest is the no-fold rule's provenance: the signed
    # bytes are provably the bytes the release serves.
    def sign_one(work, key_file, tool, release, name, digest) # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists
      local = Pathname.new(local_packages_dir).join(name)
      target = if local.exist? && Digest::SHA256.file(local).hexdigest == digest
                 local
               else
                 download_served_bytes(work.join("assets"), name, digest)
               end
      @executor.run(tool, "sign", "--key-file", key_file.to_s, "--no-sums", name, chdir: File.dirname(target.to_s))
      @executor.run(tool, "verify", name, chdir: File.dirname(target.to_s))
      converge_asc(release, Pathname.new(File.join(File.dirname(target.to_s), "#{name}.asc")))
      puts "#{name}: signed and converged"
    end

    # The backfill byte source: download the served asset and refuse to sign
    # anything but the listing's bytes. A digest mismatch after a successful
    # download is a hard provenance failure, never retried.
    def download_served_bytes(dir, name, digest)
      FileUtils.mkdir_p(dir)
      download_when_served(dir, name)
      target = dir.join(name)
      actual = Digest::SHA256.file(target).hexdigest
      return target if actual == digest

      raise SigningGateError,
            "NAMED FAILURE: refusing to sign bytes the release does not serve — " \
            "#{name} downloaded with sha256 #{actual}, the listing says #{digest}"
    end

    # The bounded re-ask for the young-release-object lag: the name came FROM
    # the release listing, so gh's "no assets to download" is the byte store
    # trailing the listing, never absence — it retries; every other named
    # failure (auth, usage, a genuinely gone release) raises at once.
    def download_when_served(dir, name)
      pauses = SERVED_BYTES_DELAYS.dup
      begin
        @executor.run("gh", "release", "download", @tag, "--repo", @config.repo,
                      "--pattern", name, "--dir", dir.to_s, "--clobber")
      rescue SigningGateError => e
        raise unless e.message.include?("no assets to download") && (pause = pauses.shift)

        puts "#{name} is listed but not served yet (young release object) — re-asking in #{pause}s"
        sleep pause
        retry
      end
    end

    # A tiny metadata upload, converged: replace whatever the name serves,
    # then poll until the listing's digest is our bytes (the edge cache
    # lesson of the uploader, bounded).
    def converge_asc(release, asc_file)
      sha = Digest::SHA256.file(asc_file).hexdigest
      converged = false
      CONVERGENCE_DELAYS.each do |pause|
        converged = asc_converged?(release, asc_file, sha)
        break if converged

        puts "#{asc_file.basename} has not converged on the release yet; cycling in #{pause}s"
        sleep pause
      end
      raise SigningGateError, "NAMED FAILURE: #{asc_file.basename} did not converge on #{@tag}" unless converged
    end

    # One convergence cycle: the listing already serving our bytes is done;
    # anything else is deleted/replaced and re-uploaded for the next poll.
    # A 422 mid-replace is the deletion-propagation race (the wedge
    # lesson): the name unblocks within a cycle, so it rides along as
    # not-yet-converged instead of crashing the pass.
    def asc_converged?(release, asc_file, sha) # rubocop:disable Metrics/AbcSize
      existing = @client.release_assets(release.url).find { |asset| asset.name == asc_file.basename.to_s }
      return true if existing && listed_sha(existing) == sha

      @client.delete_release_asset(existing.id) if existing
      @client.upload_asset(release.url, asc_file.to_s,
                           content_type: "text/plain",
                           name: asc_file.basename.to_s)
      false
    rescue Octokit::UnprocessableEntity => e
      puts "#{asc_file.basename}: replace raced the 422 propagation window (#{e.class}) — cycling"
      false
    end

    # The coverage assertion: after the pass, every target has a .asc on
    # the release — a partially signed release is a named failure, never a
    # quiet state.
    def assert_coverage!(release, targets)
      names = @client.release_assets(release.url).map(&:name)
      missing = targets.reject { |name| names.include?("#{name}.asc") }
      return if missing.empty?

      raise SigningGateError,
            "NAMED FAILURE: #{missing.size} signature(s) missing on #{@tag}: #{missing.join(", ")}"
    end

    # The listing's digest field is "sha256:<hex>" when the API serves one.
    def listed_sha(asset)
      asset.digest.to_s.sub(/\Asha256:/, "")
    end

    # The default command seam: argv in, stdout out, named failure on a
    # non-zero exit. Specs inject a recording stand-in.
    class ShellExecutor
      # gh's release-asset edges are transient-prone under release-storm
      # load: the 5xx class and the intermediary 403 clear on a re-ask (the
      # 0.16.24 publish lost a signing leg to an HTTP 500 on a manifest
      # download — after every asset had already converged). Deterministic
      # failures (404s, auth, usage) raise at once. Bounded, with backoff.
      TRANSIENT = /HTTP 5\d\d|intermediary/i
      ATTEMPTS = 4

      def run(*argv, chdir: ".")
        attempts = 0
        loop do
          out, err, status = Open3.capture3(*argv, chdir: chdir)
          break out if status.success?

          unless err =~ TRANSIENT && (attempts += 1) < ATTEMPTS
            raise SigningGateError,
                  "NAMED FAILURE: `#{argv.join(" ")}` exited #{status.exitstatus}: #{err.strip}"
          end
          sleep(2**attempts)
        end
      end
    end
  end
end
