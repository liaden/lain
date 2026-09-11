# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      # Replays gate decisions a HUMAN (or {Policy::HandsOff}) already made in
      # an earlier run, keyed by the artifact's own digest -- so re-running an
      # epic-progressive arm against the SAME artifacts answers exactly as
      # recorded, with no human present and no live model asked to guess.
      #
      # {Policy::HandsOff} approves everything; this approves only what was
      # already approved and denies only what was already denied. An artifact
      # this policy has never seen names itself and REFUSES rather than
      # defaulting either way -- inventing a verdict nobody gave would make
      # the replay a fiction wearing the recording's name.
      #
      # NOT a {Policy} subclass, on purpose: `spec/lain/skill/shipped_skills_spec.rb`
      # pins `Policy.subclasses` to the exact family a session can CONFIGURE
      # through `[epics.gates]`, which the epic skills document -- and this
      # policy replays records from an EARLIER run, so no config entry
      # -- decided before any run has happened -- could ever name a digest to
      # replay. Composing {Policy::Boundary} rather than inheriting keeps that
      # family exactly the configurable four while still answering the same
      # `#decide(artifact, gate:, stage:, epic_slug:, issue_id:, criteria_digest:)`
      # duck every caller of a policy sends. A caller wires it directly, the way `bench altitude`'s
      # progressive arm does.
      class RecordedPolicy
        NAME = "recorded"

        # No recorded {Approval::GateDecision} names this artifact's digest.
        class Unrecorded < Error; end

        # Build from journaled `gate_decision` records, keeping the LATEST
        # verdict per artifact digest -- a re-decided address (the live queue
        # allows it) replays the answer the earlier run actually settled on,
        # not the first one it walked back from.
        #
        # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
        # @param queue [#drained?] forwarded to {#initialize} -- the sign-off
        #   queue the stage boundary is checked against
        # @return [RecordedPolicy]
        def self.from_journal(entries, queue:)
          decisions = Journal.records(entries, type: SignoffQueue::JOURNAL_TYPE)
                             .to_h { |record| [record["artifact_digest"], record] }
          new(decisions:, queue:)
        end

        # @param decisions [Hash{String=>Hash}] artifact digest => its
        #   journaled `gate_decision` record
        # @param queue [#drained?] the sign-off queue the stage boundary is
        #   checked against, or {Policy::Drained} when the session has none
        def initialize(decisions:, queue:)
          @decisions = decisions
          @boundary = Policy::Boundary.new(queue)
        end

        # Read off the NAME constant, the same durable-journal-value contract
        # {Policy#name} documents.
        def name = NAME

        # The whole seam a caller sends a policy: check the stage boundary,
        # look up the recorded verdict, replay it through the SAME
        # {Approval::Gate#call} every policy goes through.
        #
        # @param artifact [#digest, #gate_question]
        # @param gate [Gate]
        # @param stage [#to_s]
        # @param epic_slug [#to_s]
        # @param issue_id [String, nil] the issue an issue-scoped gate is about:
        #   its boundary is checked for that issue alone, and the replayed
        #   decision names it, so it drains that issue's parked sign-off
        # @param criteria_digest [String, nil] the criteria the artifact carries
        # @return [Boolean] whether the recorded verdict approved
        # @raise [Epic::StageBlocked] when an earlier stage of this epic (or of
        #   this issue) still holds sign-offs parked
        # @raise [Unrecorded] naming the digest when nothing was recorded for it
        def decide(artifact, gate:, stage:, epic_slug:, issue_id: nil, criteria_digest: nil)
          @boundary.ensure_open!(stage, epic_slug:, issue_id:)
          recorded = @decisions.fetch(artifact.digest) do
            raise Unrecorded, "no recorded gate decision for artifact #{artifact.digest.inspect} -- " \
                              "replaying a verdict nobody gave would make this run a fiction"
          end
          gate.call(artifact, asker: Policy::StandingAnswer.new(answer_for(recorded)), stage:, epic_slug:,
                              policy: NAME, issue_id:, criteria_digest:)
        end

        private

        def answer_for(recorded)
          recorded["approved"] ? Answer.approve(recorded["answered_by"]) : Answer.deny(recorded["answered_by"])
        end
      end
    end
  end
end
