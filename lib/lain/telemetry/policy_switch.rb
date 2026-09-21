# frozen_string_literal: true

module Lain
  module Telemetry
    # A gate-policy flip, attributed to the surface that made it -- "who changed
    # what the gate answers, and when" is evidence on a study bench, not incident
    # detail. The flip is DERIVED rather than typed: {CLI::Switchboard#apply}
    # writes the approval level's gate policy as the consequence of a `/mode` flip, so
    # `surface` names the surface that flipped the MODE.
    #
    # A DUMB CARRIER, as {ModelSwitch} and {ModeSwitch} are: {Approval::PolicySwitch}
    # owns the from/to naming and keeps its own live `@current`, and the record only
    # serializes the flip. The discriminator "policy_switch" derives from the class
    # basename ({Journalable#journal_type}), which journal readers and replay match
    # on, so the class name must not drift.
    PolicySwitch = Data.define(:from, :to, :surface) do
      include Journalable

      def initialize(from:, to:, surface:)
        super(from: from.to_s.dup.freeze, to: to.to_s.dup.freeze, surface: surface.to_s.dup.freeze)
      end
    end
  end
end
