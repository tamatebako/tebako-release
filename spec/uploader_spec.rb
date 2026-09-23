# frozen_string_literal: true

# Ported from tebako-runtime-ruby's spec/release_manager_spec.rb — the machinery's
# home is this gem now; the factories keep no copies.

require "spec_helper"
require "digest"
require "json"
require "pathname"
require "yaml"

# Contract version the specs publish under (never a real release version)
SPEC_VERSION = "9.9.9"

# The builder-emitted contract sidecar every era-2 runtime package carries
# (spec 18 C2); executable fixtures get one by default.
SPEC_CONTRACT = {
  "contract_era" => 2,
  "image_layout" => 1,
  "mount_root" => "/__tfs__",
  "built_from" => {
    "release" => "v0.2.13",
    "sources" => [{ "name" => "tfs-ruby-3.3.7-src.tar.gz", "sha256" => "0" * 64 }]
  }
}.freeze

# Recording octokit stand-ins: ReleaseManager accepts any client object
# (client:), and every publish interaction becomes observable through the
# store's public collections; transient failures are scriptable per call.
FakeAsset = Struct.new(:id, :name, :browser_download_url, :digest, :state, :url)

# A page of the asset listing: data plus a Sawyer-shaped rels whose
# :next link serves the following page (the real API's shape — raw rel
# gets are NOT auto-paginated).
class FakePage
  attr_reader :data

  def initialize(data, next_link)
    @data = data
    @next_link = next_link
  end

  def rels
    @next_link ? { next: @next_link } : {}
  end
end

class FakePageLink
  def initialize(store, offset)
    @store = store
    @offset = offset
  end

  def get
    @store.page_at(@offset)
  end
end

class FakeAssetsRel
  attr_reader :gets

  def initialize(store)
    @store = store
    @gets = 0
  end

  def get
    @gets += 1
    @store.page_at(0)
  end
end

class FakeRelease
  attr_reader :id, :url, :rels

  def initialize(store)
    @id = 42
    @url = "https://api.github.test/releases/42"
    @rels = { assets: FakeAssetsRel.new(store) }
  end
end

class FakeAssetStore
  attr_reader :assets, :uploads, :deletes, :updates, :attempts, :upload_content_types, :creates
  attr_accessor :manifest_json, :delete_propagation, :page_size

  def initialize(names = [])
    @assets = names.each_with_index.map do |name, index|
      FakeAsset.new(index + 1, name, "https://download.test/#{name}", nil, nil,
                    "https://api.github.test/releases/42/assets/#{index + 1}")
    end
    @manifest_json = nil
    @delete_propagation = 0
    init_recorders
  end

  def init_recorders # rubocop:disable Metrics/MethodLength
    @uploads = []
    @deletes = []
    @updates = []
    @creates = []
    @attempts = Hash.new(0)
    @upload_content_types = {}
    @contents = {}
    @deleted_assets = {}
    @pending_deletes = {}
    @failures = Hash.new { |hash, key| hash[key] = [] }
    @page_size = 0
  end

  # Paged listing: page_size <= 0 serves everything in one page (the
  # historical fake); a positive size slices the visible assets and links
  # the pages, exactly like the real API's default-30 pages. Each page
  # read is a scriptable :listing attempt (rate-limit injection).
  def page_at(offset)
    attempt(:listing)
    all = tick_and_visible_assets
    return FakePage.new(all, nil) if page_size.to_i <= 0

    slice = all.drop(offset).first(page_size)
    following = offset + page_size
    FakePage.new(slice, (following < all.size ? FakePageLink.new(self, following) : nil))
  end

  def fail_next(call, error)
    @failures[call] << error
  end

  def attempt(call)
    @attempts[call] += 1
    raise @failures[call].shift unless @failures[call].empty?
  end

  # Per-url asset bytes for the download path; an unstubbed url falls
  # back to the manifest body (the manifest merge reads it through the
  # same client get).
  def content_for(url)
    @contents.fetch(url) { @manifest_json }
  end

  def set_content(url, body)
    @contents[url] = body
  end

  # A landed upload becomes servable: the edge (and the asset's own
  # browser url) serve exactly the bytes that landed, and the listing's
  # digest is their sha256 (the real API's shape).
  def register_upload(asset, bytes)
    asset.digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    @contents[asset.browser_download_url] = bytes
    tag = ENV.fetch("TEBAKO_VERSION", nil)
    return unless tag

    @contents["https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{tag}/#{asset.name}"] = bytes
  end

  # One listing = one propagation tick: a freshly deleted asset stays
  # visible for delete_propagation ticks (the real API's eventual
  # consistency), then vanishes.
  def tick_and_visible_assets
    @pending_deletes.each_key { |id| @pending_deletes[id] -= 1 }
    @pending_deletes.delete_if { |_id, ttl| ttl.negative? }
    visible_assets
  end

  def visible_assets
    @assets + @pending_deletes.keys.filter_map { |id| @deleted_assets[id] }
  end

  def delete_asset(id)
    asset = @assets.find { |candidate| candidate.id == id }
    return unless asset

    @assets.delete(asset)
    return unless delete_propagation.positive?

    @deleted_assets[id] = asset
    @pending_deletes[id] = delete_propagation
  end

  # A same-name upload while the deleted predecessor is still listed
  # 422s, exactly like the real API.
  def assert_uploadable!(name)
    raise Octokit::UnprocessableEntity if visible_assets.any? { |asset| asset.name == name }
  end
end

class FakeClient
  def initialize(store)
    @store = store
    @release = FakeRelease.new(store)
  end

  attr_reader :release

  def release_for_tag(_repo, _tag)
    @release
  end

  # The release-create seam: races are scriptable via fail_next(:create, …)
  # (a concurrent winner's 422), and every create records its notes body.
  def create_release(_repo, _tag, **opts)
    @store.attempt(:create)
    @store.creates << opts
    @release
  end

  def upload_asset(_url, path, content_type:, name:)
    @store.attempt(:upload)
    @store.assert_uploadable!(name)
    id = @store.assets.size + 100
    asset = FakeAsset.new(id, name, "https://download.test/#{name}", nil, nil,
                          "https://api.github.test/releases/42/assets/#{id}")
    @store.uploads << name
    @store.upload_content_types[name] = content_type
    @store.assets << asset
    @store.register_upload(asset, File.binread(path))
    asset # the real client returns the created asset record
  end

  # The single-asset existence read the deletion-propagation wait polls:
  # one call per poll instead of a full re-listing. Shares the listing's
  # propagation model — one poll is one tick.
  def release_asset(url)
    id = url.split("/").last.to_i
    @store.tick_and_visible_assets.find { |asset| asset.id == id } or raise Octokit::NotFound
  end

  def delete_release_asset(id)
    @store.attempt(:delete)
    @store.deletes << id
    @store.delete_asset(id)
  end

  def update_release(_url, body:)
    @store.attempt(:update)
    @store.updates << body
  end

  def get(url)
    @store.attempt(:get)
    @store.content_for(url) or raise Octokit::NotFound
  end
end

RSpec.describe TebakoRelease::Uploader do
  around do |example|
    old = %w[GITHUB_TOKEN TEBAKO_VERSION EXPECTED_ENV_MATRIX EXPECTED_RUBY_MATRIX FORCE_REBUILD AUDIT_ONLY
             BACKFILL_METADATA TEBAKO_PUBLISH_SETTLED_PATH
             TEBAKO_RELEASE_SIGNING_ENABLED TEBAKO_RELEASE_SIGNING_KEYID].to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV["GITHUB_TOKEN"] = "test-token"
    ENV["TEBAKO_VERSION"] = SPEC_VERSION
    ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"macos-15","container":null,"os":"macos","arch":"arm64"}]'
    ENV["EXPECTED_RUBY_MATRIX"] = '["3.3.7"]'
    ENV.delete("FORCE_REBUILD")
    ENV.delete("BACKFILL_METADATA")
    ENV.delete("TEBAKO_RELEASE_SIGNING_ENABLED")
    ENV.delete("TEBAKO_RELEASE_SIGNING_KEYID")
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      # The settled-asset ledger (cross-invocation wedge memory) lives in
      # the per-example tmpdir: the default path is the process CWD, and a
      # spec writing it would pollute the repo checkout and leak
      # settlement between examples.
      ENV["TEBAKO_PUBLISH_SETTLED_PATH"] = @dir.join("settled-ledger").to_s
      example.run
    end
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  let(:manager) { described_class.new }

  def package(name, contents = name)
    @dir.join(name).tap do |path|
      path.write(contents)
      unless name.end_with?(".tfs", ".dll", ".abi", TebakoRelease::Uploader::CONTRACT_SIDECAR_SUFFIX)
        write_contract_sidecar(path)
      end
    end
  end

  def write_contract_sidecar(path, contract = SPEC_CONTRACT)
    File.write("#{path.to_s.sub(/\.exe\z/, "")}#{TebakoRelease::Uploader::CONTRACT_SIDECAR_SUFFIX}",
               YAML.dump(contract))
  end

  def with_packages(&block)
    Dir.chdir(@dir, &block)
  end

  # The 50–200 MB runtime assets have out-written the 60 s Faraday
  # default twice in one publish day (the v0.16.3 gnu/musl retries) —
  # the client must carry upload-sized timeouts.
  it "builds the Octokit client with upload-sized request timeouts" do
    captured = nil
    allow(Octokit::Client).to receive(:new) do |**kwargs|
      captured = kwargs
      FakeClient.new(FakeAssetStore.new)
    end

    described_class.new

    request = captured.fetch(:connection_options).fetch(:request)
    expect(request[:write_timeout]).to eq(600)
    expect(request[:open_timeout]).to eq(30)
  end

  it "folds the sibling .tfs into the package entry as an additive image key" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")

    entries = manager.build_manifest_entries([exe, img])

    expect(entries.size).to eq(1)
    entry = entries.first
    expect(entry[:filename]).to eq("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    expect(entry[:ruby_version]).to eq("3.3.7")
    expect(entry[:platform]).to eq("macos-arm64")
    expect(entry[:image]).to eq(
      filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs",
      sha256: Digest::SHA256.file(img).hexdigest,
      size_bytes: img.size
    )
  end

  it "omits the image key when the package has no sibling image" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

    entries = manager.build_manifest_entries([exe])

    expect(entries.size).to eq(1)
    expect(entries.first).not_to have_key(:image)
  end

  it "folds the sibling .dll into the windows package entry as an additive dll key (issue 40)" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.exe")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.tfs")
    dll = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.dll")

    entries = manager.build_manifest_entries([exe, img, dll])

    expect(entries.size).to eq(1)
    entry = entries.first
    expect(entry[:filename]).to eq("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.exe")
    expect(entry[:dll]).to eq(
      filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.dll",
      install_as: "x64-ucrt-ruby330.dll",
      sha256: Digest::SHA256.file(dll).hexdigest,
      size_bytes: dll.size
    )
  end

  it "warns when a windows package lacks its ruby DLL and when a DLL is orphaned" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.exe")
    orphan = package("tebako-runtime-#{SPEC_VERSION}-4.0.6-windows-ucrt64.dll")

    expect { manager.report_missing_packages([exe, orphan]) }
      .to output(/3\.3\.7-windows-ucrt64 has no runtime DLL.*4\.0\.6-windows-ucrt64\.dll has no matching/m)
      .to_stdout
  end

  it "keeps pre-image manifest consumers working (existing keys unchanged)" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")

    entry = manager.build_manifest_entries([exe, img]).first

    expect(entry.keys).to contain_exactly(:tebako_version, :contract_era, :contract_version, :ruby_version,
                                          :platform, :filename, :sha256, :size_bytes,
                                          :mount_root, :image_layout, :built_from, :capabilities, :image)
    expect(entry[:tebako_version]).to eq(SPEC_VERSION)
    expect(entry[:sha256]).to eq(Digest::SHA256.file(exe).hexdigest)
    expect(entry[:size_bytes]).to eq(exe.size)
    expect(entry[:capabilities]).to eq(["yjit"])
  end

  # Plan 04: the additive capabilities key — display metadata owned by the
  # factory (Capabilities truth table), never a selector axis.
  it "emits the capabilities key per the Capabilities truth table" do
    cases = {
      "3.3.7-macos-arm64" => ["yjit"],
      "3.3.7-windows-ucrt64" => [],
      "3.1.6-linux-gnu-x86_64" => ["yjit"],
      "3.1.6-linux-gnu-arm64" => []
    }
    cases.each do |stem, expected|
      exe = package("tebako-runtime-#{SPEC_VERSION}-#{stem}#{".exe" if stem.include?("windows")}")
      entry = manager.build_manifest_entries([exe]).first
      expect(entry[:capabilities]).to eq(expected), "capabilities for #{stem}"
    end
  end

  # Spec 18 C2: the era-2 contract card — contract_era / mount_root /
  # image_layout / built_from flow from the package's builder-emitted
  # .contract.yaml sidecar into the entry unchanged.
  it "flows the contract sidecar fields into the manifest entry" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

    entry = manager.build_manifest_entries([exe]).first

    expect(entry[:contract_era]).to eq(2)
    expect(entry[:mount_root]).to eq("/__tfs__")
    expect(entry[:image_layout]).to eq(1)
    expect(entry[:built_from]).to eq(
      "release" => "v0.2.13",
      "sources" => [{ "name" => "tfs-ruby-3.3.7-src.tar.gz", "sha256" => "0" * 64 }]
    )
  end

  # S11/S16: a package without the builder's contract sidecar is pre-era;
  # the publish refuses it by name rather than shipping an under-declared
  # manifest entry (fail closed — no special pleading for side-loaded
  # runtimes either).
  it "refuses a package without the contract sidecar" do
    exe = @dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64").tap { |path| path.write("exe") }

    expect { manager.build_manifest_entries([exe]) }
      .to raise_error(/carries no \.contract\.yaml contract sidecar.*pre-era/)
  end

  it "refuses a sidecar declaring a contract era this pipeline does not speak" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    write_contract_sidecar(exe, SPEC_CONTRACT.merge("contract_era" => 3))

    expect { manager.build_manifest_entries([exe]) }
      .to raise_error(/contract_era 3.*speaks 2.*upgrade/)
  end

  it "refuses a sidecar missing contract fields" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    write_contract_sidecar(exe, SPEC_CONTRACT.reject { |key,| key == "mount_root" })

    expect { manager.build_manifest_entries([exe]) }
      .to raise_error(/missing mount_root/)
  end

  # Roadmap 45: every published package entry names the bootstrap <->
  # runtime contract it was built for; the value comes from contract.yml,
  # the release pipeline's single source of truth (never hardcode it here --
  # the next contract bump edits contract.yml and the driver define only).
  it "emits the repo contract version into every manifest entry" do
    expected = YAML.load_file(File.join(REPO_ROOT, "spec", "fixtures", "contract.yml")).fetch("contract_version")
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    other = package("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64")

    entries = manager.build_manifest_entries([exe, other])

    expect(entries.map { |entry| entry[:contract_version] }).to eq([expected, expected])
  end

  # spec 05 §5's abi line: build_runtime's <package>.abi sidecar folds
  # into the entry as the additive `abi` key; absent sidecar, no key
  # (the compat window — pre-abi releases stay consumable).
  it "emits the abi line from the .abi sidecar, omitting it when absent" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.abi").tap do |sidecar|
      sidecar.write("arm64-darwin-23\n")
    end
    plain = package("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64")

    with_packages do
      # build_manifest_entries sorts by basename: 3.1.6 (no sidecar)
      # first, 3.3.7 (sidecar) second
      entries = manager.build_manifest_entries([exe, plain])
      expect(entries.first).not_to have_key(:abi)
      expect(entries.last[:abi]).to eq("arm64-darwin-23")
    end
  end

  it "never treats .abi sidecars as packages" do
    dir = @dir.join("runtime-packages")
    dir.mkdir
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64").write("exe")
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.abi").write("arm64-darwin-23\n")

    with_packages do
      packages = manager.validate_packages_directory
      expect(packages.map(&:extname)).not_to include(".abi")
    end
  end

  it "never treats .contract.yaml sidecars as packages" do
    dir = @dir.join("runtime-packages")
    dir.mkdir
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64").write("exe")
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64#{TebakoRelease::Uploader::CONTRACT_SIDECAR_SUFFIX}")
       .write(YAML.dump(SPEC_CONTRACT))

    with_packages do
      packages = manager.validate_packages_directory
      expect(packages.map { |p| p.basename.to_s })
        .to contain_exactly("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    end
  end

  it "never treats .sha256 image markers as packages" do
    dir = @dir.join("runtime-packages")
    dir.mkdir
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64").write("exe")
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs").write("image")
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs.sha256").write("#{"0" * 64}  image\n")

    with_packages do
      packages = manager.validate_packages_directory
      expect(packages.map(&:extname)).not_to include(".sha256")
    end
  end

  it "warns when a package lacks its image" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

    expect { manager.report_missing_packages([exe]) }
      .to output(/has no filesystem image \(tebako-runtime-#{SPEC_VERSION}-3\.3\.7-macos-arm64\.tfs\)/)
      .to_stdout
  end

  it "warns when an image is orphaned (no matching package)" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
    orphan = package("tebako-runtime-#{SPEC_VERSION}-4.0.6-linux-musl-arm64.tfs")

    expect { manager.report_missing_packages([exe, img, orphan]) }
      .to output(/4\.0\.6-linux-musl-arm64\.tfs has no matching runtime package/)
      .to_stdout
  end

  it "still warns about missing expected packages" do
    expect { manager.report_missing_packages([]) }
      .to output(/Missing runtime package: tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64/).to_stdout
  end

  it "reads the prepare job's object-shaped ruby matrix rows ({version, src_sha256})" do
    ENV["EXPECTED_RUBY_MATRIX"] = "[{\"version\":\"3.3.7\",\"src_sha256\":\"#{"a" * 64}\"}]"

    expect { manager.report_missing_packages([]) }
      .to output(/Missing runtime package: tebako-runtime-#{SPEC_VERSION}-3\.3\.7-macos-arm64/).to_stdout
  end

  # The (version × arch) capability floor in the audit's expectation
  # (the build matrix's exclude-matrix applies the same rule via
  # RubyVersion#msys_arm64_capable?): a windows/arm64 package below the
  # floor is never built, so it must never be expected — the v0.16.27
  # arm64 audit demanded 42 assets for incapable rubies (run 35683750004).
  it "expects a windows/arm64 package only for a ruby at or above the capability floor" do
    ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"windows-11-arm","container":null,"os":"windows","arch":"arm64"}]'
    ENV["EXPECTED_RUBY_MATRIX"] = '["3.3.12", "3.4.10"]'

    expect { manager.report_missing_packages([]) }
      .to output(/Missing runtime package: tebako-runtime-#{SPEC_VERSION}-3\.4\.10-windows-ucrt-arm64/).to_stdout
    expect { manager.report_missing_packages([]) }
      .not_to output(/3\.3\.12-windows-ucrt-arm64/).to_stdout
  end

  it "still expects the same ruby on windows/x64 (the floor gates arm64 only)" do
    ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"windows-latest","container":null,"os":"windows","arch":"x86_64"}]'
    ENV["EXPECTED_RUBY_MATRIX"] = '["3.3.12"]'

    expect { manager.report_missing_packages([]) }
      .to output(/Missing runtime package: tebako-runtime-#{SPEC_VERSION}-3\.3\.12-windows-ucrt64/).to_stdout
  end

  # The era-2 contract set the monolithic manifest.json used to carry now
  # lives in the per-package shard (spec 13 §2a) — the shard-content
  # assertions ride the "per-package metadata (issue 139)" describe below.
  describe "#verify_completeness" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }
    let(:stem) { "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64" }
    # The sidecar-era expected set (issue 139): the payload files, each
    # landed file's .sha256 sidecar, and the package's .manifest.json
    # shard. The monolithic conveniences are gone (spec 13 §2a —
    # consumer-side derivations now), never a gate's business.
    let(:expected) do
      [stem, "#{stem}.tfs",
       "#{stem}.manifest.json", "#{stem}.sha256", "#{stem}.tfs.sha256"]
    end

    it "passes quietly when every expected asset is on the release" do
      expected.each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      expect { fake_manager.verify_completeness(release) }.not_to raise_error
    end

    it "fails loud and lists a package that never landed" do
      # No exe: the package reports its own name only — the implied
      # sidecar/shard gaps never cascade into secondary errors.
      ["#{stem}.tfs", "#{stem}.tfs.sha256"].each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      expect { fake_manager.verify_completeness(release) }
        .to raise_error(/incomplete.*1 missing/)
        .and output(/::error::Missing asset: #{stem}/).to_stdout
    end

    it "fails loud when a filesystem image is missing" do
      [stem, "#{stem}.manifest.json", "#{stem}.sha256"]
        .each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      expect { fake_manager.verify_completeness(release) }
        .to raise_error(/incomplete.*1 missing/)
        .and output(/::error::Missing asset: #{stem}\.tfs/).to_stdout
    end

    it "fails loud when the per-asset metadata did not land" do
      [stem, "#{stem}.tfs"].each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      gap = "Missing asset: #{stem}"
      gaps = /#{gap}\.manifest\.json.*#{gap}\.sha256.*#{gap}\.tfs\.sha256/m
      expect { fake_manager.verify_completeness(release) }
        .to raise_error(/incomplete.*3 missing/)
        .and output(gaps).to_stdout
    end

    it "accepts a windows executable carrying the .exe suffix" do
      ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"windows-2022","container":null,"os":"windows","arch":"x86_64"}]'
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64"
      ["#{stem}.exe", "#{stem}.tfs", "#{stem}.dll",
       "#{stem}.manifest.json", "#{stem}.exe.sha256", "#{stem}.tfs.sha256", "#{stem}.dll.sha256"]
        .each_with_index { |name, index| store.assets << FakeAsset.new(index + 1, name) }

      expect { fake_manager.verify_completeness(release) }.not_to raise_error
    end

    it "fails loud when the windows ruby DLL is missing (issue 40)" do
      ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"windows-2022","container":null,"os":"windows","arch":"x86_64"}]'
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64"
      ["#{stem}.exe", "#{stem}.tfs", "#{stem}.manifest.json", "#{stem}.exe.sha256", "#{stem}.tfs.sha256"]
        .each_with_index { |name, index| store.assets << FakeAsset.new(index + 1, name) }

      expect { fake_manager.verify_completeness(release) }
        .to raise_error(/incomplete.*1 missing/)
        .and output(/Missing asset: #{stem}\.dll/).to_stdout
    end

    it "warns and passes when no expected matrix is available" do
      ENV.delete("EXPECTED_ENV_MATRIX")
      ENV.delete("EXPECTED_RUBY_MATRIX")

      expect { fake_manager.verify_completeness(release) }
        .to output(/completeness is not verifiable/).to_stdout
    end

    # Spec 09 §5's no-fold rule, gate side: a signing-enabled line expects
    # every served name's own .asc — the coordinator's release-job audit
    # passes require_signatures: true (via TEBAKO_RELEASE_SIGNING_ENABLED).
    it "requires every served name's .asc when signatures are required" do
      expected.each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }
      # Only the exe's .asc landed: the image's and the metadata's .asc
      # files are missing.
      store.assets << FakeAsset.new(store.assets.size + 1, "#{stem}.asc")

      expect { fake_manager.verify_completeness(release, require_signatures: true) }
        .to raise_error(/incomplete.*4 missing/)
        .and output(/Missing asset: #{Regexp.escape("#{stem}.tfs.asc")}/).to_stdout
    end

    it "passes the signature-requiring audit when every served name carries its .asc" do
      (expected + expected.map { |name| "#{name}.asc" })
        .each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      expect { fake_manager.verify_completeness(release, require_signatures: true) }.not_to raise_error
    end

    it "tolerates unsigned releases when signatures are not required (unsigned stays first-class)" do
      expected.each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      expect { fake_manager.verify_completeness(release, require_signatures: false) }.not_to raise_error
    end
  end

  describe "publish retry and replace behavior" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }

    before { allow(fake_manager).to receive(:sleep) }

    it "retries a 422 upload (the delete-then-reupload race) until it lands" do
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      fake_manager.perform_upload(release, exe, exe.basename.to_s)

      expect(store.attempts[:upload]).to eq(3)
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    # The v0.16.1 publish died on this: a POST timed out but landed
    # server-side; every retry then 422'd until the attempts ran out.
    # The content check short-circuits the first 422.
    it "treats a 422 as done when the timed-out attempt landed the same content" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      store.assets << FakeAsset.new(7, exe.basename.to_s, url)
      store.set_content(url, exe.read)
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to output(/already on the release with matching content/).to_stdout
      expect(store.attempts[:upload]).to eq(1)
      expect(store.uploads).to be_empty
    end

    # The listing's digest is the authority: the download edge can serve
    # a deleted partial for hours — a matching digest accepts without a
    # byte read, and never deletes a good upload on a stale edge (the
    # v0.16.3 gnu publish looped exactly so).
    it "accepts a landed asset whose listing digest matches, even with a stale edge" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      asset = FakeAsset.new(7, exe.basename.to_s, url)
      asset.digest = "sha256:#{Digest::SHA256.hexdigest(exe.read)}"
      store.assets << asset
      store.set_content(url, "stale partial bytes")
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to output(/already on the release with matching content/).to_stdout
      expect(store.deletes).to be_empty
    end

    # The same 422 with DIFFERENT landed bytes is a partial (a timed-out
    # POST that landed incomplete) or a stale asset blocking the name:
    # delete it and land the retry — blind re-POSTs can never win (the
    # v0.16.3 publish exhausted its budget exactly here).
    it "deletes a 422's mismatched asset and lands the retry" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      store.assets << FakeAsset.new(7, exe.basename.to_s, url)
      store.set_content(url, "stale bytes")

      fake_manager.perform_upload(release, exe, exe.basename.to_s)

      expect(store.attempts[:upload]).to eq(2)
      expect(store.uploads).to eq([exe.basename.to_s])
      expect(store.deletes).to eq([7])
    end

    # A recovery replace whose name wedges server-side (the replace cannot
    # land within the budget) keeps the previous entry — byte-truthful,
    # loudly warned, never a failed publish; the completeness gate remains
    # the arbiter of what the release actually serves. (Byte-differing
    # assets warn-keep before any delete — this rescue is the recovery
    # paths' safety net; the trigger below is the never-committed "starter"
    # stub.) The settled package's published metadata then speaks with the
    # previous entry's voice (effective_entry).
    it "keeps the previous asset and entry when the replace cannot land" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      previous = { filename: exe.basename.to_s, sha256: "1" * 64, platform: "macos-arm64" }
      store.delete_propagation = 999 # the delete never clears the listing
      store.assets << FakeAsset.new(7, exe.basename.to_s, url, nil, "starter")
      store.set_content(url, "previous bytes")
      allow(fake_manager).to receive(:previous_manifest_entries).and_return([previous])
      allow(fake_manager).to receive(:current_shas)
        .and_return(exe.basename.to_s => Digest::SHA256.hexdigest(exe.read))
      # The wait is wall-clock-bounded now: an advancing clock keeps a
      # never-propagating delete from spending real seconds per poll.
      clock = 0.0
      allow(fake_manager).to receive(:monotonic_now) { clock += 120.0 }
      (TebakoRelease::Uploader::UPLOAD_RETRY_DELAYS.size + 1).times { store.fail_next(:upload, Octokit::UnprocessableEntity.new) }

      expect { fake_manager.upload_package(release, exe) }
        .to output(/keeping the previous asset/).to_stdout
      expect(fake_manager.effective_entry({ filename: exe.basename.to_s, sha256: "2" * 64 }))
        .to eq(previous)
    end

    # A listed-but-unreadable landed asset (mid-propagation) proves
    # nothing — back off, never crash the publish on the read.
    it "treats an unreadable landed asset as not landed and keeps backing off" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s, "https://download.test/#{exe.basename}")
      (TebakoRelease::Uploader::UPLOAD_RETRY_DELAYS.size + 1).times { store.fail_next(:upload, Octokit::UnprocessableEntity.new) }

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to raise_error(Octokit::UnprocessableEntity)
      expect(store.attempts[:upload]).to eq(TebakoRelease::Uploader::UPLOAD_RETRY_DELAYS.size + 1)
    end

    # The v0.16.1 windows publish lost SHA256SUMS.txt to this: the delete's
    # re-upload 422'd four times inside ~20 s because the deletion had not
    # propagated. force_upload now polls for the absence first — exactly
    # one upload attempt, no 422 spent.
    it "force_upload waits out deletion propagation before re-uploading" do
      store.assets << FakeAsset.new(7, "SHA256SUMS.txt", "https://download.test/SHA256SUMS.txt")
      store.delete_propagation = 3
      file = @dir.join("SHA256SUMS.txt").tap { |path| path.write("new sums") }

      fake_manager.force_upload(release, file)

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq(["SHA256SUMS.txt"])
      expect(store.attempts[:upload]).to eq(1)
    end

    # The 0.16.8 wedge's timing: the name stayed 422 already_exists-blocked
    # ~15 s PAST the deletion's visible absence — the manual repair that
    # worked was "gone, grace, then upload". The confirmed absence pays
    # DELETION_PROPAGATION_GRACE before the next POST.
    it "pays a grace after the confirmed absence, before the re-upload" do
      store.assets << FakeAsset.new(7, "SHA256SUMS.txt", "https://download.test/SHA256SUMS.txt")
      store.delete_propagation = 2
      file = @dir.join("SHA256SUMS.txt").tap { |path| path.write("new sums") }

      fake_manager.force_upload(release, file)

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq(["SHA256SUMS.txt"])
      expect(store.attempts[:upload]).to eq(1)
      expect(fake_manager).to have_received(:sleep).with(TebakoRelease::Uploader::DELETION_PROPAGATION_GRACE).once
    end

    # The 0.16.8 wedge in miniature: the delete HAS left the listing, yet
    # the same-name POST still 422s already_exists (the upload validator's
    # replica lags the listing). The handler re-runs the delete+poll cycle
    # once more (the delete is a no-op — nothing is listed — and the poll
    # is trivially green, so the operative half is the grace), and the
    # retry lands instead of burning the per-asset budget on blind POSTs.
    it "re-cycles the deletion wait once more when a 422 outlives the listing absence" do
      # The recovery replace's trigger: the listed digest disagrees with
      # the local bytes and no previous entry covers the name.
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      asset = FakeAsset.new(7, exe.basename.to_s, "https://download.test/#{exe.basename}")
      asset.digest = "sha256:#{"1" * 64}"
      store.assets << asset
      allow(fake_manager).to receive(:current_shas)
        .and_return(exe.basename.to_s => Digest::SHA256.hexdigest(exe.read))
      store.fail_next(:upload, Octokit::UnprocessableEntity.new) # the name is still blocked though unlisted

      fake_manager.upload_package(release, exe)

      expect(store.deletes).to eq([7])
      expect(store.attempts[:upload]).to eq(2)
      expect(store.uploads).to eq([exe.basename.to_s])
      # once after the delete's confirmed absence, once on the 422 re-cycle
      expect(fake_manager).to have_received(:sleep).with(TebakoRelease::Uploader::DELETION_PROPAGATION_GRACE).twice
    end

    # Metadata is derivable (a pure function of the package's served
    # bytes), so already-current metadata — the listing's digest matches
    # the content's sha — never re-uploads, never deletes.
    it "skips a metadata asset whose listed digest already matches the content" do
      content = "#{"0" * 64}  pkg-a\n"
      asset = FakeAsset.new(7, "pkg-a.sha256", "https://download.test/pkg-a.sha256")
      asset.digest = "sha256:#{Digest::SHA256.hexdigest(content)}"
      store.assets << asset

      expect { fake_manager.ensure_metadata_asset(release, "pkg-a.sha256", content) }
        .to output(/already current/).to_stdout
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end

    # Read-first: the served bytes already match → no mutation at all
    # (the delete-then-reupload pair is the API's most race-prone move).
    it "force_upload makes no mutation when the served metadata already matches" do
      file = @dir.join("SHA256SUMS.txt").tap { |path| path.write("sums bytes") }
      store.set_content(
        "https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{SPEC_VERSION}/SHA256SUMS.txt",
        "sums bytes"
      )

      expect { fake_manager.force_upload(release, file) }.to output(/already current/).to_stdout
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end

    # The listing lags behind the edge: a landed asset can be unlisted yet
    # serving its bytes. The canonical URL fallback accepts it by content.
    it "accepts a landed duplicate via the canonical URL when the listing misses" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.set_content(
        "https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{SPEC_VERSION}/#{exe.basename}",
        exe.read
      )
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to output(/already on the release with matching content/).to_stdout
      expect(store.attempts[:upload]).to eq(1)
    end

    # The 2026-08-03 night: a deleted name 422'd re-uploads for >25 min
    # while replicas disagreed. The convergence loop cycles read-first →
    # delete → upload → verify until the edge serves our bytes.
    it "converges the metadata across a flapping backend" do
      file = @dir.join("SHA256SUMS.txt").tap { |path| path.write("fresh sums") }
      url = "https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{SPEC_VERSION}/SHA256SUMS.txt"
      store.assets << FakeAsset.new(7, "SHA256SUMS.txt", "https://download.test/SHA256SUMS.txt")
      store.set_content(url, "stale sums")
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)

      expect { fake_manager.force_upload(release, file) }
        .to output(/already current on the release/).to_stdout
      expect(store.uploads).to eq(["SHA256SUMS.txt"])
    end

    # …but never forever: an unconvergeable name is a named failure.
    it "raises when the metadata never converges within the budget" do
      file = @dir.join("SHA256SUMS.txt").tap { |path| path.write("fresh sums") }
      store.set_content(
        "https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{SPEC_VERSION}/SHA256SUMS.txt",
        "stale sums"
      )
      (4 * TebakoRelease::Uploader::METADATA_CONVERGENCE_DELAYS.size).times do
        store.fail_next(:upload, Octokit::UnprocessableEntity.new)
      end

      expect { fake_manager.force_upload(release, file) }
        .to raise_error(/could not converge SHA256SUMS\.txt/)
    end

    # A metadata asset whose bytes DRIFTED is debris from an interrupted
    # publish (metadata is derivable; payloads alone are byte-immutable):
    # the convergence loop replaces it — delete, re-upload, verify.
    it "replaces a metadata asset whose bytes drifted" do
      store.assets << FakeAsset.new(7, "pkg-a.sha256", "https://download.test/pkg-a.sha256")

      fake_manager.ensure_metadata_asset(release, "pkg-a.sha256", "#{"1" * 64}  pkg-a\n")

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq(["pkg-a.sha256"])
    end

    it "raises after the upload attempts are exhausted" do
      (TebakoRelease::Uploader::UPLOAD_RETRY_DELAYS.size + 1).times { store.fail_next(:upload, Faraday::TimeoutError.new) }
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to raise_error(Faraday::TimeoutError)
      expect(store.attempts[:upload]).to eq(TebakoRelease::Uploader::UPLOAD_RETRY_DELAYS.size + 1)
    end

    it "retries transport-level drops on the upload path (stale keep-alive SSL EOF), escalating" do
      store.fail_next(:upload, OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof while reading"))
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      fake_manager.perform_upload(release, exe, exe.basename.to_s)

      expect(store.attempts[:upload]).to eq(2)
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    it "retries transient timeouts on idempotent calls" do
      calls = 0
      result = fake_manager.with_transient_retries do
        calls += 1
        raise Faraday::ConnectionFailed, "refused" if calls < 3

        "ok"
      end

      expect(result).to eq("ok")
      expect(calls).to eq(3)
    end

    it "retries transport-level drops (a stale keep-alive answered with SSL EOF)" do
      calls = 0
      result = fake_manager.with_transient_retries do
        calls += 1
        raise OpenSSL::SSL::SSLError, "SSL_read: unexpected eof while reading" if calls < 2

        "ok"
      end

      expect(result).to eq("ok")
      expect(calls).to eq(2)
    end

    it "keeps an existing asset (byte-immutable per name, absolutely)" do
      store.assets << FakeAsset.new(7, "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end

    # tebako-runtime-ruby#189: a FORCE_REBUILD delete→re-upload wedged 51
    # legs of the 0.16.28 republish; only recreating the release OBJECT
    # freed the names. The env is inert uploader-side now — force
    # republication is the coordinator's recreate-the-object, never a
    # per-asset delete here.
    it "keeps the asset even with FORCE_REBUILD set (the env is inert uploader-side)" do
      ENV["FORCE_REBUILD"] = "true"
      store.assets << FakeAsset.new(7, "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end

    it "looks assets up through the paginated assets rel, not the embedded array" do
      fake_manager.find_asset(release, "anything")

      expect(release.rels[:assets].gets).to eq(1)
    end
  end

  # The 0.16.6 publish (run 32602525094) died at the finalize: the
  # publish's ~1000 listing re-reads drained the tebako-ci token's
  # 5000-request hourly window in ~30 minutes and the next GET 403'd.
  # A rate-limit response now rides the window out (budget-bounded),
  # never dying on the response itself, never spending transient attempts.
  describe "rate-limit resilience" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }

    before { allow(fake_manager).to receive(:sleep) }

    def too_many_requests(headers = {})
      Octokit::TooManyRequests.new(status: 403, body: "API rate limit exceeded", response_headers: headers)
    end

    it "sleeps until the window's named reset and retries instead of dying" do
      reset = Time.now.to_i + 30
      store.fail_next(:listing, too_many_requests("x-ratelimit-reset" => reset.to_s))

      expect(fake_manager.all_assets(release)).to eq([])
      expect(store.attempts[:listing]).to eq(2)
      expect(fake_manager).to have_received(:sleep).with(a_value_between(25, 36))
    end

    it "honors the Retry-After header when no reset is named" do
      store.fail_next(:listing, too_many_requests("retry-after" => "17"))

      fake_manager.all_assets(release)

      expect(fake_manager).to have_received(:sleep).with(a_value_between(17, 23))
    end

    it "waits a default minute when the response names neither reset nor retry-after" do
      store.fail_next(:listing, too_many_requests)

      fake_manager.all_assets(release)

      expect(fake_manager).to have_received(:sleep).with(TebakoRelease::Uploader::RATE_LIMIT_DEFAULT_WAIT)
    end

    it "never spends transient attempts on rate-limit responses" do
      5.times { store.fail_next(:listing, too_many_requests("retry-after" => "1")) }

      fake_manager.all_assets(release)

      expect(store.attempts[:listing]).to eq(6)
    end

    it "rides out a rate-limited upload POST" do
      store.fail_next(:upload, too_many_requests("retry-after" => "1"))
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      fake_manager.perform_upload(release, exe, exe.basename.to_s)

      expect(store.attempts[:upload]).to eq(2)
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    it "gives up loudly when the wait outlasts two full hourly windows" do
      reset = Time.now.to_i + TebakoRelease::Uploader::RATE_LIMIT_BUDGET + 60
      store.fail_next(:listing, too_many_requests("x-ratelimit-reset" => reset.to_s))

      expect { fake_manager.all_assets(release) }
        .to raise_error(TebakoRelease::Uploader::RateLimitBudgetExhausted, /rate-limit/)
      expect(fake_manager).not_to have_received(:sleep)
    end
  end

  # The 0.16.6 token drain's other half: every own-mutation invalidated
  # the listing memo, re-fetching ~4 pages per upload/delete/poll at
  # catalog size. The memo now updates in place (an upload appends the
  # response's record, a delete drops by id) and the propagation wait
  # polls a bounded single-asset read — the listing is fetched ONCE.
  describe "asset listing memo updates in place" do
    let(:store) { FakeAssetStore.new(["existing.tgz"]) }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }

    before { allow(fake_manager).to receive(:sleep) }

    def listing_reads
      release.rels[:assets].gets
    end

    it "records an upload in the memo without a re-listing" do
      fake_manager.find_asset(release, "existing.tgz") # populates the memo
      expect(listing_reads).to eq(1)

      file = @dir.join("new.tgz").tap { |path| path.write("new bytes") }
      fake_manager.upload_once(release, file, "new.tgz")

      expect(fake_manager.find_asset(release, "new.tgz")).not_to be_nil
      expect(listing_reads).to eq(1)
    end

    it "drops a deleted asset from the memo without a re-listing" do
      fake_manager.find_asset(release, "existing.tgz")
      expect(listing_reads).to eq(1)

      fake_manager.remove_existing_asset(release, "existing.tgz")

      expect(fake_manager.find_asset(release, "existing.tgz")).to be_nil
      expect(listing_reads).to eq(1)
    end

    it "polls deletion propagation by single-asset reads, never re-listing" do
      store.delete_propagation = 2 # the deletion clears on the third poll
      fake_manager.find_asset(release, "existing.tgz")
      expect(listing_reads).to eq(1)

      fake_manager.remove_existing_asset(release, "existing.tgz")

      expect(store.deletes).to eq([1])
      expect(listing_reads).to eq(1)
    end
  end

  # 2026-08-20 incident (run 32346716268, "Publish the runtime packages"):
  # one wedged exe/.tfs pair burned the full 150-minute step timeout, zero
  # of 338 assets updated. The three wounds, spec-locked: the
  # deletion-propagation wait is wall-clock-bounded and ends in a named
  # error (it sleeps between polls, never spins, never silently gives up);
  # a settled asset is never re-attempted within the run — the workspace
  # ledger carries the settlement across the per-platform invocations (no
  # exe<->tfs ping-pong); and the per-asset wall-clock cap bounds a
  # fully-wedged asset's effort.
  describe "wedged asset settlement (2026-08-20)" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }

    before { allow(fake_manager).to receive(:sleep) }

    it "sleeps between deletion-propagation polls until the asset leaves the listing" do
      store.assets << FakeAsset.new(7, "asset.tgz", "https://download.test/asset.tgz")
      store.delete_propagation = 2 # the listing clears on the third poll

      expect { fake_manager.remove_existing_asset(release, "asset.tgz") }
        .to output(/Waiting for the deletion of asset\.tgz to propagate/).to_stdout
      expect(fake_manager).to have_received(:sleep)
        .with(TebakoRelease::Uploader::DELETION_PROPAGATION_POLL_INTERVAL).exactly(:twice)
    end

    it "times out with a named error when the deletion never propagates" do
      store.assets << FakeAsset.new(7, "asset.tgz", "https://download.test/asset.tgz")
      allow(fake_manager).to receive(:monotonic_now).and_return(0.0, 60.0, 120.0, 190.0)

      expect { fake_manager.wait_for_absence(release, "asset.tgz", store.assets.first) }
        .to raise_error(TebakoRelease::Uploader::DeletionPropagationTimeout,
                        /asset\.tgz has not propagated within 180s/)
    end

    it "demotes the propagation timeout to a loud warning at the delete call sites" do
      store.assets << FakeAsset.new(7, "asset.tgz", "https://download.test/asset.tgz")
      store.delete_propagation = 999 # the delete never clears the listing
      allow(fake_manager).to receive(:monotonic_now).and_return(0.0, 190.0)

      expect { fake_manager.remove_existing_asset(release, "asset.tgz") }
        .to output(/::warning::the deletion of asset\.tgz has not propagated/).to_stdout
      expect(store.deletes).to eq([7])
    end

    # The incident's shape: the wedged exe warn-kept, then its own .tfs
    # re-entered the replace path — and the next platform invocation
    # re-attempted the exe. A settled asset is never attempted again in
    # the run, and its facets stand down with it. (The settle now happens
    # through the byte-immutable keep — zero replace attempts.)
    it "never re-attempts a settled asset and stands its .tfs facet down" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      tfs = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
      url = "https://download.test/#{exe.basename}"
      previous = { filename: exe.basename.to_s, sha256: "1" * 64, platform: "macos-arm64",
                   image: { filename: tfs.basename.to_s, sha256: "2" * 64, size_bytes: 1 } }
      store.assets << FakeAsset.new(7, exe.basename.to_s, url)
      allow(fake_manager).to receive(:previous_manifest_entries).and_return([previous])
      allow(fake_manager).to receive(:current_shas)
        .and_return(exe.basename.to_s => Digest::SHA256.hexdigest(exe.read))

      expect { fake_manager.upload_package(release, exe) }
        .to output(/keeping the previous asset/).to_stdout
      expect(store.attempts[:upload]).to eq(0)

      expect { fake_manager.upload_package(release, exe) }
        .to output(/never re-attempted/).to_stdout
      expect { fake_manager.upload_package(release, tfs) }
        .to output(/never re-attempted/).to_stdout
      expect(store.attempts[:upload]).to eq(0)
    end

    # The publish step runs one upload_release.rb process per platform;
    # the settlement must survive the process boundary or each invocation
    # re-burns the wedge (the incident's 3x 20-minute re-attempts).
    it "carries the settlement across the per-platform invocations via the workspace ledger" do
      fake_manager.settle_asset!("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-arm64")

      second = described_class.new(client: FakeClient.new(store))
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-arm64")

      expect { second.upload_package(release, exe) }
        .to output(/never re-attempted/).to_stdout
      expect(store.attempts[:upload]).to eq(0)
      expect(store.deletes).to be_empty
    end

    # The 0.16.6 re-publish's kill shot, pre-empted: a rebuilt .tfs facet
    # whose bytes differ from the published asset's warn-keeps BEFORE any
    # replace is attempted — no delete, no upload (the delete+re-upload
    # of a differing same-name asset is exactly what wedged the name
    # server-side) — settling the whole package stem so effective_entry
    # reverts the package's published metadata (byte-truthful for the
    # published bytes).
    it "keeps a byte-differing .tfs facet without a replace attempt (byte-immutable per name)" do
      tfs = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
      url = "https://download.test/#{tfs.basename}"
      asset = FakeAsset.new(7, tfs.basename.to_s, url)
      asset.digest = "sha256:#{"2" * 64}"
      store.assets << asset
      previous = { filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64", sha256: "1" * 64,
                   platform: "macos-arm64",
                   image: { filename: tfs.basename.to_s, sha256: "2" * 64, size_bytes: 1 } }
      allow(fake_manager).to receive(:previous_manifest_entries).and_return([previous])
      allow(fake_manager).to receive(:current_shas)
        .and_return(tfs.basename.to_s => Digest::SHA256.file(tfs).hexdigest)

      expect { fake_manager.upload_package(release, tfs) }
        .to output(/keeping the previous asset/).to_stdout
      expect(store.attempts[:upload]).to eq(0)
      expect(store.deletes).to be_empty
      expect(fake_manager.settled?(tfs.basename.to_s)).to be(true)
    end

    # A LATER invocation builds fresh entries for the wedged platform;
    # without the ledger-driven revert the package's shard/sidecars would
    # describe bytes the release does not serve.
    it "reverts a settled package's fresh manifest entry in later invocations too" do
      fake_manager.settle_asset!("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      previous = { filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
                   sha256: "1" * 64, platform: "macos-arm64" }
      fresh = { filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
                sha256: "9" * 64, platform: "macos-arm64" }

      second = described_class.new(client: FakeClient.new(store))
      allow(second).to receive(:previous_manifest_entries).and_return([previous])

      expect(second.effective_entry(fresh)).to eq(previous)
    end

    # A fully-wedged asset: every POST 422s, every delete never
    # propagates. The per-asset cap ends the effort inside the budget
    # instead of grinding the whole escalating delay series (the
    # incident's ~20 minutes per asset per invocation).
    it "bounds a fully-wedged asset by the per-asset wall-clock cap" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      store.delete_propagation = 999
      store.assets << FakeAsset.new(7, exe.basename.to_s, url)
      store.set_content(url, "previous bytes")
      clock = 0.0
      allow(fake_manager).to receive(:monotonic_now) { clock += 120.0 }

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to raise_error(Octokit::UnprocessableEntity)
        .and output(/per-asset upload budget \(300s\) is exhausted/).to_stdout
      expect(store.attempts[:upload]).to eq(1)
    end

    it "prints the end-of-step summary naming every kept package" do
      fake_manager.settle_asset!("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      fake_manager.settle_asset!("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-arm64.tfs")

      expect { fake_manager.print_settled_summary }
        .to output(/Publish summary: 2 package\(s\) kept their previous bytes.*linux-gnu-arm64.*macos-arm64/m)
        .to_stdout
    end

    it "stays silent when nothing wedged" do
      expect { fake_manager.print_settled_summary }.not_to output(/.+/).to_stdout
    end
  end

  # Raw rel gets are NOT auto-paginated (auto_paginate covers client
  # methods only): with 100+ assets, a first-page-only lookup silently
  # misses — then the publish re-uploads an existing asset, and a timeout
  # on that upload becomes the 422 cascade. all_assets walks the pages.
  describe "asset listing pagination" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }

    it "finds an asset that only exists past page one" do
      store.page_size = 30
      40.times { |i| store.assets << FakeAsset.new(i + 1, "asset-#{format("%02d", i)}") }
      store.assets << FakeAsset.new(99, "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      expect(fake_manager.find_asset(release, "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"))
        .not_to be_nil
    end

    it "skips re-uploading an existing asset that only exists past page one" do
      store.page_size = 30
      40.times { |i| store.assets << FakeAsset.new(i + 1, "asset-#{format("%02d", i)}") }
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(99, exe.basename.to_s)

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      expect(store.uploads).to be_empty
    end

    it "verify_completeness sees assets past page one" do
      store.page_size = 30
      40.times { |i| store.assets << FakeAsset.new(i + 1, "asset-#{format("%02d", i)}") }
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      [stem, "#{stem}.tfs", "#{stem}.manifest.json", "#{stem}.sha256", "#{stem}.tfs.sha256"]
        .each_with_index do |name, index|
        store.assets << FakeAsset.new(100 + index, name)
      end

      expect { fake_manager.verify_completeness(release) }.not_to raise_error
    end
  end

  # The per-platform publish: each platform leg republishes only its own
  # packages and writes only its own packages' metadata (sidecars +
  # shard — issue 139; NOTHING merges into a shared file). The idempotent
  # skip keeps an unchanged asset from re-uploading (same name + same
  # sha256), and the byte-immutable keep's byte-truth revert now speaks
  # through effective_entry.
  describe "per-package metadata and idempotent skip" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: client) }
    let(:client) { FakeClient.new(store) }

    before { allow(fake_manager).to receive(:sleep) }

    def previous_manifest(entries)
      store.manifest_json = JSON.generate(entries)
      store.assets << FakeAsset.new(90, "manifest.json", "https://download.test/manifest.json")
    end

    def previous_entry(filename, platform, sha256, image_sha256: nil)
      entry = { "tebako_version" => SPEC_VERSION, "filename" => filename,
                "platform" => platform, "sha256" => sha256, "size_bytes" => 1 }
      entry["image"] = { "filename" => "#{filename}.tfs", "sha256" => image_sha256, "size_bytes" => 1 } if image_sha256
      entry
    end

    # Spec 13 §2a: the shards are the previous-entry authority — this leg
    # reads only the shards its expected matrix names, symbolized, image
    # facet included.
    it "reads this leg's previous entries from the shards (the authority)" do
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      other = "tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64"
      entry = { "filename" => stem, "platform" => "macos-arm64", "sha256" => "c" * 64, "size_bytes" => 10,
                "image" => { "filename" => "#{stem}.tfs", "sha256" => "d" * 64, "size_bytes" => 20 } }
      store.assets << FakeAsset.new(90, "#{stem}.manifest.json", "https://download.test/#{stem}.manifest.json")
      store.set_content("https://download.test/#{stem}.manifest.json", JSON.generate(entry))
      # Another platform's shard: outside this leg's expected matrix —
      # never downloaded, never returned.
      store.assets << FakeAsset.new(91, "#{other}.manifest.json", "https://download.test/#{other}.manifest.json")
      store.set_content("https://download.test/#{other}.manifest.json",
                        JSON.generate({ "filename" => other, "platform" => "linux-gnu-x86_64",
                                        "sha256" => "e" * 64, "size_bytes" => 1 }))

      entries = fake_manager.previous_manifest_entries

      expect(entries.map { |e| e[:filename] }).to eq([stem])
      expect(entries.first[:image][:sha256]).to eq("d" * 64)
      expect(fake_manager.previous_entry_for(stem)[:sha256]).to eq("c" * 64)
    end

    # The pre-de-rendezvous migration window: a stem no shard covers falls
    # back to the monolithic manifest.json — loudly, scoped to this leg's
    # matrix, never an error.
    it "covers a shard-less expected stem from the monolith, loudly (the migration window)" do
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      previous_manifest([
                          previous_entry("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64",
                                         "linux-gnu-x86_64", "a" * 64, image_sha256: "b" * 64),
                          previous_entry(stem, "macos-arm64", "c" * 64)
                        ])

      entries = nil
      expect { entries = fake_manager.previous_manifest_entries }
        .to output(/pre-de-rendezvous migration window.*#{Regexp.escape(stem)}/).to_stdout

      # The out-of-matrix monolith entry stays unread for this leg.
      expect(entries.map { |e| e[:filename] }).to eq([stem])
      expect(fake_manager.previous_entry_for(stem)[:sha256]).to eq("c" * 64)
    end

    # An unscoped invocation (no expected matrix — the ad-hoc/operator
    # case) reads every shard, the pre-de-rendezvous behavior's successor.
    it "reads every shard when no expected matrix scopes the invocation" do
      ENV.delete("EXPECTED_ENV_MATRIX")
      ENV.delete("EXPECTED_RUBY_MATRIX")
      stems = ["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
               "tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64"]
      stems.each_with_index do |stem, index|
        store.assets << FakeAsset.new(90 + index, "#{stem}.manifest.json",
                                      "https://download.test/#{stem}.manifest.json")
        store.set_content("https://download.test/#{stem}.manifest.json",
                          JSON.generate({ "filename" => stem, "sha256" => index.to_s * 64, "size_bytes" => 1 }))
      end

      expect(fake_manager.previous_manifest_entries.map { |e| e[:filename] }).to eq(stems)
    end

    it "covers a facet lookup through the package entry (previous_entry_covering)" do
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      previous_manifest([previous_entry(stem, "macos-arm64", "a" * 64, image_sha256: "b" * 64)])

      covering = fake_manager.previous_entry_covering("#{stem}.tfs")

      expect(covering[:filename]).to eq(stem)
      expect(fake_manager.previous_entry_covering("tebako-runtime-#{SPEC_VERSION}-9.9.9-nowhere")).to be_nil
    end

    it "skips re-uploading an asset whose content is unchanged (same name, same sha256)" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s)
      previous_manifest([previous_entry(exe.basename.to_s, "macos-arm64", Digest::SHA256.file(exe).hexdigest)])
      fake_manager.build_manifest_entries([exe])

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end

    # Byte-immutability (owner-locked, the 0.16.6 re-publish): the build
    # is not bit-reproducible, so a re-publish's rebuilt package almost
    # always differs from the published bytes — and the delete+re-upload
    # of a differing same-name asset is exactly what wedged the name
    # server-side (POST 422 cycles ~7 min apart until the per-asset
    # budget died). Same name + different bytes keeps
    # the published asset — no delete, no upload, a loud ::warning naming
    # both shas — and the manifest entry reverts to the published sha
    # (byte-truthful). The refresh needs a republish onto a recreated
    # release object (the coordinator's force_rebuild).
    it "keeps the published asset when the rebuilt bytes differ (byte-immutable per name)" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s)
      previous_manifest([previous_entry(exe.basename.to_s, "macos-arm64", "f" * 64)])
      entries = fake_manager.build_manifest_entries([exe])
      local_sha = Digest::SHA256.file(exe).hexdigest

      expect { fake_manager.upload_package(release, exe) }
        .to output(/::warning::#{Regexp.escape(exe.basename.to_s)}.*different bytes.*#{"f" * 12}.*#{local_sha[0, 12]}/)
        .to_stdout
      expect(store.deletes).to be_empty
      expect(store.uploads).to be_empty
      expect(fake_manager.effective_entry(entries.first)[:sha256]).to eq("f" * 64)
    end

    # Missing is not different bytes: a name the release does not carry
    # uploads fresh (the recovery path), and the completeness gate still
    # fails when an expected name never lands.
    it "uploads a fresh asset the release does not carry" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      fake_manager.build_manifest_entries([exe])

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      expect(store.uploads).to eq([exe.basename.to_s])
      expect(store.deletes).to be_empty
    end

    # No uploader-side exception to byte-immutability (tebako-runtime-ruby#189):
    # FORCE_REBUILD set, previous entry covering, bytes differing — the keep
    # still stands; the refresh is the coordinator's recreated release object.
    it "keeps a byte-differing published asset even under FORCE_REBUILD" do
      ENV["FORCE_REBUILD"] = "true"
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s)
      previous_manifest([previous_entry(exe.basename.to_s, "macos-arm64", "f" * 64)])
      fake_manager.build_manifest_entries([exe])

      fake_manager.upload_package(release, exe)

      expect(store.deletes).to be_empty
      expect(store.uploads).to be_empty
      expect(fake_manager.settled?(exe.basename.to_s)).to be(true)
    end

    it "keeps an existing asset when the previous manifest is unreadable (fail conservative)" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s)
      store.assets << FakeAsset.new(90, "manifest.json", "https://download.test/manifest.json")
      store.manifest_json = "not json {"
      fake_manager.build_manifest_entries([exe])

      expect do
        expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      end.to output(/could not read the previous manifest/).to_stdout
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end

    it "re-uploads a listed asset whose upload never committed (state \"starter\")" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s, nil, nil, "starter")
      previous_manifest([previous_entry(exe.basename.to_s, "macos-arm64", Digest::SHA256.file(exe).hexdigest)])
      fake_manager.build_manifest_entries([exe])

      fake_manager.upload_package(release, exe)

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    it "re-uploads a listed asset with no previous manifest entry when the listing digest differs" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s).tap { |a| a.digest = "sha256:#{"0" * 64}" }
      fake_manager.build_manifest_entries([exe])

      fake_manager.upload_package(release, exe)

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    it "keeps a listed asset with no previous manifest entry when the listing digest matches" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s)
                               .tap { |a| a.digest = "sha256:#{Digest::SHA256.file(exe).hexdigest}" }
      fake_manager.build_manifest_entries([exe])

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end
  end

  describe "process_release completeness enforcement" do
    let(:store) { FakeAssetStore.new }
    let(:client) { FakeClient.new(store) }
    let(:fake_manager) { described_class.new(client: client) }

    before { allow(fake_manager).to receive(:sleep) }

    def stage_packages(*names)
      dir = @dir.join("runtime-packages")
      dir.mkdir
      names.each do |name|
        path = dir.join(name)
        path.write("bytes-of-#{name}")
        write_contract_sidecar(path) unless name.end_with?(".tfs")
      end
    end

    it "publishes the payloads and their per-package metadata, touching no shared file" do
      stage_packages("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
                     "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")

      with_packages { fake_manager.process_release }

      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      expect(store.uploads).to contain_exactly(stem, "#{stem}.tfs",
                                               "#{stem}.manifest.json", "#{stem}.sha256", "#{stem}.tfs.sha256")
      # No shared file exists anymore (spec 13 §2a): the monoliths are
      # consumer-side derivations and the notes are written once at
      # release creation — a platform publish never writes either.
      expect(store.uploads).not_to include("SHA256SUMS.txt", "manifest.json")
      expect(store.updates).to be_empty
    end

    # The 0.16.6 re-publish end-to-end: the release already carries the
    # earlier attempt's payload assets and the rebuild is not
    # byte-identical. Keep-first-wins: the payloads are never deleted or
    # re-uploaded (the delete+re-upload is what wedged the names
    # server-side), a loud warning names the keep, and the published
    # shard + sidecars describe the PUBLISHED bytes (byte-truthful).
    it "keeps a byte-differing rebuilt package and publishes byte-truthful metadata" do
      stage_packages("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
                     "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
      exe_name = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      store.assets << FakeAsset.new(7, exe_name, "https://download.test/#{exe_name}")
      store.assets << FakeAsset.new(8, "#{exe_name}.tfs", "https://download.test/#{exe_name}.tfs")
      store.manifest_json = JSON.generate(
        [{ "tebako_version" => SPEC_VERSION, "filename" => exe_name, "platform" => "macos-arm64",
           "sha256" => "e" * 64, "size_bytes" => 1,
           "image" => { "filename" => "#{exe_name}.tfs", "sha256" => "1" * 64, "size_bytes" => 1 } }]
      )
      store.assets << FakeAsset.new(90, "manifest.json", "https://download.test/manifest.json")

      with_packages do
        expect { fake_manager.process_release }.to output(/keeping the previous asset/).to_stdout
      end
      expect(store.deletes).not_to include(7, 8)
      expect(store.uploads).not_to include(exe_name, "#{exe_name}.tfs")
      shard = JSON.parse(store.content_for("https://download.test/#{exe_name}.manifest.json"))
      expect(shard["sha256"]).to eq("e" * 64)
      expect(shard["image"]["sha256"]).to eq("1" * 64)
      expect(store.content_for("https://download.test/#{exe_name}.sha256"))
        .to eq("#{"e" * 64}  #{exe_name}\n")
      expect(store.content_for("https://download.test/#{exe_name}.tfs.sha256"))
        .to eq("#{"1" * 64}  #{exe_name}.tfs\n")
    end

    it "fails the publish when an expected package never lands" do
      stage_packages("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64",
                     "tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64.tfs")

      with_packages do
        expect { fake_manager.process_release }
          .to raise_error(/incomplete \(2 missing/)
          .and output(/::error::Missing asset: tebako-runtime-#{SPEC_VERSION}-3\.3\.7-macos-arm64/).to_stdout
      end
    end

    # AUDIT_ONLY (the 04 audit / a publish dry run): strictly read-only —
    # no uploads, no notes, no local packages needed; the release is only
    # verified against the expected matrix.
    it "audit mode uploads nothing and passes when the release is complete" do
      ENV["AUDIT_ONLY"] = "true"
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      [stem, "#{stem}.tfs", "#{stem}.manifest.json", "#{stem}.sha256", "#{stem}.tfs.sha256"]
        .each_with_index do |name, index|
        store.assets << FakeAsset.new(index + 1, name, "https://download.test/#{name}")
      end

      expect { fake_manager.process_release }.to output(/AUDIT mode/).to_stdout
      expect(store.uploads).to be_empty
      expect(store.updates).to be_empty
    end

    it "audit mode fails an incomplete release, still uploading nothing" do
      ENV["AUDIT_ONLY"] = "true"

      expect { fake_manager.process_release }
        .to raise_error(/incomplete \(2 missing/)
        .and output(/AUDIT mode/).to_stdout
      expect(store.uploads).to be_empty
      expect(store.updates).to be_empty
    end

    it "audit mode refuses a tag with no release (and never creates one)" do
      ENV["AUDIT_ONLY"] = "true"
      allow(client).to receive(:release_for_tag).and_raise(Octokit::NotFound)

      expect { fake_manager.process_release }
        .to raise_error(/no release found for tag/)
    end
  end

  # Issue 139: the release's asset listing IS the package index. Every
  # payload asset carries a `<asset>.sha256` sidecar (the store's
  # trust-anchor shape, spec 00 §8) and every package a
  # `<stem>.manifest.json` shard holding exactly its manifest entry —
  # uploaded by the job that built the package, never merged.
  describe "per-package metadata (issue 139)" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }
    let(:stem) { "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64" }

    before { allow(fake_manager).to receive(:sleep) }

    it "publishes the shard as the package's manifest entry and a coreutils sidecar per asset" do
      exe = package(stem)
      img = package("#{stem}.tfs")
      entry = fake_manager.build_manifest_entries([exe, img]).first

      fake_manager.ensure_package_metadata(release, entry)

      shard = JSON.parse(store.content_for("https://download.test/#{stem}.manifest.json"))
      expect(shard["filename"]).to eq(stem)
      expect(shard["sha256"]).to eq(Digest::SHA256.file(exe).hexdigest)
      expect(shard["image"]["filename"]).to eq("#{stem}.tfs")
      expect(shard["image"]["sha256"]).to eq(Digest::SHA256.file(img).hexdigest)
      expect(store.content_for("https://download.test/#{stem}.sha256"))
        .to eq("#{Digest::SHA256.file(exe).hexdigest}  #{stem}\n")
      expect(store.content_for("https://download.test/#{stem}.tfs.sha256"))
        .to eq("#{Digest::SHA256.file(img).hexdigest}  #{stem}.tfs\n")
    end

    it "is idempotent: a second publish of the same bytes uploads no metadata" do
      exe = package(stem)
      entry = fake_manager.build_manifest_entries([exe]).first
      fake_manager.ensure_package_metadata(release, entry)
      expect(store.uploads).to contain_exactly("#{stem}.manifest.json", "#{stem}.sha256")

      expect { fake_manager.ensure_package_metadata(release, entry) }
        .to output(/already current/).to_stdout
      expect(store.uploads).to contain_exactly("#{stem}.manifest.json", "#{stem}.sha256")
      expect(store.deletes).to be_empty
    end

    it "publishes the PREVIOUS entry's metadata for a settled package (byte-truthful)" do
      exe = package(stem)
      fake_manager.settle_asset!(stem)
      previous = { filename: stem, sha256: "f" * 64, platform: "macos-arm64" }
      allow(fake_manager).to receive(:previous_manifest_entries).and_return([previous])
      entry = fake_manager.build_manifest_entries([exe]).first

      fake_manager.ensure_package_metadata(release, entry)

      shard = JSON.parse(store.content_for("https://download.test/#{stem}.manifest.json"))
      expect(shard["sha256"]).to eq("f" * 64)
      expect(store.content_for("https://download.test/#{stem}.sha256")).to eq("#{"f" * 64}  #{stem}\n")
    end
  end

  # Spec 13 §2a's de-rendezvous: N legs create the release concurrently.
  # The create is the natural race — find-miss then create meets another
  # leg's create — and the loser's 422 rides the winner's release once it
  # becomes visible. Never an error in itself.
  describe "the race-safe release create" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:client) { FakeClient.new(store) }
    let(:fake_manager) { described_class.new(client: client) }

    before { allow(fake_manager).to receive(:sleep) }

    it "returns the existing release without creating when the tag resolves" do
      expect(fake_manager.get_or_create_release.url).to eq(release.url)
      expect(store.creates).to be_empty
    end

    it "creates the release with the static notes when the tag is missing" do
      allow(client).to receive(:release_for_tag).and_raise(Octokit::NotFound)

      expect(fake_manager.get_or_create_release.url).to eq(release.url)

      expect(store.creates.size).to eq(1)
      body = store.creates.first.fetch(:body)
      # Static notes (spec 13 §2a): they point at the shards + sidecars,
      # the consumer-side index derivation, and the registry — never an
      # asset enumeration (a read-modify-write in disguise).
      expect(body).to include("manifest.json` shard", "release-index entry", "tpkg-registry.yaml")
      expect(body).not_to include("### macOS", "### Windows")
    end

    it "rides the winner's release when the create loses the race (422)" do
      # The find misses, the create 422s (a concurrent leg won), and the
      # winner's release becomes visible on the first poll.
      responses = %i[raise_not_found return_release]
      allow(client).to receive(:release_for_tag) do
        responses.shift == :raise_not_found ? (raise Octokit::NotFound) : release
      end
      store.fail_next(:create, Octokit::UnprocessableEntity.new)

      expect(fake_manager.get_or_create_release).to eq(release)
      expect(store.attempts[:create]).to eq(1)
    end

    it "fails named when the loser release never becomes visible" do
      allow(client).to receive(:release_for_tag).and_raise(Octokit::NotFound)
      store.fail_next(:create, Octokit::UnprocessableEntity.new)
      stub_const("TebakoRelease::Uploader::RELEASE_CREATE_POLL_DELAYS", [0, 0])

      expect { fake_manager.get_or_create_release }
        .to raise_error(/rejected the create.*never became visible/)
    end
  end

  # Spec 13 §2a / spec 09 §5: on signing-enabled lines every shard entry
  # declares its own `signature` block — {keyid, asc}, the signer's
  # 16-lowercase-hex primary keyid and the exact .asc asset name — at the
  # entry and facet levels. Declared by the factory, flowed verbatim by
  # consumers, fulfilled by the leg's sign pass.
  describe "shard signature declarations" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }

    it "declares signature blocks at entry, image, and dll level when armed" do
      ENV["TEBAKO_RELEASE_SIGNING_ENABLED"] = "true"
      ENV["TEBAKO_RELEASE_SIGNING_KEYID"] = "efc3c250f7862a48"
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64"
      exe = package("#{stem}.exe")
      img = package("#{stem}.tfs")
      dll = package("#{stem}.dll")

      entry = fake_manager.build_manifest_entries([exe, img, dll]).first

      expect(entry[:signature]).to eq(keyid: "efc3c250f7862a48", asc: "#{stem}.exe.asc")
      expect(entry[:image][:signature]).to eq(keyid: "efc3c250f7862a48", asc: "#{stem}.tfs.asc")
      expect(entry[:dll][:signature]).to eq(keyid: "efc3c250f7862a48", asc: "#{stem}.dll.asc")
    end

    it "declares nothing when the line is not signing-enabled (unsigned stays first-class)" do
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      entry = fake_manager.build_manifest_entries([package(stem), package("#{stem}.tfs")]).first

      expect(entry).not_to have_key(:signature)
      expect(entry[:image]).not_to have_key(:signature)
    end

    it "fails fast and named when armed with a malformed keyid" do
      ENV["TEBAKO_RELEASE_SIGNING_ENABLED"] = "true"
      ENV["TEBAKO_RELEASE_SIGNING_KEYID"] = "NOT-HEX"

      expect { described_class.new }
        .to raise_error(/TEBAKO_RELEASE_SIGNING_KEYID must be the signer's 16-lowercase-hex/)
    end

    it "skips the keyid check in audit mode (the audit signs nothing)" do
      ENV["TEBAKO_RELEASE_SIGNING_ENABLED"] = "true"
      ENV["AUDIT_ONLY"] = "true"

      expect { described_class.new }.not_to raise_error
    end
  end

  # Issue 139's migration / repair pass: BACKFILL_METADATA=true writes
  # the missing sidecars (from the listing's server-computed digests —
  # the served bytes' truth) and the missing shards (from the monolithic
  # manifest.json, sha fields re-anchored to the digests) onto a pre-shard
  # release. It never touches a monolith or the notes (spec 13 §2a: the
  # monoliths are consumer-side derivations now, written by no one).
  describe "the backfill pass (issue 139 migration)" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:client) { FakeClient.new(store) }
    let(:fake_manager) { described_class.new(client: client) }

    before { allow(fake_manager).to receive(:sleep) }

    it "writes sidecars from the listing digests and shards from the monolith" do
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      store.assets << FakeAsset.new(7, stem, "https://download.test/#{stem}",
                                    "sha256:#{"a" * 64}")
      store.assets << FakeAsset.new(8, "#{stem}.tfs", "https://download.test/#{stem}.tfs",
                                    "sha256:#{"b" * 64}")
      # The monolith's recorded shas STALE-disagree with the served bytes
      # (the incident class) — the backfill re-anchors to the digests.
      store.manifest_json = JSON.generate(
        [{ "filename" => stem, "platform" => "macos-arm64", "sha256" => "0" * 64, "size_bytes" => 1,
           "image" => { "filename" => "#{stem}.tfs", "sha256" => "2" * 64, "size_bytes" => 2 } }]
      )
      store.assets << FakeAsset.new(90, "manifest.json", "https://download.test/manifest.json")

      with_packages do
        expect { fake_manager.backfill_release }
          .to output(/disagree with the manifest\.json record/).to_stdout
      end

      expect(store.content_for("https://download.test/#{stem}.sha256")).to eq("#{"a" * 64}  #{stem}\n")
      expect(store.content_for("https://download.test/#{stem}.tfs.sha256")).to eq("#{"b" * 64}  #{stem}.tfs\n")
      shard = JSON.parse(store.content_for("https://download.test/#{stem}.manifest.json"))
      expect(shard["sha256"]).to eq("a" * 64)
      expect(shard["image"]["sha256"]).to eq("b" * 64)
      # The monolith is a read-only source here — never rewritten.
      expect(store.updates).to be_empty
      expect(store.uploads).not_to include("manifest.json", "SHA256SUMS.txt")
    end

    it "fails closed when the release carries no monolith to synthesize from" do
      with_packages do
        expect { fake_manager.backfill_release }
          .to raise_error(/BACKFILL needs the release's monolithic manifest\.json/)
      end
    end

    it "fails closed when a listed payload asset is covered by no monolith entry" do
      stem = "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"
      store.assets << FakeAsset.new(7, stem, "https://download.test/#{stem}", "sha256:#{"a" * 64}")
      store.manifest_json = JSON.generate([{ "filename" => "tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64",
                                             "platform" => "linux-gnu-x86_64", "sha256" => "c" * 64,
                                             "size_bytes" => 1 }])
      store.assets << FakeAsset.new(90, "manifest.json", "https://download.test/manifest.json")

      with_packages do
        expect { fake_manager.backfill_release }.to raise_error(/BACKFILL: no manifest\.json entry covers #{stem}/)
      end
    end
  end
end
