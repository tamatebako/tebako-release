# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako

require_relative "tebako_release/version"
require_relative "tebako_release/error"
require_relative "tebako_release/adapter"
require_relative "tebako_release/config"
require_relative "tebako_release/platform"
require_relative "tebako_release/bundler"
require_relative "tebako_release/uploader"
require_relative "tebako_release/signer"

# The tebako factories' release machinery — the single owner of the
# per-leg publish uploader and the no-fold OpenPGP release signer every
# runtime factory consumes (spec 00 §10: one owner; factories declare
# identity + policy through .configure, never a copy of the machinery).
module TebakoRelease
  class << self
    # The consuming factory's identity + policy, declared once in its
    # adapter file (scripts/release_adapter.rb by convention). Every
    # cross-repo value the machinery needs flows through here — never a
    # second hand-written copy of the machinery itself.
    def configure(**)
      @config = Config.new(**)
    end

    # Sign-only consumers (and the factories' own sign legs) need nothing
    # but the repo name; TEBAKO_RELEASE_REPO is that minimal declaration.
    def config
      @config ||= Config.from_env
    end

    # Test seam: reset the memoized env-derived config.
    def reset_config!
      @config = nil
    end
  end
end
