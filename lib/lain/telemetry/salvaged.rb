# frozen_string_literal: true

module Lain
  module Telemetry
    # One salvage-on-resume: the harness recovered a paid-for-but-uncommitted
    # response from the {Provider::ResponseWal} instead of re-spending.
    # `request_digest` is the join key onto the {RequestSent} the response
    # answers; `head_before`/`head_after` are the Timeline heads either side of
    # the recovery, so a reader sees exactly which turn got recovered without
    # re-deriving it from the surrounding `turn` records. `head_before` is nil
    # when the crashed request was the session's very first -- an empty
    # Timeline has no head to name, the same nil-is-a-value idiom {MemoryRoot}
    # uses for an empty index, though the two are unrelated structures and
    # the nil arises for a different reason in each.
    #
    # Deliberately carries no usage or cost. {Agent::Accounting} never ran this
    # turn through the ordinary commit-then-journal atom -- there was no live
    # Agent, no provider call, that is the entire point of salvage -- so no
    # {TurnUsage} record exists for it either, and {Ledger} prices a salvaged
    # turn at zero. That is an accepted, DOCUMENTED gap, not a bug to route
    # around here: real tokens were genuinely spent the first time around, the
    # same shape as a silently-retried request (see {ProviderRetry}) where
    # real spend can exceed what the reported Usage ever shows. Inventing a
    # {TurnUsage} record after the fact would need a stop_reason and a token
    # count this class has no independent way to attribute correctly (the
    # recovered SSE stream's own `usage` field is exactly the number the
    # ORIGINAL, now-vanished Agent run would have journaled, and re-journaling
    # it a second time under a different digest would double-count it in any
    # aggregate that sums TurnUsage records) -- so the honest choice is a zero
    # line here, not a manufactured one there.
    #
    # Emitted by {CLI::Resume}, never by {SessionRecord::Salvage} itself -- that
    # class is a pure calculation over the ducks it is handed and never touches a
    # file (see its class comment); writing the record, like every other file
    # effect of a resume, is the CLI layer's job.
    Salvaged = Data.define(:request_digest, :head_before, :head_after) do
      include Journalable

      def initialize(request_digest:, head_before:, head_after:)
        super(request_digest: request_digest.dup.freeze, head_before: head_before&.dup&.freeze,
              head_after: head_after.dup.freeze)
      end
    end
  end
end
