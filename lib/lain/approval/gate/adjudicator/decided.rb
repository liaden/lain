# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      class Adjudicator
        # Which artifact addresses a machine has already SETTLED, read off the
        # journal.
        #
        # It is a FOLD, not a set, for {SignoffQueue}'s reason one level over:
        # the record is the state, so two readers of one journal agree by
        # construction and a session that dies loses no verdict. Re-walked per
        # lookup rather than indexed once, because the whole question is whether
        # somebody ELSE -- another Adjudicator, another session -- settled this
        # address since we last looked, which a snapshot cannot answer.
        #
        # {Adjudicator::TERMINAL_POLICY} is the discriminator, and it is the only
        # honest one available: {Gate}'s approval registry is add-only, so it
        # answers "was this APPROVED" and leaves a terminal DENIAL looking
        # exactly like an artifact nobody ever judged. The `policy` label does
        # not -- it says a machine reached a verdict here, whichever way it went.
        # A `deferred` record is deliberately NOT terminal: parking is an
        # invitation to come back.
        #
        # == The identity is the DIGEST ALONE
        #
        # `(epic_slug, stage)` is on every record and {Approval::GateDecision}
        # refuses to be built without it, so ignoring it here is a decision, not
        # an oversight: one address adjudicated in `alpha/epic_plan` refuses the
        # same CONTENT in `beta/research`, permanently, with no override short
        # of editing the journal. It is chosen because it fails CLOSED and
        # because it is the identity {Gate#approved?} already uses -- an
        # approval is remembered by digest and carries across partitions, so a
        # partition-scoped refusal could disagree with a global approval, which
        # is the exact disagreement {AlreadyDecided} exists to prevent.
        #
        # It stops mattering in practice as submissions arrive pre-qualified:
        # `Submission#digest` addresses `{stage, slug, artifact}`, so the same
        # artifact in two partitions is already two addresses by the time it
        # reaches a gate.
        class Decided
          # A nil `decisions:` builds cleanly and then dies INSIDE the fold with
          # `NoMethodError: undefined method 'lazy' for nil` -- mid-decision,
          # after both spawns are paid for, naming neither the argument nor the
          # caller that omitted it. Refused where the mistake was made.
          MISSING = "Decided needs the journal read back -- the Journal.records duck (an Enumerable of parsed " \
                    "Hashes or raw NDJSON lines), got nil. There is no 'nothing was decided' default."
          private_constant :MISSING

          # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
          #   -- parsed Hashes or raw NDJSON lines -- RE-ENUMERATED on every
          #   lookup. The two Enumerator shapes are not interchangeable:
          #   `File.foreach(path)` (no block) re-opens the file per walk and is
          #   correct; `File.open(path).each_line` and `io.each_line` are
          #   one-shot, so a second lookup answers "nothing decided" and the
          #   guard fails OPEN. An Array snapshot is one-shot in the same way --
          #   it cannot contain the record this decision is about to write.
          def initialize(entries)
            raise ArgumentError, MISSING if entries.nil?

            @entries = entries
          end

          # The precondition {Adjudicator#call} runs before it spends anything.
          #
          # @param digest [String] the artifact address about to be judged
          # @return [nil] when no machine has settled this address
          # @raise [AlreadyDecided] naming the address and the verdict it
          #   already carries
          def ensure_undecided!(digest)
            settled = self[digest]
            raise AlreadyDecided, refusal(digest, settled) if settled
          end

          private

          # The LAST match, not the first. Which record refuses does not matter
          # -- any terminal record refuses, and that holds under any order --
          # but which one the MESSAGE names does: two conflicting terminal
          # records for one address are reachable (a pre-T9 journal permitted
          # them, and so does the concurrent window {AlreadyDecided} documents),
          # and journal order is time order, so the last one written is the one
          # that stands.
          def [](digest)
            Journal.records(@entries, type: SignoffQueue::JOURNAL_TYPE)
                   .select { |record| terminal?(record, digest) }
                   .to_a.last
          end

          def terminal?(record, digest)
            record["policy"].to_s == TERMINAL_POLICY && record["artifact_digest"].to_s == digest.to_s
          end

          def refusal(digest, settled)
            "artifact #{digest} already has a terminal adjudication (approved: #{settled["approved"]}) -- " \
              "Gate's approval registry is add-only, so a second verdict would leave it disagreeing " \
              "with the journal"
          end
        end
      end
    end
  end
end
