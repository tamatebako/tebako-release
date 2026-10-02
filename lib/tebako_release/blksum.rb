# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako

require "digest"
require "json"
require "pathname"

module TebakoRelease
  # The spec 39 §3 block-group digest sidecar (`<image>.blksum.json`): one
  # sha256 per 4 MiB group of image bytes plus the whole-image sha256,
  # authored by the PUBLISHER in-process (a resolver never derives one).
  # For the factories the publisher invocation is `tebako-release upload`,
  # so the derivation lives here — a pure function of the staged image
  # bytes, the same derivable-metadata class as the `.sha256` sidecars.
  #
  # The render is byte-exact with tpkg::lazy::Blksum::render (the product's
  # single owner of the grammar): compact machine JSON, keys in schema
  # order, lowercase hex, no trailing newline. spec/blksum_spec.rb pins
  # tpkg-minted golden vectors against this render — a drift fails the
  # suite, never ships.
  class Blksum
    # The locked fetch unit (spec 39 §11.3): 4 MiB of image bytes; the
    # final group is short. Tunable only by a measured product follow-up.
    GROUP_SIZE = 4 * 1024 * 1024

    # `schema_version` of the v1 document.
    SCHEMA_VERSION = 1

    # The served asset name is the image's name plus this suffix.
    SIDECAR_SUFFIX = ".blksum.json"

    # The sidecar asset name for an image name (or an image path).
    def self.sidecar_name(image)
      "#{Pathname.new(image).basename}#{SIDECAR_SUFFIX}"
    end

    def self.blksum_file?(path)
      path.basename.to_s.end_with?(SIDECAR_SUFFIX)
    end

    # Derive the sidecar of a staged image: streams the file in GROUP_SIZE
    # chunks (the runtime env images are 50–200 MB — never held whole),
    # one sha256 per group plus the whole-image sha256. An absent or empty
    # image is a named refusal (spec 39 §3: size_bytes >= 1).
    def self.for_image(image_path)
      path = Pathname.new(image_path)
      assert_derivable!(path)
      whole, groups = hash_stream(path)
      new(size_bytes: path.size, sha256: whole.hexdigest, groups: groups)
    end

    def self.assert_derivable!(path)
      raise Error, "the blksum sidecar cannot be derived: #{path} does not exist" unless path.file?
      raise Error, "the blksum sidecar cannot be derived: #{path} is empty (size_bytes >= 1)" if path.empty?
    end

    def self.hash_stream(path)
      whole = Digest::SHA256.new
      groups = []
      path.open("rb") do |io|
        while (chunk = io.read(GROUP_SIZE))
          whole.update(chunk)
          groups << Digest::SHA256.hexdigest(chunk)
        end
      end
      [whole, groups]
    end

    attr_reader :size_bytes, :sha256, :groups

    def initialize(size_bytes:, sha256:, groups:)
      @size_bytes = size_bytes
      @sha256 = sha256
      @groups = groups
    end

    # The machine JSON form (keys in schema order) — byte-exact with
    # tpkg::lazy::Blksum::render, golden-pinned in spec/blksum_spec.rb.
    def render
      JSON.generate(
        schema_version: SCHEMA_VERSION,
        group_size: GROUP_SIZE,
        size_bytes: size_bytes,
        sha256: sha256,
        groups: groups
      )
    end

    # The sidecar document's own sha256 (the manifest's
    # `image.blksum.sha256` pin — spec 39 §3).
    def digest
      Digest::SHA256.hexdigest(render)
    end
  end
end
