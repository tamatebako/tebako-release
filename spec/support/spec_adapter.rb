# frozen_string_literal: true

# The spec-time factory adapter: deterministic, dependency-free stand-ins
# for the policy callbacks a real factory delegates to its builder lib.
# The tables below mirror the ruby factory's public rules exactly where the
# ported suites assert against them (the windows/arm64 capability floor,
# the capabilities truth table, the msys DLL PE name grammar).
class SpecAdapter < TebakoRelease::Adapter
  # windows/arm64 builds exist only for runtime versions at/above the
  # factory's capability floor.
  FLOOR = Gem::Version.new("3.4.8")

  def capable_pair?(os, arch, version)
    !(os == "windows" && arch == "arm64") || Gem::Version.new(version) >= FLOOR
  end

  # yjit: every non-windows leg except the 3.1 line's non-x86_64 ones;
  # zjit: the 4.x line's non-windows legs.
  def capabilities(version:, platform_id:) # rubocop:disable Metrics/CyclomaticComplexity
    return [] if version.nil? || platform_id.nil? || platform_id.include?("windows")

    major, minor = version.split(".").first(2).map(&:to_i)
    caps = []
    caps << "yjit" unless [major, minor] == [3, 1] && !platform_id.end_with?("x86_64")
    caps << "zjit" if major >= 4
    caps
  end

  # The windows PE name the store materializes: x64-ucrt-ruby330.dll for
  # the 3.3 line, matching the factory's major*100 + minor*10 grammar.
  def dll_install_name(version, _host_id)
    major, minor = version.split(".").first(2).map(&:to_i)
    "x64-ucrt-ruby#{(major * 100) + (minor * 10)}.dll"
  end
end

# The spec 36 opt-in: a factory adapter declaring the bundle-era publish
# shape (the bundle suites' stand-in for the factory's deliberate opt-in).
class BundleSpecAdapter < SpecAdapter
  def bundle_publish?
    true
  end
end
