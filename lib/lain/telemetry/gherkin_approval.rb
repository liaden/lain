# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # An approval verdict must name the criteria it judged, say whether it
      # was approved as a real boolean (the same `presence:`-cannot-reject-
      # `false` reasoning as {Verdict}'s `survived`), and name who answered --
      # a surface, never nil, so a journal reader never guards (the same
      # named-not-nil discipline {Approval::Queue::TIMEOUT_SURFACE} keeps).
      class GherkinApproval < Guard
        attribute :criteria_digest
        attribute :approved
        attribute :answered_by
        validates :criteria_digest, presence: { message: "must name the criteria it judged, got nil" }
        validates :approved, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :answered_by, presence: { message: "must name who answered, got nil" }
      end
    end

    # One GG-1 approval verdict over a {Gherkin::Criteria}. `criteria_digest`
    # is the {Gherkin::Criteria#digest} the gate judged -- the JOIN KEY a
    # downstream refuses to consume unapproved, and precisely why an edited
    # clause (a different digest) is a distinct, un-approved criteria rather
    # than a stale match. `approved` is the verdict as a real boolean;
    # `answered_by` NAMES the surface that gave it -- the human surface, the
    # `"auto_approver"` meta-agent, or `"timeout"` when the fail-closed clock
    # denied an unanswered gate -- so a transcript never confuses who approved
    # what (the same signed-surface evidence {Approval::Queue} keeps for its
    # `approval_decision`). `latency` is the measured seconds the verdict took.
    #
    # Emitted by {Gherkin::Approval#call}, the same decide-then-journal pairing
    # {Approval::Queue} makes for its own `approval_decision` line -- one gate,
    # one durable verdict.
    GherkinApproval = Data.define(:criteria_digest, :approved, :answered_by, :latency) do
      include Journalable

      def initialize(criteria_digest:, approved:, answered_by:, latency:)
        Guards::GherkinApproval.check!(criteria_digest:, approved:, answered_by:)

        super(
          criteria_digest: criteria_digest.dup.freeze,
          approved:,
          answered_by: answered_by.to_s.dup.freeze,
          latency: latency.to_f
        )
      end
    end
  end
end
