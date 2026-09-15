# frozen_string_literal: true

module Lain
  class Tool
    # The `tool_result` a call is answered with when the conversation carries no
    # real result for it, and the only place this repo mints one. Every repair
    # of a stranded `tool_use` answers through here -- a run torn by an
    # interrupt ({Agent::ToolRunner::Answers}), a settle whose commit raised or
    # a budget stop after the call was committed ({Agent::ToolDelivery},
    # {Agent}), a stranded head met at the next ask ({Agent#ask}) or at load
    # ({CLI::Resume::Cancellation}) -- because two shapes for one fact is how
    # two repairs of one defect come to disagree. The shape is
    # {ResultBlock}'s, so a repair reaches the wire through the same gates
    # every real result does:
    #
    #     { "type" => "tool_result", "tool_use_id" => <the stranded id>,
    #       "content" => <the notice>, "is_error" => true }
    #
    # One block per stranded call, all in ONE user turn, in the order the model
    # made the calls, and the turn carries NO `meta`: `meta` is inside the
    # content address, and one torn turn can mix a finished tool's real output
    # with cancellations, so the fact is per block.
    #
    # Only the sentence differs between repairs, and each says what that repair
    # genuinely knows. The kinds are closed: a repair naming one this class has
    # no sentence for is a bug, and `fetch` says so.
    #
    # KNOWN HOLE, recorded rather than fixed here: a head carrying two
    # `tool_use` blocks with the SAME id yields two tool_results with the same
    # `tool_use_id`. {Context::Conversation#valid?} answers true for that (its
    # pairing rule does not count multiplicity) and the wire would reject it.
    # The malformed head is the cause and neither answering nor dropping one
    # fixes it, but this is what MANUFACTURES the paired duplicates.
    class Cancellation
      # A stranded call {ResultBlock}'s gate 4 refuses to build a result for,
      # because it names no usable id. Named rather than left as the builder's
      # ArgumentError: every repair runs on the way out of some other failure
      # -- an interrupt, a refused commit, a load -- and a raw ArgumentError
      # escaping one leaves its caller holding neither the repair nor the
      # failure it was handling.
      class Unpairable < Error; end

      # The FACT, and the only claim the no-result repairs make about the past.
      # It does NOT say the run was interrupted, because at load that is false
      # on two doors: a `--fork` point can sit below results the journal really
      # recorded, and an OPEN session's owner may still be appending.
      # "Cancelled" is said about the continuation, which every side knows.
      NO_RESULT = "The conversation being continued carries no result for this tool call, so it is " \
                  "cancelled: there is no output to read."

      # At load, and at an ask that finds its head stranded, nothing can tell
      # whether the tool ran, so this claims nothing either way.
      EFFECTS_UNKNOWN = "Whether the tool ran is not known from this conversation -- check before " \
                        "assuming its effects did or did not happen."

      # A tear knows more: whether the call was ever dispatched.
      # "May be" and not "were" for a running call, because the dispatch is
      # marked BEFORE the effect is built, so it over-claims in the safe
      # direction.
      NEVER_DISPATCHED = "The run was interrupted before this call was dispatched, so the tool did not run " \
                         "and had no effects."
      WAS_RUNNING = "The run was interrupted while this call was running, so its effects may be partly " \
                    "applied -- check before assuming they happened."

      # Neither "cancelled" nor "no result": when a settle's commit raises, the
      # tool DID produce a result, and what failed was recording it. When a
      # budget stop lands after the call was committed, the tool never ran. The
      # sentence is true of both, which is why it claims no more.
      ERRORED = "This tool call's result never reached the conversation: the run failed with an error " \
                "before it could be recorded. Check before assuming its effects did or did not happen."

      # Composed, never re-typed, so the shared fact cannot drift between the
      # three kinds that state it. Frozen, because an interpolated literal is
      # mutable even under `frozen_string_literal` and each is read straight
      # into a deeply-frozen record.
      NOTICES = { unknown: "#{NO_RESULT} #{EFFECTS_UNKNOWN}".freeze,
                  never_dispatched: "#{NO_RESULT} #{NEVER_DISPATCHED}".freeze,
                  was_running: "#{NO_RESULT} #{WAS_RUNNING}".freeze,
                  errored: ERRORED }.freeze

      # @param id [String] the tool_use id being answered
      # @param kind [Symbol] a key of {NOTICES}
      # @return [Hash] one tool_result block
      # @raise [Unpairable] when `id` names no tool_use
      # @raise [KeyError] for a kind with no sentence
      def self.block(id, kind)
        notice = NOTICES.fetch(kind)
        ResultBlock.of(Result.error(notice), tool_use_id: id).to_h
      rescue ArgumentError => e
        raise Unpairable, e.message
      end

      # Minted EAGERLY, so construction is the one place {Unpairable} can
      # surface; a lazy #blocks would raise past whichever caller rescued it.
      #
      # @param head [Lain::Event] an assistant turn carrying the stranded calls
      # @param kind [Symbol] which repair this is, a key of {NOTICES}
      # @raise [Unpairable] when a stranded call names no tool_use id
      def initialize(head, kind:)
        @blocks = head.content.grep(Hash)
                      .select { |block| block["type"] == "tool_use" }
                      .map { |use| self.class.block(use["id"], kind) }
                      .freeze
        freeze
      end

      # @return [Array<Hash>] one tool_result block per stranded call, in the
      #   order the model made them -- one user turn's content
      attr_reader :blocks
    end
  end
end
