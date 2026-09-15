# frozen_string_literal: true

module Lain
  # The on-disk session format, promoted out of {Bench::Session} so a LIVE chat
  # writes a loadable session in the same bytes a recorded bench run does. TURN
  # and HEADER field names stay byte-compatible with {Bench::Session}, so one
  # Loader reads both; the live scribe adds four additive record types an older
  # reader's `of_type` narrowing skips by construction.
  #
  # The header is written FIRST, with `head: nil` meaning OPEN -- a session in
  # progress has no final anchor yet. A graceful close writes a
  # {Telemetry::SessionClosed} carrying the real head; a SIGKILL leaves the open
  # header and no closer, which is how a reader tells the two apart.
  #
  # == The open-session anti-truncation limit, stated honestly
  #
  # A write-first header cannot anchor a chain that does not exist yet, and a
  # Merkle chain self-verifies only its PREFIX -- so an OPEN session's torn tail
  # loads as a shorter-but-self-consistent open session, indistinguishable from a
  # process that stopped earlier. That is the deliberate price of durability
  # before completion; {Bench::Session}'s anchored header rejects truncation only
  # because it writes AFTER the run. A CLOSED session recovers the protection:
  # the anchor lives in the `session_closed` record, NOT the header, and a loader
  # verifies the rebuilt chain against it -- while an open session's head is
  # recoverable only as the LAST turn record's digest.
  module SessionRecord
    HEADER_TYPE = "session"
    TURN_TYPE = "turn"
    REWOUND_TYPE = "rewound"
    # Named beside the types it deliberately is NOT: a spawned chain's turn is no
    # render-chain `turn` (the fold would re-derive it against the wrong parent)
    # and no `message` (a :turn's render edge is part of its address).
    CHILD_TURN_TYPE = "child_turn"

    module_function

    # Byte-compatible with {Bench::Session}'s: {Context}'s constructor inputs
    # plus the tool schema, reminders and the head anchor. `head:` defaults to
    # nil, the OPEN marker, because the scribe writes this before any turn
    # commits and never rewrites it. `resumed_from:` merges in only when present
    # -- a fresh session's header must stay byte-identical to the pre-resume
    # format, so absence is no key, never a nil value. The context pipeline's
    # name follows the same rule, through {.context_pipeline}.
    #
    # `profile:` is the run profile's fields beside `model` -- `provider`,
    # `api_base`, `num_ctx`, `num_batch` -- the keys {Bench::Session}'s own
    # header already spells `provider` with, so one reader reads both. It is
    # what a resumed or forked chat defaults its backend to.
    #
    # `writer:` is the process writing the file ({Liveness::Writer}), so a
    # reader elsewhere can tell a crashed session from a quiet one; an
    # unrecorded writer writes no field.
    def header(context:, toolset:, workspace: Workspace.empty, head: nil, resumed_from: nil, profile: {},
               writer: Liveness::Writer::UNRECORDED)
      record = { "type" => HEADER_TYPE, "context_class" => context.class.name,
                 "model" => context.model, "max_tokens" => context.max_tokens,
                 "system" => context.system, "stream" => context.stream, "extra" => context.extra,
                 "head" => head,
                 "tools" => toolset.to_schema, "reminders" => workspace.reminders }
      record = record.merge(context_pipeline(context), profile, writer.to_header)
      resumed_from.nil? ? record : record.merge("resumed_from" => resumed_from)
    end

    # The header field naming which catalog pipeline rendered the session, and
    # no field at all when none was named. Shared with {Bench::Session}'s own
    # header writer, because one Loader reads both and resolves this key back.
    #
    # @param context [Context]
    # @return [Hash{String => String}] empty for an unnamed pipeline
    def context_pipeline(context)
      context.pipeline_name.nil? ? {} : { "context_pipeline" => context.pipeline_name }
    end

    # The same fields {Bench::Session} writes: the body plus the render edge,
    # which is exactly what a Loader re-commits to recompute the digest recorded
    # beside it.
    #
    # `causal_parents` -- the SET edge, sorted and frozen by {Event} -- rides here
    # because it is part of that content address, so a record without it cannot
    # re-commit. It merges in only when the turn HAS one, on {.header}'s
    # `resumed_from` idiom, so a turn with no causal edge stays byte-identical to
    # every record written before the field existed and the committed fixtures
    # keep loading unchanged.
    def turn(turn)
      record = { "type" => TURN_TYPE, "digest" => turn.digest, "role" => turn.role,
                 "content" => turn.content, "parent" => turn.parent, "meta" => turn.meta }
      turn.causal_parents.empty? ? record : record.merge("causal_parents" => turn.causal_parents)
    end

    # The render head moved BACKWARD -- the one record that changes the fold
    # position instead of extending it. Both digests are already recorded
    # (`to: nil` is the empty session), so a loader folding in file order checks
    # out `to` and verifies later turns as extending it, while the turns above
    # `from` stay reachable in the Store.
    def rewound(from:, to:)
      { "type" => REWOUND_TYPE, "from" => from, "to" => to }
    end
  end
end

require_relative "session_record/scribe"
require_relative "session_record/replay"
require_relative "session_record/salvage"
