# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako

module TebakoRelease
  # The factory-policy surface — the one seam through which a consuming
  # factory's own vocabulary reaches the release machinery. Factories
  # subclass this (or pass any object responding to the same methods) in
  # their adapter file; the defaults describe a runtime with no
  # capability gates, no capabilities display metadata, no DLL facet,
  # plain string version matrix rows, and a semver version grammar.
  class Adapter
    # (os id, arch id, runtime version) → false when the factory never
    # builds that combination (the audit must never expect it). Default:
    # every pair is capable.
    def capable_pair?(_os, _arch, _version)
      true
    end

    # The additive capabilities line of a manifest entry: display metadata
    # owned by the factory that compiled the runtime — never a selector
    # axis. Default: none.
    def capabilities(version:, platform_id:)
      _ = version
      _ = platform_id
      []
    end

    # The PE name the store materializes next to a windows exe so its
    # imports resolve (nil → the runtime ships no DLL facet).
    def dll_install_name(_version, _host_id)
      nil
    end

    # The prepare job's version matrix rows → version strings. Default:
    # rows ARE the version strings; factories whose rows carry extra keys
    # (a src_sha256 cache key) override.
    def expected_versions(rows)
      rows.map { |row| row.is_a?(Hash) ? row.fetch("version") : row }
    end

    # The version capture of the package-name grammar, as a regex SOURCE
    # (the consuming factory's version-line model owns it).
    def version_grammar_source
      "\\d+\\.\\d+\\.\\d+"
    end

    # The language segment of the package-name grammar
    # (`tebako-runtime-<ver>-<lang>-<lv>-<triplet>` — tebako#716):
    # declared by factories publishing the post-#716 spelling. Default
    # nil — the pre-#716 spelling carried no language segment, and this
    # machinery keeps composing/parsing it for the immutable releases
    # that already carry it.
    def lang_name
      nil
    end

    # Spec 36's publish shape: when true, each leg publishes ONE bundle
    # (<stem>.tar.gz — exe + env image + DLLs + in-bundle SHA256SUMS) plus
    # its sidecar and shard, instead of the per-file asset enumeration.
    # Default off: a factory opts in deliberately, with the bundle-era
    # resolver shipped downstream (spec 36 §4's compat window).
    def bundle_publish?
      false
    end

    # Spec 36 §3's co-publish: when true (and bundle_publish? holds), each
    # leg ALSO serves the per-file assets — the exe under its historical
    # spelling, the env image, the windows DLL — as standalone release
    # assets beside the bundle, each with its .sha256 sidecar. The lazy
    # arm (spec 39 §7) range-fetches the image's groups over HTTP, which
    # is impossible inside the gzip stream; the shard gains the additive
    # per_file_assets witness (runtime-manifest MINOR 2) that gates the
    # loaders' lazy arm on bundle-declaring shards. Default off: a
    # factory opts in when its consumers include the lazy arm.
    def per_file_alongside_bundle?
      false
    end
  end
end
