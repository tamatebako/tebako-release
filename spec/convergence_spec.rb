# frozen_string_literal: true

require "spec_helper"

# The wrapper-boundary suite: the ONE convergence wrapper every GitHub API
# call in the gem rides (tebako-release#2/#12/#13/#14), pinned once against
# a scripted harness with the module included — the uploader/signer suites
# pin the call-site semantics; this suite pins the wrapper's own: the quota
# ride-out (reset / Retry-After / capped headerless backoff), the two
# budgets (per-call attempts, per-process wall-clock), the transient
# retries, and the stderr retry lines.
class ConvergenceHarness
  include TebakoRelease::Convergence

  attr_reader :calls

  def initialize(script)
    @script = script
    @calls = 0
  end

  # One scripted GitHub roundtrip: each entry is either the value to
  # return or the exception to raise.
  def github_roundtrip
    @calls += 1
    outcome = @script.shift
    raise outcome if outcome.is_a?(Exception)

    outcome
  end
end

RSpec.describe TebakoRelease::Convergence do
  let(:script) { [:ok] }
  let(:harness) { ConvergenceHarness.new(script) }

  before { allow(harness).to receive(:sleep) }

  # A quota-shaped 403, the way Octokit 7 raises it (the rate-limit body
  # wording maps to TooManyRequests); headers carry the window's advice.
  def too_many_requests(headers = {})
    Octokit::TooManyRequests.new(status: 403, body: "API rate limit exceeded", response_headers: headers)
  end

  it "passes a clean call through untouched" do
    expect(harness.with_transient_retries("listing") { harness.github_roundtrip }).to eq(:ok)
    expect(harness.calls).to eq(1)
    expect(harness).not_to have_received(:sleep)
  end

  it "rides a quota 403 out on its named Retry-After and returns the first success" do
    script.replace([too_many_requests("retry-after" => "17"), :ok])

    expect(harness.with_transient_retries("listing") { harness.github_roundtrip }).to eq(:ok)
    expect(harness.calls).to eq(2)
    expect(harness).to have_received(:sleep).with(22) # 17 + the 5s settle
  end

  it "logs each quota ride-out to stderr with the wait, the attempt, and the target" do
    script.replace([too_many_requests("retry-after" => "17"), :ok])

    expect { harness.with_transient_retries("listing") { harness.github_roundtrip } }
      .to output(%r{github listing: Octokit::TooManyRequests — rate-limited; sleeping 22s \(quota response 1/8\)})
      .to_stderr
  end

  it "sleeps until the window's named reset plus the settle" do
    reset = Time.now.to_i + 1000
    script.replace([too_many_requests("x-ratelimit-reset" => reset.to_s), :ok])

    harness.with_transient_retries("listing") { harness.github_roundtrip }

    expect(harness).to have_received(:sleep).with(a_value_between(1000, 1006))
  end

  it "backs off exponentially from 30s when the response names no window, capped at ten minutes" do
    script.replace(Array.new(6) { too_many_requests } + [:ok])

    harness.with_transient_retries("listing") { harness.github_roundtrip }

    [30, 60, 120, 240, 480, 600].each do |wait|
      expect(harness).to have_received(:sleep).with(wait).once
    end
    expect(harness.calls).to eq(7)
  end

  # Octokit 7 maps only 403s with a quota body to TooManyRequests; a bare
  # 429 arrives as a plain ClientError — it is the same quota class here.
  it "treats a bare 429 as a quota response" do
    script.replace([Octokit::ClientError.new(status: 429, body: "429 Too Many Requests",
                                             response_headers: { "retry-after" => "1" }), :ok])

    expect(harness.with_transient_retries("listing") { harness.github_roundtrip }).to eq(:ok)
    expect(harness).to have_received(:sleep).with(6)
  end

  it "never retries a 404 — absence is information for the caller" do
    script.replace([Octokit::NotFound.new(status: 404, body: "Not Found", response_headers: {})])

    expect { harness.with_transient_retries("listing") { harness.github_roundtrip } }
      .to raise_error(Octokit::NotFound)
    expect(harness.calls).to eq(1)
    expect(harness).not_to have_received(:sleep)
  end

  it "never retries a 422 — validation errors keep the caller's semantics" do
    script.replace([Octokit::UnprocessableEntity.new(status: 422, body: "Validation Failed", response_headers: {})])

    expect { harness.with_transient_retries("listing") { harness.github_roundtrip } }
      .to raise_error(Octokit::UnprocessableEntity)
    expect(harness.calls).to eq(1)
  end

  # The per-call bound (run 37061404844's lesson: a leg that keeps eating
  # quota starves the fleet) — the ninth absorbed quota response raises
  # the named, resumable error instead of sleeping again.
  it "gives up named when the per-call quota attempt budget is spent, without a final sleep" do
    budget = described_class::RATE_LIMIT_ATTEMPTS
    script.replace(Array.new(budget + 1) { too_many_requests })

    expect { harness.with_transient_retries("listing") { harness.github_roundtrip } }
      .to raise_error(described_class::RateLimitBudgetExhausted, /budget is exhausted/)
    expect(harness.calls).to eq(budget + 1)
    expect(harness).to have_received(:sleep).exactly(budget).times
  end

  # …and the wall-clock bound: two full hourly windows waited in one
  # process means something is systemically wrong — give up loudly.
  it "gives up loudly when the next window outlasts the two-window ride-out budget" do
    reset = Time.now.to_i + described_class::RATE_LIMIT_BUDGET + 60
    script.replace([too_many_requests("x-ratelimit-reset" => reset.to_s)])

    expect { harness.with_transient_retries("listing") { harness.github_roundtrip } }
      .to raise_error(described_class::RateLimitBudgetExhausted, /rate-limit/)
    expect(harness).not_to have_received(:sleep)
  end

  it "retries a transport drop inside the same ride-out, then returns the success" do
    script.replace([Faraday::ConnectionFailed.new("ssl eof"), :ok])

    expect(harness.with_transient_retries("listing") { harness.github_roundtrip }).to eq(:ok)
    expect(harness.calls).to eq(2)
    expect(harness).to have_received(:sleep).with(a_value_between(5, 10)).once
  end

  it "spends the transient budget on a persistent drop, then raises it" do
    script.replace(Array.new(described_class::TRANSIENT_ATTEMPTS) { Faraday::ConnectionFailed.new("ssl eof") })

    expect { harness.with_transient_retries("listing") { harness.github_roundtrip } }
      .to raise_error(Faraday::ConnectionFailed)
    expect(harness.calls).to eq(described_class::TRANSIENT_ATTEMPTS)
  end

  it "never spends transient attempts on quota responses" do
    script.replace([too_many_requests("retry-after" => "1"), Faraday::ConnectionFailed.new("ssl eof"), :ok])

    expect(harness.with_transient_retries("listing") { harness.github_roundtrip }).to eq(:ok)
    expect(harness.calls).to eq(3)
  end
end
