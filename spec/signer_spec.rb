# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"
require "json"
require "pathname"
require "time"
require "tmpdir"

# Recording stand-ins in the release_manager_spec idiom: the signer
# accepts any client/executor object, and every publish interaction
# becomes observable through the fakes' public collections.
SignSpecAsset = Struct.new(:id, :name, :digest, :updated_at, :url)
SignSpecRelease = Struct.new(:url, :tag_name)

# The Octokit stand-in: release listings per release URL, uploads and
# deletes recorded AND reflected in the listing (an uploaded .asc joins
# the assets with the digest of its bytes, so the convergence poll sees
# exactly what the real edge would). Transient/quota failures are
# scriptable per call (fail_next), and a delete can be made to lag the
# single-asset read path by delete_propagation polls — the 0.16.32 smoke
# night's authoritative-store lag (tebako-release#12).
class FakeSignClient
  attr_reader :uploads, :deletes, :tags, :attempts
  attr_accessor :delete_propagation

  def initialize(release:, assets:, tool_release:, tool_assets:) # rubocop:disable Metrics/MethodLength
    @release = release
    @assets = assets
    @tool_release = tool_release
    @tool_assets = tool_assets
    @uploads = []
    @deletes = []
    @tags = []
    @delete_propagation = 0
    @pending_deletes = {}
    @attempts = Hash.new(0)
    @failures = Hash.new { |hash, key| hash[key] = [] }
  end

  def fail_next(call, error)
    @failures[call] << error
  end

  def attempt(call)
    @attempts[call] += 1
    raise @failures[call].shift unless @failures[call].empty?
  end

  def release_for_tag(_repo, tag)
    attempt(:release_for_tag)
    @tags << tag
    @release
  end

  def latest_release(_repo)
    attempt(:latest_release)
    @tool_release
  end

  def release_assets(url)
    attempt(:release_assets)
    url == @release.url ? @assets : @tool_assets
  end

  # The single-asset existence/digest read the convergence poll rides.
  # A freshly deleted asset keeps answering for delete_propagation polls
  # (the delete has not propagated to the authoritative store), then 404s.
  def release_asset(url)
    attempt(:release_asset)
    tick_pending_deletes
    asset = @assets.find { |candidate| candidate.url == url } || @pending_deletes[url]&.first
    raise Octokit::NotFound unless asset

    asset
  end

  def delete_release_asset(id)
    attempt(:delete)
    @deletes << id
    asset = @assets.find { |candidate| candidate.id == id }
    @assets.delete(asset)
    @pending_deletes[asset.url] = [asset, delete_propagation] if asset && delete_propagation.positive?
  end

  def upload_asset(_url, path, content_type:, name:) # rubocop:disable Metrics/MethodLength
    attempt(:upload)
    # A same-name upload while the deleted predecessor still answers the
    # single-asset read 422s, exactly like the real API.
    if @assets.any? { |asset| asset.name == name } || @pending_deletes.key?("u/#{name}")
      raise Octokit::UnprocessableEntity.new(status: 422,
                                             body: "Validation Failed: the asset name already_exists",
                                             response_headers: {})
    end

    @uploads << { name: name, content_type: content_type }
    asset = SignSpecAsset.new(@assets.map(&:id).max + 1, name,
                              "sha256:#{Digest::SHA256.file(path).hexdigest}",
                              Time.now, "u/#{name}")
    @assets << asset
    asset
  end

  private

  def tick_pending_deletes
    @pending_deletes.each_value { |pending| pending[1] -= 1 }
    @pending_deletes.delete_if { |_url, (_asset, ttl)| ttl.negative? }
  end
end

# The command seam stand-in: `gh release download` materializes the
# requested patterns as canned bytes ("BYTES-<name>" — the specs' asset
# digests are computed over exactly these bytes, so the digest-verified
# signing path can pass honestly); `tebako-pkg sign` writes the .asc the
# way the real tool does; `tebako-pkg verify` succeeds. `unserved:` maps a
# pattern to the number of "no assets to download" failures it raises
# before serving — the young-release-object lag, exactly as gh words it;
# `unfound:` does the same for "release not found" — the fresh release
# object not yet visible on gh's read path (tebako-release#13).
class FakeSignExecutor
  attr_reader :calls

  def initialize(tool_sha_ok: true, unserved: {}, unfound: {})
    @calls = []
    @tool_sha_ok = tool_sha_ok
    @unserved = unserved
    @unfound = unfound
  end

  def run(*argv, chdir: ".")
    @calls << [argv, chdir]
    if argv[0] == "gh"
      lag_or_materialize(argv)
    elsif argv[1] == "sign"
      File.write(File.join(chdir, "#{argv.last}.asc"), "ASC-#{argv.last}")
    end
    ""
  end

  def sign_calls
    @calls.select { |argv, _| argv[1] == "sign" }.map { |argv, _| argv.last }
  end

  def download_patterns
    @calls.select { |argv, _| argv[0] == "gh" }.flat_map { |argv, _| patterns_from(argv) }
  end

  private

  def patterns_from(argv)
    argv.each_with_index.with_object([]) { |(arg, i), acc| acc << argv[i + 1] if arg == "--pattern" }
  end

  # A lagging pattern raises the real gh wording until its budget is spent,
  # then serves — the signer's re-ask loop is what's under test. `unfound`
  # is the same lag one hop earlier: the fresh release object itself is not
  # on gh's read path yet, so EVERY pattern on it answers "release not found".
  def lag_or_materialize(argv) # rubocop:disable Metrics/MethodLength
    patterns = patterns_from(argv)
    lagging = patterns.find { |name| @unserved[name].to_i.positive? }
    if lagging
      @unserved[lagging] -= 1
      raise TebakoRelease::Signer::SigningGateError,
            "NAMED FAILURE: `gh release download vX --pattern #{lagging} --clobber` exited 1: no assets to download"
    end
    unfound = patterns.find { |name| @unfound[name].to_i.positive? }
    if unfound
      @unfound[unfound] -= 1
      raise TebakoRelease::Signer::SigningGateError,
            "NAMED FAILURE: `gh release download vX --pattern #{unfound} --clobber` exited 1: release not found"
    end
    materialize_download(argv)
  end

  def materialize_download(argv) # rubocop:disable Metrics/AbcSize
    dir = argv[argv.index("--dir") + 1]
    patterns = patterns_from(argv)
    patterns.each { |name| File.write(File.join(dir, name), "BYTES-#{name}") }
    sidecar = patterns.find { |name| name.end_with?(".sha256") }
    tool = patterns.find { |name| !name.end_with?(".sha256") }
    return unless sidecar && tool

    sha = @tool_sha_ok ? Digest::SHA256.file(File.join(dir, tool)).hexdigest : "0" * 64
    File.write(File.join(dir, sidecar), "#{sha}  #{tool}\n")
  end
end

RSpec.describe TebakoRelease::Signer do
  let(:version) { "9.9.9" }
  let(:release) { SignSpecRelease.new("https://api.test/releases/1", "v#{version}") }
  let(:tool_release) { SignSpecRelease.new("https://api.test/releases/2", "v2.5.0") }
  let(:tool_assets) do
    [SignSpecAsset.new(901, "tebako-pkg-2.5.0-linux-gnu-x86_64", nil, Time.utc(2026, 9, 1), "u/t"),
     SignSpecAsset.new(902, "tebako-pkg-2.5.0-linux-gnu-x86_64.sha256", nil, Time.utc(2026, 9, 1), "u/t.sha")]
  end
  let(:enabled_env) do
    { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true",
      "TEBAKO_RELEASE_SIGNING_KEY" => Base64.strict_encode64("SIGNING-KEY-BYTES"),
      "TEBAKO_PKG_HOST_ID" => "linux-gnu-x86_64",
      "TEBAKO_VERSION" => version }
  end

  # The listing's digest of the canned bytes the fake download serves —
  # the digest the signer's provenance check compares against.
  def asset(id, name, updated_at)
    SignSpecAsset.new(id, name, "sha256:#{Digest::SHA256.hexdigest("BYTES-#{name}")}", updated_at, "u/#{name}")
  end

  def signer_for(assets, env: enabled_env, executor: FakeSignExecutor.new)
    client = FakeSignClient.new(release: release, assets: assets,
                                tool_release: tool_release, tool_assets: tool_assets)
    [TebakoRelease::Signer.new(client: client, executor: executor, env: env), client, executor]
  end

  # A quota-shaped 403, the way Octokit 7 raises it (the rate-limit body
  # wording maps to TooManyRequests); headers carry the window's advice.
  def too_many_requests(headers = {})
    Octokit::TooManyRequests.new(status: 403, body: "API rate limit exceeded", response_headers: headers)
  end

  it "is a quiet no-op when the gate is disarmed (unsigned stays first-class)" do
    client = FakeSignClient.new(release: release, assets: [], tool_release: tool_release, tool_assets: [])
    executor = FakeSignExecutor.new
    signer = TebakoRelease::Signer.new(client: client, executor: executor,
                                       env: { "TEBAKO_VERSION" => version })
    expect(signer.sign_release).to eq(:disarmed)
    expect(executor.calls).to be_empty
    expect(client.uploads).to be_empty
  end

  it "fails fast and named when armed without the key secret" do
    signer, = signer_for([], env: { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true",
                                    "TEBAKO_RELEASE_SIGNING_KEY" => "",
                                    "TEBAKO_VERSION" => version })
    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /TEBAKO_RELEASE_SIGNING_KEY secret is not set/)
  end

  it "targets TEBAKO_RELEASE_TAG when set (the line-shard override)" do
    signer, client, = signer_for([], env: enabled_env.merge("TEBAKO_RELEASE_TAG" => "v#{version}-ruby9.9"))
    signer.sign_release
    expect(client.tags).to eq(["v#{version}-ruby9.9"])
  end

  it "fails named when the key secret is not valid base64 (the decode is real)" do
    signer, = signer_for([], env: enabled_env.merge("TEBAKO_RELEASE_SIGNING_KEY" => "!!! not base64 !!!"))
    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /not valid base64/)
  end

  it "targets every served name except the .asc files themselves (spec 09 §5's no-fold rule)" do
    signer, = signer_for([])
    names = ["tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64",
             "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64.tfs",
             "tebako-runtime-9.9.9-3.3.12-windows-ucrt64.exe",
             "tebako-runtime-9.9.9-3.3.12-windows-ucrt64.dll",
             "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64.sha256",
             "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64.manifest.json",
             "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64.contract.yaml",
             "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64.asc"]
    expect(signer.signature_targets(names)).to eq(
      ["tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64",
       "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64.contract.yaml",
       "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64.manifest.json",
       "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64.sha256",
       "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64.tfs",
       "tebako-runtime-9.9.9-3.3.12-windows-ucrt64.dll",
       "tebako-runtime-9.9.9-3.3.12-windows-ucrt64.exe"]
    )
  end

  it "scopes the targets to SIGN_ONLY_STEMS (the in-leg case), comma- or space-separated" do
    stem = "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64"
    other = "tebako-runtime-9.9.9-4.0.6-macos-arm64"
    signer, = signer_for([], env: enabled_env.merge("SIGN_ONLY_STEMS" => "#{stem}, #{other}"))
    names = [stem, "#{stem}.tfs", "#{stem}.sha256", "#{stem}.manifest.json",
             "#{stem}.contract.yaml", "#{stem}.asc",
             other, "#{other}.tfs", "#{other}.manifest.json",
             # A stem-sharing prefix that is NOT the stem: never swallowed.
             "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64-musl",
             "tebako-runtime-9.9.9-3.4.10-linux-gnu-x86_64"]
    expect(signer.signature_targets(names)).to eq(
      [stem, "#{stem}.contract.yaml", "#{stem}.manifest.json", "#{stem}.sha256", "#{stem}.tfs",
       other, "#{other}.manifest.json", "#{other}.tfs"]
    )
  end

  it "re-signs only assets whose .asc is absent or older than the asset" do
    old = Time.utc(2026, 9, 1)
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "fresh", new), asset(2, "fresh.asc", new), # converged
              asset(3, "stale", new), asset(4, "stale.asc", old), # re-sign
              asset(5, "unsigned", new)]                          # sign
    signer, = signer_for(assets)
    stale = signer.stale_targets(%w[fresh stale unsigned], assets)
    expect(stale).to contain_exactly("stale", "unsigned")
  end

  it "signs every stale target, verifies it, and converges each .asc onto the release" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    old = Time.utc(2026, 9, 1)
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "pkg-a", new), asset(2, "pkg-a.asc", new),
              asset(3, "pkg-b", new), asset(4, "pkg-b.asc", old),
              asset(5, "pkg-b.sha256", new), asset(6, "pkg-b.manifest.json", new)]
    signer, client, executor = signer_for(assets)
    # The deleted stale .asc pays the name-release grace — stub the clock.
    allow(signer).to receive(:sleep)

    expect(signer.sign_release).to eq(:signed)

    # pkg-a was already converged — never re-signed, never re-uploaded.
    expect(executor.sign_calls).to contain_exactly("pkg-b", "pkg-b.sha256", "pkg-b.manifest.json")
    expect(client.uploads.map { |u| u[:name] })
      .to contain_exactly("pkg-b.asc", "pkg-b.sha256.asc", "pkg-b.manifest.json.asc")
    # The stale .asc was deleted before the replacement landed.
    expect(client.deletes).to contain_exactly(4)
    # Every upload is the plain-text detached signature shape.
    expect(client.uploads.map { |u| u[:content_type] }.uniq).to eq(["text/plain"])
  end

  it "signs the leg's local bytes without a download when they hash to the listing's digest" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "pkg-local", new)]
    signer, _client, executor = signer_for(assets)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "runtime-packages"))
      File.write(File.join(dir, "runtime-packages", "pkg-local"), "BYTES-pkg-local")
      Dir.chdir(dir) { expect(signer.sign_release).to eq(:signed) }
    end
    expect(executor.sign_calls).to eq(["pkg-local"])
    # The tool itself downloads; the payload never does.
    expect(executor.download_patterns).to contain_exactly(
      "tebako-pkg-2.5.0-linux-gnu-x86_64", "tebako-pkg-2.5.0-linux-gnu-x86_64.sha256"
    )
  end

  it "reads the leg's local bytes from SIGN_LOCAL_DIR when set" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "pkg-staged", new)]
    env = enabled_env.merge("SIGN_LOCAL_DIR" => "out/flavor-triplet")
    signer, _client, executor = signer_for(assets, env: env)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "out", "flavor-triplet"))
      File.write(File.join(dir, "out", "flavor-triplet", "pkg-staged"), "BYTES-pkg-staged")
      Dir.chdir(dir) { expect(signer.sign_release).to eq(:signed) }
    end
    expect(executor.sign_calls).to eq(["pkg-staged"])
    # The staged bytes hashed to the listing's digest — no download.
    expect(executor.download_patterns).to contain_exactly(
      "tebako-pkg-2.5.0-linux-gnu-x86_64", "tebako-pkg-2.5.0-linux-gnu-x86_64.sha256"
    )
  end

  it "re-downloads when the local bytes disagree with the listing's digest" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "pkg-drifted", new)]
    signer, _client, executor = signer_for(assets)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "runtime-packages"))
      File.write(File.join(dir, "runtime-packages", "pkg-drifted"), "STALE-LOCAL-BYTES")
      Dir.chdir(dir) { expect(signer.sign_release).to eq(:signed) }
    end
    expect(executor.sign_calls).to eq(["pkg-drifted"])
    expect(executor.download_patterns).to include("pkg-drifted")
  end

  it "refuses to sign a download whose bytes disagree with the listing's digest" do
    new = Time.utc(2026, 9, 9)
    # The listing claims a digest the served bytes cannot have.
    lying = SignSpecAsset.new(1, "pkg-a", "sha256:#{"1" * 64}", new, "u/pkg-a")
    signer, = signer_for([lying])
    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /refusing to sign bytes the release does not serve/)
  end

  it "re-asks a listed-but-unserved asset (young release object) until the bytes arrive" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    stub_const("TebakoRelease::Signer::SERVED_BYTES_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    executor = FakeSignExecutor.new(unserved: { "pkg-lagged" => 2 })
    signer, = signer_for([asset(1, "pkg-lagged", new)], executor: executor)

    expect(signer.sign_release).to eq(:signed)

    expect(executor.sign_calls).to eq(["pkg-lagged"])
    expect(executor.download_patterns.count("pkg-lagged")).to eq(3)
  end

  it "fails named when a listed asset never becomes servable within the budget" do
    stub_const("TebakoRelease::Signer::SERVED_BYTES_DELAYS", [0, 0])
    new = Time.utc(2026, 9, 9)
    executor = FakeSignExecutor.new(unserved: { "pkg-absent" => 99 })
    signer, = signer_for([asset(1, "pkg-absent", new)], executor: executor)
    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /no assets to download/)
  end

  it "fails named when the listing carries no digest for a target" do
    new = Time.utc(2026, 9, 9)
    digestless = SignSpecAsset.new(1, "pkg-a", nil, new, "u/pkg-a")
    signer, = signer_for([digestless])
    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /carries no digest for pkg-a/)
  end

  it "fetches the signing tool for this runner's platform (windows carries the .exe suffix)" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    windows_tool_assets = [
      SignSpecAsset.new(911, "tebako-pkg-2.5.0-windows-ucrt64.exe", nil, new, "u/tw"),
      SignSpecAsset.new(912, "tebako-pkg-2.5.0-windows-ucrt64.exe.sha256", nil, new, "u/tw.sha")
    ]
    client = FakeSignClient.new(release: release, assets: [asset(1, "pkg-win", new)],
                                tool_release: tool_release, tool_assets: windows_tool_assets)
    executor = FakeSignExecutor.new
    signer = TebakoRelease::Signer.new(client: client, executor: executor,
                                       env: enabled_env.merge("TEBAKO_PKG_HOST_ID" => "windows-ucrt64"))
    expect(signer.sign_release).to eq(:signed)
    expect(executor.download_patterns).to include("tebako-pkg-2.5.0-windows-ucrt64.exe",
                                                  "tebako-pkg-2.5.0-windows-ucrt64.exe.sha256")
  end

  it "names the detected host id when the tool asset is missing (no TEBAKO_PKG_HOST_ID)" do
    new = Time.utc(2026, 9, 9)
    env = enabled_env.except("TEBAKO_PKG_HOST_ID")
    # An EMPTY tool release: the detected host id varies with the spec
    # host (the default fake carries only linux-gnu-x86_64, which a linux
    # CI runner would find), so the missing-asset case must be host-free.
    client = FakeSignClient.new(release: release, assets: [asset(1, "pkg-a", new)],
                                tool_release: tool_release, tool_assets: [])
    signer = TebakoRelease::Signer.new(client: client, executor: FakeSignExecutor.new, env: env)
    host_id = TebakoRelease::Platform.new.host_id
    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /no tebako-pkg #{Regexp.escape(host_id)} asset/)
  end

  it "refuses to run a signing tool whose provenance digest disagrees" do
    new = Time.utc(2026, 9, 9)
    signer, = signer_for([asset(1, "pkg-a", new)], executor: FakeSignExecutor.new(tool_sha_ok: false))
    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /provenance check/)
  end

  it "fails named when an upload never converges" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "pkg-a", new)]
    # An upload that never joins the listing: the convergence poll can
    # never see the .asc's digest.
    client = FakeSignClient.new(release: release, assets: assets,
                                tool_release: tool_release, tool_assets: tool_assets)
    def client.upload_asset(_url, _path, content_type:, name:)
      @uploads << { name: name, content_type: content_type }
      nil
    end
    signer = TebakoRelease::Signer.new(client: client, executor: FakeSignExecutor.new, env: enabled_env)
    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /did not converge/)
  end

  it "rides a quota 403 out on a release-assets listing instead of dying mid-pass (tebako-release#14)" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    signer, client, = signer_for([asset(1, "pkg-quota", new)])
    allow(signer).to receive(:sleep)
    client.fail_next(:release_assets, too_many_requests("retry-after" => "1"))

    expect(signer.sign_release).to eq(:signed)

    # The failed listing re-asked inside the wrapper: tool listing (403 +
    # retry) + pass-start + coverage.
    expect(client.attempts[:release_assets]).to eq(4)
  end

  it "converges on a release object a concurrent leg just created (read-after-create visibility)" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    stub_const("TebakoRelease::Convergence::RELEASE_VISIBILITY_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    signer, client, = signer_for([asset(1, "pkg-fresh", new)])
    allow(signer).to receive(:sleep)
    2.times { client.fail_next(:release_for_tag, Octokit::NotFound.new) }

    expect(signer.sign_release).to eq(:signed)

    expect(client.attempts[:release_for_tag]).to eq(3)
  end

  it "re-asks a download while gh's read path has not found the fresh release object (tebako-release#13)" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    stub_const("TebakoRelease::Signer::SERVED_BYTES_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    executor = FakeSignExecutor.new(unfound: { "pkg-fresh" => 2 })
    signer, = signer_for([asset(1, "pkg-fresh", new)], executor: executor)

    expect(signer.sign_release).to eq(:signed)

    expect(executor.sign_calls).to eq(["pkg-fresh"])
    expect(executor.download_patterns.count("pkg-fresh")).to eq(3)
  end

  it "waits for the delete to leave the single-asset read path before re-uploading (tebako-release#12)" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    old = Time.utc(2026, 9, 1)
    new = Time.utc(2026, 9, 9)
    signer, client, = signer_for([asset(1, "pkg-b", new), asset(4, "pkg-b.asc", old)])
    client.delete_propagation = 2
    sleeps = []
    allow(signer).to receive(:sleep) { |pause| sleeps << pause }

    expect(signer.sign_release).to eq(:signed)

    expect(client.deletes).to eq([4])
    # Two polls at the propagation interval while the delete lags, the
    # name-release grace after the visible absence, then the cycle pause.
    expect(sleeps).to eq([2, 2, 15, 0])
  end

  it "fails fast and named when the delete never propagates (a resumable red beats a wedge)" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    old = Time.utc(2026, 9, 1)
    new = Time.utc(2026, 9, 9)
    signer, client, = signer_for([asset(1, "pkg-b", new), asset(4, "pkg-b.asc", old)])
    client.delete_propagation = 999
    allow(signer).to receive(:sleep)
    now = 0.0
    allow(signer).to receive(:monotonic_now) { now += 200 }

    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /has not propagated/)
  end

  it "rides the 422 already_exists race by re-learning the record and cycling" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    signer, client, = signer_for([asset(1, "pkg-race", new)])
    allow(signer).to receive(:sleep)
    client.fail_next(:upload, Octokit::UnprocessableEntity.new(status: 422,
                                                               body: "Validation Failed: the asset name already_exists",
                                                               response_headers: {}))

    expect(signer.sign_release).to eq(:signed)

    expect(client.attempts[:upload]).to eq(2)
  end

  it "fails fast and named on a 422 that is not the deletion-propagation race" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    signer, client, = signer_for([asset(1, "pkg-bad", new)])
    allow(signer).to receive(:sleep)
    client.fail_next(:upload, Octokit::UnprocessableEntity.new(status: 422,
                                                               body: "Validation Failed: file too large",
                                                               response_headers: {}))

    expect { signer.sign_release }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /not the deletion-propagation race/)

    expect(client.attempts[:upload]).to eq(1)
  end

  it "keeps the pass's request shape inside the single-asset budget (tebako-release#14)" do
    stub_const("TebakoRelease::Signer::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    signer, client, = signer_for([asset(1, "pkg-x", new), asset(2, "pkg-y", new)])

    expect(signer.sign_release).to eq(:signed)

    # The full listings: the tool release, the pass-start, the coverage
    # assertion — never a re-listing per convergence cycle.
    expect(client.attempts[:release_assets]).to eq(3)
    # The convergence polls ride the single-asset endpoint, one per cycle.
    expect(client.attempts[:release_asset]).to eq(2)
    # Two signed targets, nine requests in total — the catalog fleet's
    # ~90 legs stay far inside the token's 5,000/h window.
    expect(client.attempts.values.sum).to eq(9)
  end

  it "budgets the convergence window for campaign-scale concurrency (tebako-release#15)" do
    delays = TebakoRelease::Signer::CONVERGENCE_DELAYS
    expect(delays.size).to be >= 8
    expect(delays.sum).to be_between(180, 360)
  end

  it "jitters convergence pauses within the ±40% window and keeps zero pauses zero" do
    samples = Array.new(1000) { TebakoRelease::Signer.jittered(50) }
    expect(samples).to all(be_within(20).of(50))
    expect(TebakoRelease::Signer.jittered(0)).to eq(0)
  end
end

# The real executor's transient class: 5xx and the intermediary 403 earn
# a bounded re-ask (0.16.24's publish lost a signing leg to an HTTP 500
# after every asset had converged); deterministic failures raise at once.
RSpec.describe TebakoRelease::Signer::ShellExecutor do
  subject(:executor) { described_class.new }

  def capture3_queue(*results)
    calls = []
    allow(Open3).to receive(:capture3) do |*argv, **|
      calls << argv
      out, err, code = results[[calls.length - 1, results.length - 1].min]
      [out, err, instance_double(Process::Status, success?: code.zero?, exitstatus: code)]
    end
    calls
  end

  it "retries a 5xx and returns the first success" do
    calls = capture3_queue(["", "HTTP 500", 1], ["ok-bytes", "", 0])
    allow(executor).to receive(:sleep)
    expect(executor.run("gh", "release", "download", "vX")).to eq("ok-bytes")
    expect(calls.length).to eq(2)
  end

  it "raises immediately on a deterministic failure (no retry budget spent)" do
    calls = capture3_queue(["", "HTTP 404 Not Found", 1])
    expect { executor.run("gh", "release", "download", "vX") }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /NAMED FAILURE.*404/)
    expect(calls.length).to eq(1)
  end

  it "spends the whole budget on a persistent transient, then names it" do
    calls = capture3_queue(["", "Error from intermediary with HTTP status code 403", 1])
    allow(executor).to receive(:sleep)
    expect { executor.run("gh", "release", "download", "vX") }
      .to raise_error(TebakoRelease::Signer::SigningGateError, /NAMED FAILURE.*intermediary/)
    expect(calls.length).to eq(TebakoRelease::Signer::ShellExecutor::ATTEMPTS)
  end
end
