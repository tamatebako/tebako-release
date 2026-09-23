# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako

module TebakoRelease
  # Named error for every release-machinery failure (spec 00: named errors,
  # never silent fallbacks).
  class Error < StandardError; end
end
