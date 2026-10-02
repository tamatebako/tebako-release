# frozen_string_literal: true

require "spec_helper"
require "digest"

# The golden vectors: image bytes are byte[i] = ((i * 31 + 7) % 251),
# the sidecars were minted by tpkg::lazy::Blksum::from_image_bytes +
# render (the product's single owner of the grammar, spec 39 §3) and
# pinned here verbatim — a drift between this render and tpkg's fails
# the suite, never ships.
# name => [image size in bytes, sidecar sha256]
BLKSUM_GOLDENS = {
  "small" => [100_000, "0766530bb8427b1ae98592814e4feb70b6caf218f6b4e9695cee8c3286211afe"],
  "two-groups" => [8_388_608, "3d99d723907732cb42bd209aee0be8a3b6250d532a2981e6ca3af5b9985b0178"],
  "ragged" => [6_000_000, "b25f865430d31741e2a9d5f36db489add05b6e79beda4e57ae9c0e739c2344bc"]
}.freeze

RSpec.describe TebakoRelease::Blksum do
  def golden_bytes(size)
    (0...size).map { |i| ((i * 31) + 7) % 251 }.pack("C*")
  end

  def stage_image(size)
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir).join("image.tfs")
      path.binwrite(golden_bytes(size))
      yield path
    end
  end

  BLKSUM_GOLDENS.each do |name, (size, sidecar_sha)|
    it "renders the #{name} golden byte-exact with tpkg::lazy::Blksum::render" do
      stage_image(size) do |path|
        blksum = described_class.for_image(path)
        golden = File.binread(File.join(REPO_ROOT, "spec", "fixtures", "blksum", "#{name}.blksum.json"))
        expect(blksum.render).to eq(golden)
        expect(blksum.digest).to eq(sidecar_sha)
      end
    end
  end

  it "hashes one sha256 per 4 MiB group, the final group short" do
    stage_image(6_000_000) do |path|
      blksum = described_class.for_image(path)
      bytes = path.binread
      expect(blksum.groups).to eq(
        [Digest::SHA256.hexdigest(bytes[0, 4_194_304]),
         Digest::SHA256.hexdigest(bytes[4_194_304, 6_000_000 - 4_194_304])]
      )
      expect(blksum.size_bytes).to eq(6_000_000)
      expect(blksum.sha256).to eq(Digest::SHA256.hexdigest(bytes))
    end
  end

  it "renders compact machine JSON, keys in schema order, no trailing newline" do
    stage_image(100_000) do |path|
      render = described_class.for_image(path).render
      expect(render).to start_with('{"schema_version":1,"group_size":4194304,"size_bytes":100000,"sha256":"')
      expect(render).to end_with("]}")
      expect(render).not_to include("\n")
    end
  end

  it "refuses an empty image by name (size_bytes >= 1)" do
    stage_image(100) do |path|
      path.binwrite("")
      expect { described_class.for_image(path) }
        .to raise_error(TebakoRelease::Error, /is empty \(size_bytes >= 1\)/)
    end
  end

  it "refuses a missing image by name" do
    expect { described_class.for_image("/nonexistent/image.tfs") }
      .to raise_error(TebakoRelease::Error, /does not exist/)
  end

  it "names the sidecar after the image and recognizes its own" do
    expect(described_class.sidecar_name("tebako-runtime-9.9.9-3.3.7-macos-arm64.tfs"))
      .to eq("tebako-runtime-9.9.9-3.3.7-macos-arm64.tfs.blksum.json")
    expect(described_class.blksum_file?(Pathname.new("x.tfs.blksum.json"))).to be(true)
    expect(described_class.blksum_file?(Pathname.new("x.tfs"))).to be(false)
  end
end
