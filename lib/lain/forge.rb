# frozen_string_literal: true

module Lain
  # Where lain reaches OUTSIDE the machine it is running on -- pushing a ref,
  # opening a pull request, merging one -- and its discipline is that each such
  # reach is journaled as an INTENT before it is attempted and an OUTCOME
  # after, so a crash leaves a readable bet rather than a silence.
  # {Forge::Reconcile} reads those back and asks the world which of them
  # actually landed.
  module Forge; end
end
