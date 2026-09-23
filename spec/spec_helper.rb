# frozen_string_literal: true

require "tmpdir"

REPO_ROOT = File.expand_path("..", __dir__).freeze

require "tebako_release"
require_relative "support/spec_adapter"

# The machinery's spec-time factory identity: the ruby factory's grammar
# and env names (the ported suites assert against them unchanged), the
# fixture contract card, and the spec adapter's canned policy table.
TebakoRelease.configure(
  repo: "tamatebako/tebako-runtime-ruby",
  language: "ruby",
  title_prefix: "Tebako runtime packages",
  contract_yml: File.join(REPO_ROOT, "spec", "fixtures", "contract.yml"),
  adapter: SpecAdapter.new
)

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
