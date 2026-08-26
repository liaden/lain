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
    # Deliberately carries no usage or cost, and that gap is ACCEPTED rather
    # than a bug to route around. No {TurnUsage} record exists for a salvaged
    # turn -- there was no live Agent and no provider call, which is the entire
    # point -- so {Ledger} prices it at zero even though real tokens were spent
    # the first time around, the same shape as a silently-retried request.
    # Manufacturing a {TurnUsage} after the fact would re-journal the ORIGINAL
    # run's own `usage` number under a different digest, double-counting it in
    # any aggregate that sums those records.
    #
    # Emitted by {CLI::Resume}, never by {SessionRecord::Salvage} itself, which
    # is a pure calculation over the ducks it is handed and never touches a
    # file.
    Salvaged = Data.define(:request_digest, :head_before, :head_after) do
      include Journalable

      def initialize(request_digest:, head_before:, head_after:)
        super(request_digest: request_digest.dup.freeze, head_before: head_before&.dup&.freeze,
              head_after: head_after.dup.freeze)
      end
    end
  end
end
