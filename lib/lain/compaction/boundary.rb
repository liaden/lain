# frozen_string_literal: true

module Lain
  module Compaction
    # Where a compaction span may be cut. {Head} measures a span already
    # projected at some slice, and {Context::Compact} performs the cut -- the
    # cut RULE is consulted by both and they must agree, so it lives here
    # rather than on either. Same shape as the disagreement `Head`'s own doc
    # (`head.rb:20-29`) exists to delete, one level up: the answer is an
    # INDEX, never a rewritten array.
    #
    # == One correction to the naive `messages.size - keep_last` slice
    #
    # **Never cut between a `tool_use` message and its answering
    # `tool_result`.** They are always exactly two adjacent messages
    # (Correctness gate 2, `agent.rb:326-328`), so the cut moves by at most one
    # position -- back, never forward, because retaining one extra message is
    # the safe direction while dropping one extra breaks the `keep_last` floor.
    #
    # == Why there is no longer a second, role-based correction
    #
    # RE-RULED 2026-07-27 (orchestrator, during T4). This class shipped with a
    # second rule -- *land the retained tail on `assistant`* -- and an argument
    # that it and the tool-pair rule were one backward search. That argument
    # was sound when it was written and is now wrong, so it is recorded here
    # rather than deleted: the next reader's instinct will be to restore it.
    #
    # It was derived while the replacement was an **assistant** message. F1's
    # second 400 was `summary(assistant)` followed by another assistant, and
    # landing the tail on `assistant` was the fix for THAT. T4 then fixed the
    # replacement's role at **`user`** (Open decisions ruling), and T1
    # separately ruled -- verified against `agent_spec.rb:407-410` -- that
    # adjacent `user` messages are legal production shape while only adjacent
    # `assistant` is a violation. Together those make the role rule vacuous: a
    # `user` replacement can be followed by EITHER role (`user + assistant`
    # alternates, `user + user` is legal), so no tail role can produce an
    # invalid adjacency, and the rule's only remaining effect was to move cuts
    # that never needed moving.
    #
    # That effect was not small. The backward walk ran until it found an
    # `assistant`, so a long run of `user` messages -- legal per T1, and the
    # ordinary shape of a tool_result turn followed by the human's next ask --
    # pushed the cut arbitrarily far back, or off the front entirely. Measured
    # during T4: six spec files asserting compaction over all-`user` histories
    # went red, and the T2 panel's near-decline case retained 31 of 32 messages
    # when 3 were asked for.
    #
    # **The cost, named by T2's own NIT 7 and now come due:** pair safety used
    # to be EMERGENT. A `tool_result` is always a `user` message immediately
    # after its `assistant` `tool_use`, so "land on assistant" implied "do not
    # split a pair" for free -- which meant nothing turned red for pair safety
    # specifically. Relaxing the role rule removes what was accidentally
    # providing it, so the tool-pair rule is now written directly above, and
    # tested directly in `boundary_spec.rb`.
    #
    # == Two ways to answer "nothing is safely droppable"
    #
    # {#empty?} and {#declined?} are BOTH honest no-ops -- neither drops
    # anything -- but they have different causes and a caller debugging a
    # session that mysteriously stopped compacting must be able to tell them
    # apart, so they are two distinctly named predicates, never one boolean
    # doing double duty:
    #
    #   {#empty?} -- the request itself was vacuous: `keep_last` was at least
    #     the whole history, so there was never anything to drop.
    #   {#declined?} -- the request was real, but the only legal cut is 0: the
    #     naive split would split a pair, and the one move off it lands on the
    #     front. Under the relaxed rule that is exactly one shape -- a single
    #     droppable message which IS the `tool_use` answered by the first
    #     retained one -- rather than the whole family of `user` runs it used
    #     to cover. Nearly unreachable now, and kept because it is still the
    #     only honest answer for that shape.
    #
    #     Through a {Compaction::Derivation} it is unreachable OUTRIGHT, and
    #     changing the cut rule here is what would change that. Both routes to a
    #     decline in {#snapped} require either a `tool_use` at index 0 or one
    #     message carrying both a `tool_result` and a `tool_use`, and
    #     {Context::Conversation} refuses both (invariants 1 and 5) -- so a
    #     declining source is one the derivation will not send. That coupling is
    #     pinned as a characterization example in
    #     `spec/lain/compaction/derivation_spec.rb` ("cannot reach a declined
    #     cut"), which is the example a new cut rule here will break. Breaking it
    #     is not automatically wrong; leaving it broken silently is.
    #
    #     This is never allowed to raise: a
    #     `Boundary` that raised would do so inside `Context#render`, mid-turn,
    #     on a history that is perfectly legal -- worse than just not
    #     compacting this turn.
    #
    # Both states answer {#index} as 0 (nothing droppable, the same safe
    # default either way), so a caller that only wants "can I drop anything"
    # needs neither predicate. {#moved} is the diagnostic surface for the case
    # that is neither. {Head} answers it too, because {Compaction::Source}
    # already holds a {Head} when it journals the turn's decision.
    class Boundary
      # @param messages [Array<Hash>] the full rendered message list. Only
      #   READ -- the caller keeps its array, untouched and unfrozen. Each
      #   entry must be a canonical-normalized projection (String-keyed
      #   `"content"`), the same precondition {Context::PinnedMessages}
      #   documents at `pinned_messages.rb:70-80` -- a Symbol-keyed or
      #   content-less entry does not raise on ITS OWN, but the pair check
      #   below reads `"content"` with `Hash#fetch`, so it surfaces as a loud
      #   `KeyError` rather than as a message that silently appears to carry no
      #   tool blocks and gets its pair split. `"role"` is no longer read at
      #   all: the cut rule stopped depending on roles when the replacement's
      #   role became fixed, so a role-less projection is not this object's
      #   business.
      # @param keep_last [Integer] must be positive; see {#validated}, which
      #   borrows {Head}'s refusal rather than inventing a second.
      # @param pins [Context::PinnedMessages] accepted for interface parity
      #   with {Head} and {Context::Compact}, which both take the SAME pins
      #   object (F3). It is never consulted: pin exemption is applied
      #   downstream against the fixed span this object answers, exactly as
      #   {Head#droppable} already applies it AFTER its own slice. Holding it
      #   anyway (an inert ivar, "for future introspection") was tried and
      #   reverted: it bought nothing, and a non-frozen duck-typed pins
      #   collaborator would have made this object fail its own
      #   `Ractor.shareable?` AC.
      def initialize(messages:, keep_last:, pins: Context::PinnedMessages::NONE) # rubocop:disable Lint/UnusedMethodArgument
        @keep_last = validated(keep_last)
        @index, @declined, @moved = snapped(messages)
        freeze
      end

      # @return [Integer] the split index: `messages[0...index]` is
      #   droppable, `messages[index..]` is the retained tail. 0 whenever
      #   {#empty?} or {#declined?} is true -- both mean "nothing is safely
      #   droppable," by different causes.
      attr_reader :index

      # @return [Integer] how far the cut moved from the naive
      #   `messages.size - keep_last` split: 0 when it split no tool pair (or
      #   was never taken, {#empty?}), 1 when it moved off one, and the full
      #   naive distance when it {#declined?} -- so `index + moved == raw`
      #   holds in every state, which is what the sweep asserts.
      attr_reader :moved

      # The request was vacuous: `keep_last` already covered the whole
      # history, so nothing was ever droppable.
      def empty? = @index.zero? && !@declined

      # The request was real, but the only legal cut is 0 -- see the class
      # doc's "Two ways to answer" section.
      def declined? = @declined

      private

      # Mirrors {Head#validated} line for line: the same refusal, for the
      # same reasons (`head.rb:86-96`), borrowed rather than reinvented so
      # the two objects cannot drift onto different rules for the same
      # question.
      def validated(keep_last)
        integer = Integer(keep_last)
        raise ArgumentError, "keep_last must be positive, got #{integer}" unless integer.positive?

        integer
      end

      # @return [Array(Integer, bool, Integer)] index, declined?, moved
      #
      # The one-position move is checked again at its destination rather than
      # taken on faith. In a well-formed history it always clears -- a
      # `tool_result` is preceded by its `tool_use`, never by another
      # `tool_result` -- so the second check can only fire on a message
      # carrying both a `tool_use` and a `tool_result` answering the one before
      # it, which nothing in `lib/` emits. Declining there is the safe answer
      # for a shape whose pairing this object cannot honour.
      def snapped(messages)
        raw = [messages.size - @keep_last, 0].max
        return [0, false, 0] if raw.zero?
        return [raw, false, 0] unless splits_pair?(messages, raw)

        off = raw - 1
        off.positive? && !splits_pair?(messages, off) ? [off, false, 1] : [0, true, raw]
      end

      # Would cutting at `index` leave a `tool_use` in the dropped span and its
      # answering `tool_result` in the retained tail?
      #
      # By ID, not by block type: a `tool_result` at the head of the tail whose
      # `tool_use` is nowhere near it was ALREADY an orphan in the source, and
      # moving the cut for it would retain a message for no reason while
      # reporting a {#moved} the caller cannot act on.
      def splits_pair?(messages, index)
        ids(messages[index - 1], "tool_use", "id")
          .intersect?(ids(messages[index], "tool_result", "tool_use_id"))
      end

      def ids(message, type, key)
        blocks(message).select { |block| block["type"] == type }.filter_map { |block| block[key] }
      end

      # {Context::Conversation#blocks}' reading, and its reasoning: a content
      # that is not a list carries no blocks rather than raising, because a
      # bare String content is a shape the Messages API itself accepts
      # (`conversation.rb:188`) and refusing it would raise inside
      # `Context#render` over something legal. A missing KEY is a different
      # thing -- a broken precondition -- and stays loud.
      def blocks(message)
        content = message.fetch("content")

        content.is_a?(Array) ? content.grep(Hash) : []
      end
    end
  end
end
