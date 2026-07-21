# frozen_string_literal: true

module Lain
  # M1: the friction-observer's deterministic core, for the lain **user** --
  # offline knob guidance folded over one session Journal, no model call. See
  # {Friction::Report}. Distinct from the harness-improver (M6): that pass
  # tells the lain DEV what lain itself should grow; this one tells the lain
  # USER which existing knob to turn.
  module Friction
  end
end

require_relative "friction/report"
