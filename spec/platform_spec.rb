# frozen_string_literal: true

require "spec_helper"

RSpec.describe TebakoRelease::Platform do
  it "maps every (os, arch) pair to the product's release platform id" do
    expect(described_class.host_id_for("windows", "x86_64")).to eq("windows-ucrt64")
    expect(described_class.host_id_for("windows", "arm64")).to eq("windows-ucrt-arm64")
    expect(described_class.host_id_for("macos", "arm64")).to eq("macos-arm64")
    expect(described_class.host_id_for("macos", "x86_64")).to eq("macos-x86_64")
    expect(described_class.host_id_for("linux-gnu", "x86_64")).to eq("linux-gnu-x86_64")
    expect(described_class.host_id_for("linux-gnu", "arm64")).to eq("linux-gnu-arm64")
    expect(described_class.host_id_for("linux-musl", "x86_64")).to eq("linux-musl-x86_64")
    expect(described_class.host_id_for("linux-musl", "arm64")).to eq("linux-musl-arm64")
  end

  it "fails named on an unknown pair (never a guessed id)" do
    expect { described_class.host_id_for("plan9", "x86_64") }
      .to raise_error(TebakoRelease::Error, %r{no release platform id for plan9/x86_64})
  end

  it "detects the current host's id" do
    expect(described_class.new.host_id).to match(/\A(windows-ucrt64|macos-arm64|macos-x86_64|linux-gnu-x86_64)\z/)
  end

  it "carries the exe suffix only on msys hosts" do
    expect(described_class.new("mingw32").exe_suffix).to eq(".exe")
    expect(described_class.new("darwin").exe_suffix).to eq("")
  end
end
