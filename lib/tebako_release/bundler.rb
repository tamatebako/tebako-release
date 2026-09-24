# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako

require "digest"
require "rubygems/package"
require "zlib"

module TebakoRelease
  # Spec 36 §2 — the deterministic tar.gz runtime bundle: ONE distribution
  # artifact per (version × triplet) leg carrying the interpreter exe, the
  # env image, and any windows support DLLs, closed by an in-bundle
  # SHA256SUMS. The bundle is the publish unit on bundle-era lines: the
  # per-file asset enumeration (exe + image + per-asset sidecars, each
  # signed) costs ~10–14 release assets per leg; the bundle costs 3–5.
  #
  # Determinism is a publish-economy property, not a promise to consumers:
  # identical inputs must yield identical bytes so a re-run's digest-match
  # skip stays cheap (fixed member order, mtime=0 everywhere, no gzip
  # original-name field).
  class Bundler
    BUNDLE_SUFFIX = ".tar.gz"
    SUMS_NAME = "SHA256SUMS"

    # Member modes as the store materializes them (spec 05 §3): the exe is
    # 0755, the env image 0444, support DLLs plain read-only data.
    EXE_MODE = 0o755
    IMAGE_MODE = 0o444
    DLL_MODE = 0o444

    def self.bundle_name_for(stem)
      "#{stem}#{BUNDLE_SUFFIX}"
    end

    # Build <dir>/<stem>.tar.gz from the leg's staged members.
    # members: exe Pathname (required), image Pathname (required — a
    # bundle without its env image is not a runtime), dlls (zero or
    # more). Returns the bundle Pathname.
    def build(dir, stem, exe:, image:, dlls: [])
      members = [[exe, EXE_MODE], [image, IMAGE_MODE]] + dlls.sort_by { |d| d.basename.to_s }.map { |d| [d, DLL_MODE] }
      members.map(&:first).each { |path| validate_member!(path) }
      bundle = Pathname.new(dir).join(self.class.bundle_name_for(stem))
      write_bundle(bundle, members, sums_content(members))
      bundle
    end

    private

    # SHA256SUMS, coreutils shape ("<sha>  <file>\n" per member), in member
    # order — the bundle's last member, pinning every other (spec 36 §2).
    def sums_content(members)
      lines = members.map { |path, _| "#{Digest::SHA256.file(path).hexdigest}  #{path.basename}" }
      "#{lines.join("\n")}\n"
    end

    # Deterministic bytes (spec 36 §2): fixed member order, mtime=0 in the
    # gzip header and every tar header — identical inputs yield identical
    # bytes, so a re-run's digest-match skip stays cheap.
    def write_bundle(bundle, members, sums)
      File.open(bundle, "wb") do |io|
        gz = Zlib::GzipWriter.new(io)
        gz.mtime = 0
        Gem::Package::TarWriter.new(gz) do |tar|
          members.each { |path, mode| add_member(tar, path.basename.to_s, mode, path) }
          tar.add_file_simple(SUMS_NAME, 0o444, sums.bytesize) { |io_member| io_member.write(sums) }
        end
        gz.close
      end
    end

    def add_member(tar, name, mode, path)
      tar.add_file_simple(name, mode, path.size) do |io_member|
        File.open(path, "rb") { |f| IO.copy_stream(f, io_member) }
      end
    end

    # The §2 member grammar: a plain staged regular file — never a
    # symlink, directory, or device (members are written under their bare
    # basenames, so no path traversal is possible by construction; what
    # remains to assert is the kind).
    def validate_member!(path)
      return if path.file? && !path.symlink?

      raise Error, "bundle member #{path} is not a plain staged file (spec 36 §2's member grammar)"
    end
  end
end
