# frozen_string_literal: true

module Lain
  # One exclusive posture governing how the agent's output is interpreted, plus
  # any number of orthogonal layers -- Emacs' major/minor split, keeping Vim's
  # mutual exclusion for the one job it earns: the same token must have exactly
  # one interpretation.
  #
  # ⚠️ The `Mode` VALUE is not written yet. When it lands it must be defined
  # ABOVE the requires below, never under them: `Mode = Data.define(...)`
  # RE-ASSIGNS a constant that `mode/posture` has already opened as a plain
  # module, which drops `Mode::Posture` on the floor with nothing louder than a
  # redefinition warning to say so.
  module Mode
  end
end

require_relative "mode/layer"
