# frozen_string_literal: true

require_relative "lib/tebako_release/version"

Gem::Specification.new do |spec|
  spec.name = "tebako-release"
  spec.version = TebakoRelease::VERSION
  spec.authors = ["Ribose Inc"]
  spec.email = ["open.source@ribose.com"]

  spec.summary = "Release machinery for the tebako runtime factories: per-leg publish + OpenPGP signing"
  spec.description = "The single owner of the tebako factories' release machinery: " \
                     "the de-rendezvoused per-leg uploader (shards + sidecars, byte-immutable keeps, " \
                     "convergence and rate-limit ride-outs) and the no-fold OpenPGP release signer. " \
                     "Factories consume the gem; they never carry copies of the machinery."
  spec.homepage = "https://github.com/tamatebako/tebako-release-tooling"
  spec.license = "BSD-2-Clause"
  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir["lib/**/*.rb", "exe/*", "LICENSE.md", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["tebako-release"]
  spec.require_paths = ["lib"]

  spec.add_dependency "octokit", "~> 7.1"

  spec.metadata["rubygems_mfa_required"] = "true"
end
