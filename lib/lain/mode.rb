# frozen_string_literal: true

module Lain
  # One exclusive posture governing how the agent's output is interpreted, plus
  # any number of orthogonal layers -- Emacs' major/minor split, keeping Vim's
  # mutual exclusion for the one job it earns: the same token must have exactly
  # one interpretation.
  #
  # ⚠️ The `Mode` VALUE is not written yet, and adding it is not a one-liner.
  # Today `Mode` is a NAMESPACE: a plain module that `mode/posture` and
  # `mode/layer` both reopen as `module Mode`. Two things follow, and the card
  # that adds the value has to do both together or the load breaks:
  #
  #   * `Mode = Data.define(...)` RE-ASSIGNS this constant rather than reopening
  #     it, dropping `Mode::Posture` and `Mode::Layer` on the floor with nothing
  #     louder than a redefinition warning.
  #   * `Data.define` answers a CLASS, so both children must become
  #     `class Mode` in the same change -- `module Mode` against a class is a
  #     hard `TypeError: Mode is not a class` at load. (That is not theoretical:
  #     the two wave-1 cards disagreed on this exact word and the merge caught
  #     it.)
  module Mode
  end
end

require_relative "mode/layer"
require_relative "mode/posture"
