# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako

module TebakoRelease
  # The consuming factory's identity: which repo's releases this run
  # manages, the language whose version strings ride the package-name
  # grammar, the release title prefix, the contract.yml path (the release
  # pipeline's SSOT for the bootstrap<->runtime contract version), and the
  # policy adapter. `repo` is the one value a sign-only consumer must
  # declare; everything else has an upload-side default.
  class Config
    DEFAULT_TOOL_REPO = "tamatebako/tebako"

    attr_reader :repo, :language, :title_prefix, :contract_yml, :adapter, :tool_repo

    def initialize(repo:, language: nil, title_prefix: nil, contract_yml: "contract.yml", # rubocop:disable Metrics/ParameterLists
                   adapter: Adapter.new, tool_repo: DEFAULT_TOOL_REPO)
      @repo = repo
      @language = language
      @title_prefix = title_prefix || "Tebako runtime packages"
      @contract_yml = contract_yml
      @adapter = adapter
      @tool_repo = tool_repo
    end

    # The minimal env-only declaration: the sign path's one repo value.
    def self.from_env(env = ENV)
      new(repo: env.fetch("TEBAKO_RELEASE_REPO") do
        raise Error, "TEBAKO_RELEASE_REPO is not set and no release adapter was configured — " \
                     "the release machinery never guesses which repo it publishes to"
      end)
    end

    # The manifest entry's version key for this runtime's language
    # (ruby_version / python_version / …).
    def version_key
      :"#{language}_version"
    end

    # The env var carrying this leg's expected version matrix
    # (EXPECTED_RUBY_MATRIX / EXPECTED_PYTHON_MATRIX / …).
    def version_matrix_env
      "EXPECTED_#{language.upcase}_MATRIX"
    end
  end
end
