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
    # Every GitHub call below rides the shared convergence wrapper (quota
    # ride-outs, transient retries, the release-visibility and
    # deletion-propagation budgets) — tebako-release#14's sign legs died
    # on terminal 403s mid-convergence; no call escapes the wrapper now.
    include Convergence

    # Armed-but-cannot, provenance, and coverage failures: the pass never
    # ships a partially signed release silently.
    class SigningGateError < StandardError; end

    # This run's fresh package bytes, materialized in the leg's workspace —
    # signing prefers them over a re-download, but only when they hash to
    # the release listing's digest (only a backfill onto an older release
    # downloads). SIGN_LOCAL_DIR points a consumer whose legs stage bytes
    # elsewhere (openjdk's out/<flavor>-<triplet>/) at this run's dir.
    LOCAL_PACKAGES_DIR = "runtime-packages"

    # upload convergence: a tiny metadata asset either lands or cycles.
    # Campaign-scale concurrency — dozens of sign legs replacing .asc
    # assets on one release object — makes the 422 delete-propagation
    # race routine, so the budget is ten jittered cycles over ~4–5
    # minutes (tebako-release#15); the jitter keeps concurrently failing
    # legs from re-colliding on the same propagation windows in lockstep.
    CONVERGENCE_DELAYS = [5, 10, 15, 20, 30, 30, 30, 30, 40, 40].freeze
    CONVERGENCE_JITTER = 0.4

    # A convergence pause scaled by 1 ± CONVERGENCE_JITTER. A zero pause
    # stays zero, so spec-stubbed delay lists keep their determinism.
    def self.jittered(pause)
      pause * (1 + (((rand * 2) - 1) * CONVERGENCE_JITTER))
    end

    # served-bytes convergence: a young release object lists an asset before
    # the byte store serves it (the runtime-ruby 0.16.28 republish's
    # sign-step class — the listing had converged, the download 404ed as
    # "no assets"); bounded re-asks, then the named failure stands.
    SERVED_BYTES_DELAYS = [5, 10, 20, 40, 80].freeze

    # The young-release wordings the download re-ask loop retries (the
    # operation class b): the name came FROM the release listing (or the
    # leg just published it), so gh's "no assets to download" — and a fresh
    # release object's own "release not found" (the 2026-10-02/03
    # force_rebuild's sidecar-fetch deaths, tebako-release#13) — are the
    # read path trailing the write, never absence. Every other named
    # failure (auth, usage, a genuinely gone release past the budget)
    # raises at once.
    YOUNG_RELEASE_WORDINGS = ["no assets to download", "release not found"].freeze

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
        assets = with_transient_retries("release assets") { @client.release_assets(release.url) }
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

          sign_one(work, key_file, tool, release, name, digest, by_name["#{name}.asc"])
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

    # Read-after-create convergence (the operation class b): on a fresh
    # per-line release object a sign leg can schedule AHEAD of the publish
    # leg's create becoming readable — the 2026-10-02/03 force_rebuild
    # fan-out died on exactly this. Poll for visibility on the bounded
    # budget (each poll rides the wrapper, so a quota burst stretches the
    # wait inside the call), then the named failure stands.
    def find_release
      find_release_once || await_release_visibility
    end

    def find_release_once
      with_transient_retries("release for tag #{@tag}") { @client.release_for_tag(@config.repo, @tag) }
    rescue Octokit::NotFound
      nil
    end

    def await_release_visibility
      RELEASE_VISIBILITY_DELAYS.each do |pause|
        puts "#{@tag}: the release object is not visible yet (a concurrent leg just created it) — " \
             "re-asking in #{pause}s"
        sleep pause
        release = find_release_once
        return release if release
      end
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
      latest = with_transient_retries("latest #{@config.tool_repo} release") do
        @client.latest_release(@config.tool_repo)
      end
      names = with_transient_retries("tool release assets") { @client.release_assets(latest.url) }.map(&:name)
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
    def sign_one(work, key_file, tool, release, name, digest, existing_asc) # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists
      local = Pathname.new(local_packages_dir).join(name)
      target = if local.exist? && Digest::SHA256.file(local).hexdigest == digest
                 local
               else
                 download_served_bytes(work.join("assets"), name, digest)
               end
      @executor.run(tool, "sign", "--key-file", key_file.to_s, "--no-sums", name, chdir: File.dirname(target.to_s))
      @executor.run(tool, "verify", name, chdir: File.dirname(target.to_s))
      converge_asc(release, Pathname.new(File.join(File.dirname(target.to_s), "#{name}.asc")), existing_asc)
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

    # The bounded re-ask for the young-release-object lag: the wordings
    # above retry; everything else raises at once.
    def download_when_served(dir, name)
      pauses = SERVED_BYTES_DELAYS.dup
      begin
        @executor.run("gh", "release", "download", @tag, "--repo", @config.repo,
                      "--pattern", name, "--dir", dir.to_s, "--clobber")
      rescue SigningGateError => e
        raise unless young_release_failure?(e) && (pause = pauses.shift)

        puts "#{name}: the release read path has not converged on the fresh object yet — re-asking in #{pause}s"
        sleep pause
        retry
      end
    end

    def young_release_failure?(error)
      YOUNG_RELEASE_WORDINGS.any? { |wording| error.message.include?(wording) }
    end

    # A tiny metadata upload, converged: replace whatever the name serves,
    # then poll until the served record's digest is our bytes. The poll
    # rides the SINGLE-ASSET endpoint (one request per cycle — never a
    # re-paginated listing: at catalog size the full listing is ~5 pages,
    # and ~90 legs polling it every cycle is what drained the shared
    # token's hourly budget mid-fleet, tebako-release#14). The held record
    # flows between cycles: the pass-start listing's stale record first,
    # then each upload's landed record.
    def converge_asc(release, asc_file, existing) # rubocop:disable Metrics/MethodLength
      sha = Digest::SHA256.file(asc_file).hexdigest
      asset = existing
      converged = false
      CONVERGENCE_DELAYS.each do |pause|
        converged, asset = converge_asc_cycle(release, asc_file, sha, asset)
        break if converged

        wait = Signer.jittered(pause)
        puts "#{asc_file.basename} has not converged on the release yet; cycling in #{wait.round}s"
        sleep wait
      end
      raise SigningGateError, "NAMED FAILURE: #{asc_file.basename} did not converge on #{@tag}" unless converged
    end

    # One convergence cycle: the held record already serving our bytes is
    # done; a stale record is deleted — its absence awaited on the same
    # single-asset endpoint before the re-upload (the delete-then-upload
    # class, tebako-release#12's wedge lesson) — and the upload's fresh
    # record feeds the next cycle's poll. A 422 mid-replace carrying
    # already_exists is the deletion-propagation race (or a concurrent
    # leg's landed upload): re-list ONCE to learn the conflicting record,
    # then ride it as not-yet-converged. Any other 422 is a validation
    # error, not the race — fail fast and named, never grind.
    # Returns [converged, record-to-hold].
    def converge_asc_cycle(release, asc_file, sha, asset) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity
      name = asc_file.basename.to_s
      digest = asset && served_sha(asset, name)
      return [true, asset] if digest == sha

      asset = nil if asset && digest.nil? # the held record left the store — the name is free
      if asset
        with_transient_retries("delete #{name}") { @client.delete_release_asset(asset.id) }
        await_asc_absence(asset, name)
      end
      asset = with_transient_retries("upload #{name}") do
        @client.upload_asset(release.url, asc_file.to_s,
                             content_type: "text/plain",
                             name: name)
      end
      [false, asset]
    rescue Octokit::UnprocessableEntity => e
      unless e.message.include?("already_exists")
        raise SigningGateError,
              "NAMED FAILURE: the #{name} upload was rejected (#{e.message}) — not the deletion-propagation " \
              "race; refusing to grind on a validation error"
      end
      puts "#{name}: replace raced the 422 propagation window (#{e.class}) — cycling"
      [false, find_asc_asset(release, name)]
    end

    # The record's currently-served digest, read on the single-asset
    # endpoint; nil when the record is gone (our delete propagated, or it
    # never committed).
    def served_sha(asset, name)
      record = with_transient_retries("asset #{name} state") { @client.release_asset(asset.url) }
      listed_sha(record)
    rescue Octokit::NotFound
      nil
    end

    # The delete is visible only when the single-asset read 404s — the
    # listing flaps independently of the authoritative store (#12's night),
    # so the listing is never probed here. Over the deadline the leg fails
    # fast and named: a resumable red beats a job-timeout wedge.
    def await_asc_absence(asset, name) # rubocop:disable Metrics/MethodLength
      deadline = monotonic_now + DELETION_PROPAGATION_DEADLINE
      until asc_absent?(asset)
        if monotonic_now >= deadline
          raise SigningGateError,
                "NAMED FAILURE: the deletion of #{name} has not propagated within " \
                "#{DELETION_PROPAGATION_DEADLINE}s — the asset name stays 422-blocked server-side; " \
                "re-run the sign leg"
        end

        puts "Waiting for the deletion of #{name} to propagate..."
        sleep DELETION_PROPAGATION_POLL_INTERVAL
      end
      puts "#{name} left the listing; giving the name #{DELETION_PROPAGATION_GRACE}s to free up server-side"
      sleep DELETION_PROPAGATION_GRACE
    end

    def asc_absent?(asset)
      with_transient_retries("asset #{asset.id} existence") { @client.release_asset(asset.url) }
      false
    rescue Octokit::NotFound
      true
    end

    # The recovery read behind a raced 422: ONE re-listing to learn the
    # conflicting record (our own lagging delete or a concurrent leg's
    # landed upload) so the next cycle's poll rides the single-asset
    # endpoint again.
    def find_asc_asset(release, name)
      with_transient_retries("release assets") { @client.release_assets(release.url) }
        .find { |asset| asset.name == name }
    end

    # The coverage assertion: after the pass, every target has a .asc on
    # the release — a partially signed release is a named failure, never a
    # quiet state.
    def assert_coverage!(release, targets)
      names = with_transient_retries("release assets") { @client.release_assets(release.url) }.map(&:name)
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
