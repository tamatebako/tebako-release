# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako

require "octokit"

module TebakoRelease
  # The ONE wrapper every GitHub API call in the gem rides (uploader and
  # signer alike). A catalog run's ~90 publish/sign legs share one token's
  # 5,000-request hourly window, and the release backend's reads are only
  # eventually consistent against its writes — a leg must ride both
  # physics out, bounded, and fail NAMED and resumable when a budget is
  # genuinely spent (the 2026-10-03 catalog publish lost 64 of ~90 legs to
  # terminal 403s; the 0.16.32 smoke wedged two legs for their whole job
  # timeout in an unpropagated-delete cycle).
  #
  # The operation classes (each call site picks its own):
  # * unconditional calls — plain GETs and idempotent writes: quota
  #   responses ride the window out, transport drops retry, everything
  #   else keeps its semantics (a 404/422 is information for the caller,
  #   never retried here).
  # * read-after-create reads — a release object a concurrent leg just
  #   created: poll for visibility on RELEASE_VISIBILITY_DELAYS before
  #   the named failure (the call sites own the poll loop; the rides
  #   below keep a quota storm from burning the polls).
  # * delete-then-upload replaces — poll the SINGLE-ASSET endpoint until
  #   the delete is visible, pay the name-release grace, then re-upload;
  #   the poll interval/deadline/grace live here so the uploader and the
  #   signer share one propagation discipline.
  #
  # Retry lines go to stderr (CI-visible) with the attempt, the wait, and
  # the call's target label; the narrative stream stays on stdout.
  module Convergence
    # A ride-out budget genuinely spent: the named, resumable failure —
    # the leg re-run converges on quota, never on code.
    class RateLimitBudgetExhausted < StandardError; end

    # GET/DELETE/PUT calls share the same transient network failure modes;
    # retry them (they are idempotent). A quota response is not one of
    # those modes: it rides the window out below and never consumes the
    # transient attempts. Transport-level drops (SSL EOF, TCP reset)
    # belong here too: a stale keep-alive connection answered with an SSL
    # EOF is indistinguishable from a fresh one that works — net-http
    # retries those on EOFError but NOT on OpenSSL::SSL::SSLError, so we
    # do (the 2026-08-30 backfill crashed on exactly that, on the
    # verification GET right after a long upload POST).
    TRANSIENT_ERRORS = [
      Net::WriteTimeout, Net::ReadTimeout,
      Faraday::TimeoutError, Faraday::ConnectionFailed,
      OpenSSL::SSL::SSLError, EOFError, SystemCallError
    ].freeze
    TRANSIENT_ATTEMPTS = 4

    # A quota response (403 with a rate-limit body, or a bare 429) must
    # never kill a leg: the gem is one serialized actor per leg and
    # sleeping until the window resets is the CORRECT behavior (the 0.16.6
    # publish burned the tebako-ci token's hourly window in ~30 minutes
    # and died at the finalize; run 37061404844 lost 64 legs the same
    # way). Two bounds, whichever spends first:
    RATE_LIMIT_SETTLE = 5
    # The response names no window (no reset, no Retry-After — the
    # secondary-limit shape): capped exponential backoff, doubling from
    # 30 s to a 10-minute ceiling.
    RATE_LIMIT_BACKOFF_BASE = 30
    RATE_LIMIT_BACKOFF_CAP = 600
    # Per-call quota patience: eight absorbed responses (~45 minutes of
    # headerless backoff; header-named windows ride their own advice),
    # then the named error — a fast red leg re-run converges for free,
    # while a leg that keeps eating quota starves the fleet.
    RATE_LIMIT_ATTEMPTS = 8
    # …and the wall-clock ceiling: two full hourly windows waited in one
    # process means something is systemically wrong — give up loudly
    # instead of blocking the runner forever.
    RATE_LIMIT_BUDGET = (2 * 3600) + 300

    # Read-after-create visibility: a release object created by a
    # concurrent leg (the race-safe create's loser, a sign leg ahead of
    # its publisher) is not immediately readable — the 2026-10-02/03
    # force_rebuild fan-out died on exactly this. Bounded polls, stretched
    # past a short secondary-limit window the winner's own create may be
    # riding out; each poll rides the wrapper, so a quota storm stretches
    # the wait INSIDE the call instead of burning polls.
    RELEASE_VISIBILITY_DELAYS = [5, 10, 15, 20, 30, 30, 30].freeze

    # GitHub asset deletion is only eventually consistent: a same-name
    # re-upload 422s until the delete propagates (the v0.16.1 windows
    # publish lost SHA256SUMS.txt to exactly this — four retries inside
    # ~20 s never saw the absence). Poll for the absence on the
    # single-asset endpoint (the listing and the authoritative store
    # replicate independently — the 0.16.32 smoke night flapped the
    # listing while the store never moved), SLEEPING between polls, under
    # a wall-clock deadline. The deadline matches the OBSERVED propagation
    # window: the 2026-08-29 publish watched a deleted name stay
    # 422-blocked well past the old 60 s. And the listing's truth frees
    # the name BEFORE the upload validator's replica does (0.16.8: ~15 s
    # past the visible absence), so every confirmed absence pays the grace.
    DELETION_PROPAGATION_POLL_INTERVAL = 2
    DELETION_PROPAGATION_DEADLINE = 180
    DELETION_PROPAGATION_GRACE = 15

    # Class (a): an unconditional call. Rate-limit responses ride out
    # (never consuming the transient attempts); transport drops retry with
    # escalating waits; every other error propagates to the caller's own
    # semantics untouched.
    def with_transient_retries(target = "GitHub call", attempts: TRANSIENT_ATTEMPTS) # rubocop:disable Metrics/MethodLength
      budget = attempts
      with_rate_limit_rideout(target) do
        yield
      rescue *TRANSIENT_ERRORS => e
        attempts -= 1
        raise if attempts <= 0

        delay = (5 * (budget - attempts)) + rand(5)
        warn "github #{target}: #{e.class}; retrying in #{delay}s (#{attempts} attempt(s) left)"
        sleep delay
        retry
      end
    end

    # The quota ride-out, bounded twice (RATE_LIMIT_ATTEMPTS per call,
    # RATE_LIMIT_BUDGET wall-clock per process). Octokit 7 maps a 403 with
    # a quota body — primary and secondary limits alike — to
    # TooManyRequests, while a bare 429 arrives as a plain ClientError;
    # both are the quota class here, and every other client error keeps
    # its semantics (never swallowed, never retried).
    def with_rate_limit_rideout(target = "GitHub call") # rubocop:disable Metrics/MethodLength
      attempts = 0
      begin
        yield
      rescue Octokit::ClientError => e
        raise unless rate_limit_error?(e)

        attempts += 1
        wait = rate_limit_wait(e, target, attempts)
        warn "github #{target}: #{e.class} — rate-limited; sleeping #{wait}s " \
             "(quota response #{attempts}/#{RATE_LIMIT_ATTEMPTS})"
        sleep wait
        retry
      end
    end

    def rate_limit_error?(error)
      return true if error.is_a?(Octokit::TooManyRequests)
      return false unless error.is_a?(Octokit::ClientError)

      error.response_status.to_i == 429
    rescue NoMethodError
      # A bare-raised error carries no response — and no quota status.
      false
    end

    # The seconds to sleep before the next call, budget-checked: one full
    # hourly window is a legitimate wait; a ninth absorbed quota response,
    # or a wait that would push the process past two windows, means
    # something is systemically wrong — give up loudly instead of
    # blocking the runner forever.
    def rate_limit_wait(error, target, attempts) # rubocop:disable Metrics/MethodLength
      if attempts > RATE_LIMIT_ATTEMPTS
        raise RateLimitBudgetExhausted,
              "github #{target}: absorbed #{RATE_LIMIT_ATTEMPTS} rate-limit responses without the window opening — " \
              "the per-call budget is exhausted; re-run the leg (the token's quota resets hourly)"
      end

      wait = rate_limit_seconds(error, attempts)
      return wait if monotonic_now + wait <= rate_limit_deadline

      raise RateLimitBudgetExhausted,
            "github #{target}: the next rate-limit window is #{wait}s out but this process has a " \
            "#{RATE_LIMIT_BUDGET}s ride-out budget — two full windows spent; " \
            "giving up loudly instead of blocking forever"
    end

    def rate_limit_deadline
      @rate_limit_deadline ||= monotonic_now + RATE_LIMIT_BUDGET
    end

    # The reset header names the window's end as a wall-clock epoch (plus
    # a small settle); a stale or absent reset falls back to Retry-After,
    # then to the capped exponential backoff. Faraday's real headers are
    # case-insensitive; read both spellings so a plain hash (the spec
    # fake) serves the same values.
    def rate_limit_seconds(error, attempts) # rubocop:disable Metrics/AbcSize
      headers = begin
        error.response_headers || {}
      rescue NoMethodError
        {} # a bare-raised error carries no response headers
      end
      reset = (headers["x-ratelimit-reset"] || headers["X-RateLimit-Reset"]).to_i
      return reset - Time.now.to_i + RATE_LIMIT_SETTLE if reset > Time.now.to_i

      retry_after = (headers["retry-after"] || headers["Retry-After"]).to_i
      return retry_after + RATE_LIMIT_SETTLE if retry_after.positive?

      [RATE_LIMIT_BACKOFF_BASE * (2**(attempts - 1)), RATE_LIMIT_BACKOFF_CAP].min
    end

    # Wall-clock reads for the deadline accounting — monotonic, immune to
    # clock smear on the runner.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
