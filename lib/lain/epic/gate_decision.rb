# frozen_string_literal: true

module Lain
  module Epic
    GateDecision = Data.define(:artifact_digest, :epic_slug, :stage, :verdict, :answered_by, :policy,
                               :latency, :evidence_digest, :issue_id, :criteria_digest) do
      include Telemetry::Journalable

      # `reason` fills in a note the verdict does not carry: a policy's
      # rationale, forwarded by a caller that is not the one answering.
      def initialize(artifact_digest:, epic_slug:, stage:, verdict:, answered_by:, policy:, latency:,
                     evidence_digest: nil, reason: nil, issue_id: nil, criteria_digest: nil)
        # Stringified BEFORE the guard, so `presence:` judges the bytes that
        # actually get journaled: a stage object whose `#to_s` is blank passes a
        # presence check on the raw object and then writes an empty partition
        # key -- the one value a queue folding on (epic_slug, stage) can never
        # match back.
        epic_slug = interned(epic_slug)
        stage = interned(stage)
        answered_by = interned(answered_by)
        policy = interned(policy)
        issue_id = SignoffQueue::IssueId.read(issue_id)
        verdict = noted(Approval::Verdict.coerce(verdict), reason)
        Contracts::GateDecision.check!(artifact_digest:, epic_slug:, stage:, answered_by:, policy:,
                                       latency:, issue_id:)

        super(artifact_digest: artifact_digest.dup.freeze, epic_slug:, stage:, verdict:, answered_by:, policy:,
              latency: latency.to_f, evidence_digest: frozen(evidence_digest),
              issue_id:, criteria_digest: frozen(criteria_digest))
      end

      # @return [String, nil] the verdict's note
      def reason = verdict.note

      def approved? = verdict.approved?

      def held? = verdict.held?

      # @return [Hash{String=>Object}] the verdict as its word, its note as `reason`
      def to_journal
        super.merge("verdict" => GateDecision.word(verdict), "reason" => reason)
      end

      private

      def noted(verdict, reason)
        return verdict if verdict.note || reason.nil?

        verdict.class.new(note: reason.to_s)
      end

      # Interned where the digests are dup'd-and-frozen: a stage or a surface
      # repeats across every record in a run, a digest does not.
      def interned(value) = -value.to_s

      # nil stays nil: "nothing was carried" is a value on this record.
      def frozen(value) = value&.dup&.freeze
    end

    # One verdict over one artifact, journaled as `gate_decision`.
    # `artifact_digest` is the JOIN KEY and addresses CONTENT, so an edited plan
    # is a different, un-approved address rather than a stale match. `epic_slug`
    # and `stage` are the PARTITION key a sign-off queue folds on, which is why
    # both are required and neither is derivable from the digest.
    #
    # `answered_by` (which surface) and `policy` (how it was reached) are
    # INDEPENDENT: a `"deferred"` policy still journals a real surface, and
    # reading either off the other would be a guess.
    #
    # `verdict` is an {Approval::Verdict}, journaled as its word in {WORDS};
    # `reason` is that verdict's note, journaled beside it. A hold is a verdict
    # of its own, never a denial under a surface name.
    #
    # `evidence_digest` and `reason` are nullable, and nullable is a value here
    # ("nothing was gathered", "no rationale was given"), not a missing field.
    #
    # `issue_id` is the partition's third member: nil for the epic-wide
    # stages, the issue's id for `issue_plan` and `implementation`, whose gates
    # are one issue's. `criteria_digest` is the {Gherkin::Criteria#digest} an
    # issue plan was approved WITH -- the same join key a grade record carries,
    # so a later grade can be matched to the criteria somebody signed off.
    # Both joined the shape after records were already on disk; a record
    # written before reads them as nil, which is exactly what it was.
    #
    # This reopen holds the verdict's wire form, and the one place a journaled
    # decision becomes a verdict again.
    class GateDecision
      WORDS = { Approval::Verdict::Approve => "approve", Approval::Verdict::Hold => "hold",
                Approval::Verdict::Deny => "deny" }.freeze

      BEFORE_VERDICTS = "it carries an approved boolean and no verdict, so it was written before gate decisions " \
                        "recorded one -- run `lain epic rewrite-verdicts` to rewrite its session in place"
      private_constant :BEFORE_VERDICTS

      # @param verdict [Approval::Verdict::Approve, Approval::Verdict::Hold, Approval::Verdict::Deny]
      # @return [String] approve, hold or deny
      def self.word(verdict) = WORDS.fetch(verdict.class)

      # A record from before verdicts is refused rather than read off its
      # boolean: a `false` there was a denial or a hold, and only the surface
      # name told them apart.
      #
      # @param record [Hash{String=>Object}] one journaled gate_decision
      # @return [Approval::Verdict::Approve, Approval::Verdict::Hold, Approval::Verdict::Deny] with `reason` as its note
      # @raise [ArgumentError] when `verdict` is not one of {WORDS}' words
      def self.verdict_in(record)
        kind = WORDS.key(record["verdict"])
        return kind.new(note: record["reason"]) if kind
        raise ArgumentError, "verdict is missing: #{BEFORE_VERDICTS}" if record.key?("approved")

        raise ArgumentError, "verdict must be one of #{WORDS.values.join(", ")}, got #{record["verdict"].inspect}"
      end
    end
  end
end
