# frozen_string_literal: true

module Lain
  # A question asked of something other than the main loop: an
  # {Oracle::Definition} is a content-addressed template plus the
  # {Tool::Input} schema its reply is validated against plus the tier that
  # answers it, so a caller cannot tell a heuristic answer from a model one by
  # the answer's shape. The tiers are the swappable thing here --
  # {Oracle::Heuristic} is free and deterministic, {Oracle::Model} spends a
  # call, {Oracle::Recorded} replays one.
  module Oracle; end
end
