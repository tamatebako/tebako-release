# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako

require "rbconfig"

module TebakoRelease
  # The release-side platform vocabulary: (os id, arch id) ↔ the release
  # platform id used in runtime package names. Owned by tpkg::Platform
  # (tamatebako/tebako, docs/spec/03 §3); NOT derivable by formula
  # ("windows-ucrt64" carries no arch segment). windows/arm64 follows the
  # product's RESERVED release-asset name ("windows-ucrt-arm64" — the
  # aarch64-windows-ucrt triplet, which tpkg parses but rejects in payload
  # manifests until the platform ships). This is the release tooling's
  # mirror of that table; drift fails loudly in the factories' CI parity
  # checks.
  class Platform
    HOST_IDS = {
      %w[windows x86_64] => "windows-ucrt64",
      %w[windows arm64] => "windows-ucrt-arm64",
      %w[macos arm64] => "macos-arm64",
      %w[macos x86_64] => "macos-x86_64",
      %w[linux-gnu x86_64] => "linux-gnu-x86_64",
      %w[linux-gnu arm64] => "linux-gnu-arm64",
      %w[linux-musl x86_64] => "linux-musl-x86_64",
      %w[linux-musl arm64] => "linux-musl-arm64"
    }.freeze

    # The lookup for callers with no detected host (the release pipeline's
    # expected-asset model); the instance path shares the named failure.
    def self.host_id_for(os_id, arch_id)
      HOST_IDS.fetch([os_id, arch_id]) { raise Error, "no release platform id for #{os_id}/#{arch_id}" }
    end

    def initialize(ostype = RUBY_PLATFORM, arch = RbConfig::CONFIG["host_cpu"])
      @ostype = ostype
      @arch = arch
    end

    attr_reader :ostype

    # Platform id as used by runtime package names (e.g. "macos-arm64",
    # "windows-ucrt64").
    def host_id
      self.class.host_id_for(host_os_id, host_arch_id)
    end

    def exe_suffix
      @ostype =~ /msys|mingw|cygwin/ ? ".exe" : ""
    end

    private

    def host_os_id
      case @ostype
      when /msys|mingw|cygwin/ then "windows"
      when /darwin/ then "macos"
      when /linux-musl/ then "linux-musl"
      when /linux/ then "linux-gnu"
      else
        raise Error, "no release os id for #{@ostype}"
      end
    end

    def host_arch_id
      case @arch
      when /^(x86_64|amd64|x64)$/ then "x86_64"
      when /^(aarch64|arm64)$/ then "arm64"
      else
        raise Error, "no release arch id for #{@arch}"
      end
    end
  end
end
