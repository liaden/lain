# frozen_string_literal: true

module Lain
  module Epic
    # What an edit to a signed-off issue plan does to its gate: the approval stays on the record, but
    # the new bytes were never approved, so they park for a human as a deferral does. It is written
    # only where the partition stands approved at other bytes than the issue holds now, so an edit
    # that restores the approved bytes, or one made before any approval, journals nothing.
    #
    # The record is a {GateDecision::Deferred}, never a deny: {SignoffQueue} parks it and leaves the
    # standing approval alone, where a deny would revoke it.
    class Reopen
      STAGE = "issue_plan"
      NOTE = "reopened by an edit"
      SURFACE = "epic_write"
      RESTORED = "restored to the approved bytes"
      SUMMARY = "issue %s was edited after its plan was approved"

      # @param queue [SignoffQueue] the decisions folded as they stand
      # @param digests [#digest] answers `digest(epic_slug, stage, issue_id)`, nil where the plan no longer reads
      # @param epic_slug [String] the epic
      # @param issue_ids [Array<String>] the issues asked about
      # @return [Array<String>] those whose approval stands over bytes the issue no longer holds
      def self.stale(queue, digests, epic_slug:, issue_ids:)
        approved = issue_ids.select { |id| queue.approved?(epic_slug, STAGE, issue_id: id) }
        approved.select { |id| stale?(queue, epic_slug, id, digests.digest(epic_slug, STAGE, id)) }
      end

      # @param queue [SignoffQueue] the decisions folded as they stand
      # @param epic_slug [String] the epic
      # @param issue_id [String] the issue
      # @param current [String, nil] the plan's digest as it stands now
      # @return [Boolean]
      def self.stale?(queue, epic_slug, issue_id, current)
        standing = queue.standing(epic_slug, STAGE, issue_id:)
        !current.nil? && !standing.nil? && standing.verdict.approved? && standing.digest != current
      end

      # @param journals [#call] a fresh fold of every session's decisions per call, so an approval from
      #   another chat is seen
      # @param digests [#digest] see {.stale}
      # @param journal [#record] where the reopen lands
      def initialize(journals:, digests:, journal:)
        @journals = journals
        @digests = digests
        @journal = journal
      end

      # An edit back to the approved bytes withdraws what the earlier edit parked.
      #
      # @return [Array<String>] the issue reopened, empty when the edit reopened nothing
      def reopened(epic_slug:, issue_id:)
        queue = SignoffQueue.from_journal(@journals.call.to_a)
        current = @digests.digest(epic_slug, STAGE, issue_id)
        return restored(queue, epic_slug, issue_id, current) if standing_at?(queue, epic_slug, issue_id, current)
        return [] unless self.class.stale?(queue, epic_slug, issue_id, current)
        return [] if parked?(queue, epic_slug, issue_id, current)

        journal(epic_slug, issue_id, current)
        [issue_id]
      end

      private

      def standing_at?(queue, epic_slug, issue_id, current)
        !current.nil? && queue.standing?(current, epic_slug, STAGE, issue_id:)
      end

      # The approval is stated again before the parked drafts are denied, because a deny of a draft that
      # the standing approval superseded leaves that approval standing, and a lone deny would withdraw it.
      def restored(queue, epic_slug, issue_id, current)
        stale = queue.parked(epic_slug, STAGE, issue_id:).map(&:artifact_digest) - [current]
        return [] if stale.empty?

        settle(epic_slug, issue_id, current, Approval::Verdict::Approve.new(note: RESTORED))
        stale.each { |digest| settle(epic_slug, issue_id, digest, Approval::Verdict::Deny.new(note: RESTORED)) }
        []
      end

      def settle(epic_slug, issue_id, digest, verdict)
        @journal.record(GateDecision.new(artifact_digest: digest, epic_slug:, stage: STAGE, issue_id:, verdict:,
                                         answered_by: SURFACE, policy: SignoffQueue::SIGNOFF_POLICY, latency: 0))
      end

      def parked?(queue, epic_slug, issue_id, current)
        queue.parked(epic_slug, STAGE, issue_id:).any? { |item| item.artifact_digest == current }
      end

      def journal(epic_slug, issue_id, digest)
        @journal.record(GateDecision.new(artifact_digest: digest, epic_slug:, stage: STAGE, issue_id:,
                                         verdict: GateDecision::Deferred.new(note: NOTE), answered_by: SURFACE,
                                         policy: SignoffQueue::DEFERRED_POLICY, latency: 0))
        @journal.record(Telemetry::AwaitingHuman.new(kind: "gate", ref: digest, deferred: true, epic_slug:,
                                                     stage: STAGE, issue_id:, summary: SUMMARY % issue_id))
      end
    end
  end
end
