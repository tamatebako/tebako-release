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
  end
end
