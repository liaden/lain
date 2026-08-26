# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # THE CONTRACT THE TEAR-SIDE REPAIR MUST MATCH. The `tool_result` block
      # a cancelled tool call is answered with, and the only place this repo
      # mints one: {Agent::ToolRunner::Answers} commits the SAME block at the
      # tear, and two shapes for one fact is how two repairs of one defect come
      # to disagree.
      #
      # The shape, exactly, is {Tool::ResultBlock}'s -- the sole writer of a
      # tool_result block in `lib/`, so this reaches the wire through the same
      # gates every real result does:
      #
      #     { "type" => "tool_result", "tool_use_id" => <the stranded id>,
      #       "content" => NOTICE, "is_error" => true }
      #
      # One block per stranded call, all of them in ONE user turn
      # ({Agent#perform_tools}'s correctness gate 2), in the order the model
      # made the calls. `is_error` is true because the call produced nothing;
      # it is read off the {Tool::Result}, never inferred.
      #
      # **The turn carries NO `meta`, and the tear-side repair must not add
      # one.** Two reasons, and the first is the binding one: `meta` is inside
      # the content address ({Event.turn}), so adding a key later moves every
      # projected digest. The second is that a turn-level "this is a
      # cancellation" flag cannot survive the tear side's own first case, where
      # ONE turn carries a finished tool's real output beside two cancellations
      # -- the fact is per-block, which is the granularity both repairs share.
      #
      # KNOWN HOLE, recorded rather than fixed here: a head carrying two
      # `tool_use` blocks with the SAME id yields two tool_results with the
      # same `tool_use_id`. {Context::Conversation#valid?} answers true for
      # that (its pairing rule does not count multiplicity) and the wire would
      # reject it. The malformed head is the cause and neither answering nor
      # dropping one fixes it -- but this is what MANUFACTURES the paired
      # duplicates, so it is named here and reported against `valid?`.
      #
      # It is a PROJECTION, never a record: {Resume#settled} commits it onto the
      # rebuilt in-memory Timeline, and the journal that witnessed the tear is
      # left exactly as it was. Nothing here claims the tool produced output --
      # which is what separates it from the fabrication the backstop was right
      # to refuse ({Resume::MidTool} states that refusal now).
      class Cancellation
        # A torn head this projection cannot answer: {Tool::ResultBlock}'s
        # gate 4 refuses to build a result that names no tool_use, and no
        # projection makes such a chain valid. Named rather than left as the
        # builder's ArgumentError so the door can translate it into its own
        # refusal instead of leaking a raw error with no file attached.
        class Unpairable < Error; end

        # The FACT, and the only claim this repair makes about the past: the
        # conversation being continued carries no result for the call. It does
        # NOT say the run was interrupted, because on two live doors that is
        # false -- a `--fork` point can sit below results the journal really
        # recorded (the call returned; its output is in the file being forked),
        # and an OPEN session's owner may still be appending. "Cancelled" is
        # said about the continuation, which is a thing this side knows, never
        # about the original run, which it does not.
        #
        # The tear-side repair SHARES this half verbatim: it is true at the tear too.
        NO_RESULT = "The conversation being continued carries no result for this tool call, so it is " \
                    "cancelled: there is no output to read."

        # The half the tear-side repair REPLACES, and the only one it may. At
        # load there is no way to know whether the tool ran, so this claims
        # nothing either way about effects. {Agent::ToolRunner::Answers} is
        # present at the tear and CAN distinguish "never dispatched" from "was
        # running mid-call" -- it substitutes its own sentence here and keeps
        # {NO_RESULT} untouched.
        EFFECTS_UNKNOWN = "Whether the tool ran is not known from this conversation -- check before " \
                          "assuming its effects did or did not happen."

        # Composed, never re-typed: a shared prefix plus a replaceable clause is
        # a seam the tear-side repair can hold, where "keep this string
        # byte-identical" was only a request in prose.
        NOTICE = "#{NO_RESULT} #{EFFECTS_UNKNOWN}".freeze

        # Minted EAGERLY, so construction is the one place {Unpairable} can
        # surface: a lazy #blocks raises past whichever caller rescued it.
        #
        # @param head [Lain::Event] an assistant turn {Event.pending_tool_use?}
        #   answers true for
        # @raise [Unpairable] when a stranded call names no tool_use id
        def initialize(head)
          @blocks = head.content.grep(Hash)
                        .select { |block| block["type"] == "tool_use" }
                        .map { |use| block_for(use["id"]) }
                        .freeze
          freeze
        end

        # @return [Array<Hash>] one tool_result block per stranded call, in the
        #   order the model made them -- one user turn's content
        attr_reader :blocks

        private

        def block_for(id)
          Tool::ResultBlock.of(Tool::Result.error(NOTICE), tool_use_id: id).to_h
        rescue ArgumentError => e
          raise Unpairable, e.message
        end
      end
    end
  end
end
