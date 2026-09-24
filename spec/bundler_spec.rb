# frozen_string_literal: true

require "spec_helper"

RSpec.describe TebakoRelease::Bundler do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  def stage(name, contents = "bytes-of-#{name}")
    @dir.join(name).tap { |path| path.write(contents) }
  end

  def read_bundle(bundle)
    members = []
    Zlib::GzipReader.open(bundle) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each do |entry|
          members << { name: entry.full_name, mode: entry.header.mode, body: entry.read }
        end
      end
    end
    members
  end

  it "names the bundle from the package stem" do
    expect(described_class.bundle_name_for("tebako-runtime-9.9.9-3.3.7-macos-arm64"))
      .to eq("tebako-runtime-9.9.9-3.3.7-macos-arm64.tar.gz")
  end

  it "packs exe, image, sorted DLLs and a closing SHA256SUMS with the store modes" do
    exe = stage("tebako-runtime-9.9.9-3.3.7-windows-ucrt64.exe")
    image = stage("tebako-runtime-9.9.9-3.3.7-windows-ucrt64.tfs")
    dll_b = stage("tebako-runtime-9.9.9-3.3.7-windows-ucrt64-b.dll")
    dll_a = stage("tebako-runtime-9.9.9-3.3.7-windows-ucrt64-a.dll")

    bundle = described_class.new.build(@dir, "tebako-runtime-9.9.9-3.3.7-windows-ucrt64",
                                       exe: exe, image: image, dlls: [dll_b, dll_a])

    members = read_bundle(bundle)
    expect(members.map { |member| member[:name] }).to eq(
      ["tebako-runtime-9.9.9-3.3.7-windows-ucrt64.exe",
       "tebako-runtime-9.9.9-3.3.7-windows-ucrt64.tfs",
       "tebako-runtime-9.9.9-3.3.7-windows-ucrt64-a.dll",
       "tebako-runtime-9.9.9-3.3.7-windows-ucrt64-b.dll",
       "SHA256SUMS"]
    )
    expect(members.map { |member| member[:mode] }).to eq([0o755, 0o444, 0o444, 0o444, 0o444])
    expect(members.first[:body]).to eq("bytes-of-tebako-runtime-9.9.9-3.3.7-windows-ucrt64.exe")

    sums = members.last[:body]
    expect(sums).to eq(
      "#{Digest::SHA256.file(exe).hexdigest}  tebako-runtime-9.9.9-3.3.7-windows-ucrt64.exe\n" \
      "#{Digest::SHA256.file(image).hexdigest}  tebako-runtime-9.9.9-3.3.7-windows-ucrt64.tfs\n" \
      "#{Digest::SHA256.file(dll_a).hexdigest}  tebako-runtime-9.9.9-3.3.7-windows-ucrt64-a.dll\n" \
      "#{Digest::SHA256.file(dll_b).hexdigest}  tebako-runtime-9.9.9-3.3.7-windows-ucrt64-b.dll\n"
    )
  end

  it "is byte-deterministic: identical inputs build an identical bundle" do
    exe = stage("tebako-runtime-9.9.9-3.3.7-macos-arm64")
    image = stage("tebako-runtime-9.9.9-3.3.7-macos-arm64.tfs")

    first = described_class.new.build(@dir, "stem-one", exe: exe, image: image)
    first_sha = Digest::SHA256.file(first).hexdigest
    first.delete
    second = described_class.new.build(@dir, "stem-one", exe: exe, image: image)

    expect(Digest::SHA256.file(second).hexdigest).to eq(first_sha)
  end

  it "rejects a symlinked member (the member grammar admits plain staged files only)" do
    exe = stage("tebako-runtime-9.9.9-3.3.7-macos-arm64")
    image = stage("tebako-runtime-9.9.9-3.3.7-macos-arm64.tfs")
    link = @dir.join("linked.exe")
    File.symlink(exe, link)

    expect { described_class.new.build(@dir, "stem", exe: link, image: image) }
      .to raise_error(TebakoRelease::Error, /not a plain staged file/)
  end
end
