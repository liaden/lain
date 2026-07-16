# frozen_string_literal: true

module Lain
  # The on-disk session format, promoted out of {Bench::Session} so a LIVE chat
  # can write a loadable session the same bytes a recorded bench run does. The
  # TURN and HEADER field names stay byte-compatible with {Bench::Session}, so
  # one Loader reads both; the live scribe adds three additive record types
  # ({Telemetry::Message}, {Telemetry::SessionClosed}, {Telemetry::RunInterrupted})
  # that an older reader's `of_type` narrowing skips by construction.
  #
  # The header is written FIRST, with `head: nil` meaning OPEN -- a session in
  # progress has no final anchor yet. A graceful close writes a
  # {Telemetry::SessionClosed} carrying the real head; a process that just stops
  # (SIGKILL) leaves the open header and no closer, which is exactly how a reader
  # tells the two apart. Every turn record still re-commits to its recorded
  # digest whether or not the session ever closed.
  #
  # == The open-session anti-truncation limit, stated honestly
  #
  # A write-first header cannot anchor a chain that does not exist yet, and a
  # Merkle chain self-verifies only its PREFIX -- so an OPEN session's torn tail
  # loads as a shorter-but-self-consistent open session, indistinguishable from
  # a process that stopped earlier. That is the deliberate price of durability
  # before completion; {Bench::Session}'s anchored header rejects truncation
  # only because it writes AFTER the run. A CLOSED session recovers the
  # protection: the anchor lives in the `session_closed` record (NOT the
  # header), and a loader must verify the rebuilt chain against it -- while an
  # open session's head is recoverable only as the LAST turn record's digest,
  # trusted to the extent the prefix re-commits.
  module SessionRecord
    HEADER_TYPE = "session"
    TURN_TYPE = "turn"

    module_function

    # The session header, byte-compatible with {Bench::Session}'s: exactly
    # {Context}'s constructor inputs plus the tool schema, reminders, and the
    # head anchor. `head:` defaults to nil -- the OPEN marker -- because the
    # scribe writes this before any turn commits and never rewrites it.
    # `resumed_from:` (T14's chain shape, `{"file" =>, "head" =>}`) merges in
    # only when present: a fresh session's header must stay byte-identical to
    # the pre-resume format, so absence is no key, never a nil value.
    def header(context:, toolset:, workspace: Workspace.empty, head: nil, resumed_from: nil)
      record = { "type" => HEADER_TYPE, "context_class" => context.class.name,
                 "model" => context.model, "max_tokens" => context.max_tokens,
                 "system" => context.system, "stream" => context.stream, "extra" => context.extra,
                 "head" => head,
                 "tools" => toolset.to_schema, "reminders" => workspace.reminders }
      resumed_from.nil? ? record : record.merge("resumed_from" => resumed_from)
    end

    # One turn record, the same fields {Bench::Session} writes: the body plus the
    # render edge, which is exactly what a Loader re-commits to recompute the
    # digest recorded beside it.
    def turn(turn)
      { "type" => TURN_TYPE, "digest" => turn.digest, "role" => turn.role,
        "content" => turn.content, "parent" => turn.parent, "meta" => turn.meta }
    end
  end
end

require_relative "session_record/scribe"
require_relative "session_record/replay"
