# frozen_string_literal: true

module Lain
  module Compaction
    # Where a compaction span may be cut. {Head} measures a span already
    # projected at some slice and {Context::Compact} performs the cut -- the
    # cut RULE is consulted by both and they must agree, so it lives here
    # rather than on either. The answer is an INDEX, never a rewritten array.
    #
    # One correction to the naive `messages.size - keep_last` slice: **never
    # cut between a `tool_use` message and its answering `tool_result`.** They
    # are always exactly two adjacent messages, so the cut moves by at most one
    # position -- back, never forward, because retaining one extra message is
    # the safe direction while dropping one extra breaks the `keep_last` floor.
    #
    # == Why there is no second, role-based correction
    #
    # This class shipped with one -- *land the retained tail on `assistant`* --
    # and it is recorded here rather than deleted because the next reader's
    # instinct will be to restore it. It was derived while the replacement was
    # an ASSISTANT message. The replacement's role was later fixed at `user`,
    # and adjacent `user` messages are legal production shape while only
    # adjacent `assistant` is a violation, which makes the rule vacuous: a
    # `user` replacement can be followed by either role, so no tail role can
    # produce an invalid adjacency. Its only remaining effect was to move cuts
    # that never needed moving -- and not slightly, since the backward walk ran
    # until it found an `assistant`, so an ordinary run of `user` messages
    # pushed the cut arbitrarily far back or off the front entirely. Measured
    # when the rule was relaxed: six spec files asserting compaction over
    # all-`user` histories went red, and a near-decline case retained 31 of 32
    # messages when 3 were asked for.
    #
    # The cost, now come due: pair safety used to be EMERGENT. A `tool_result`
    # is always a `user` message immediately after its `assistant` `tool_use`,
    # so "land on assistant" implied "do not split a pair" for free. Relaxing
    # the role rule removes what was accidentally providing it, so the
    # tool-pair rule is written directly above and tested directly.
    #
    # == Two ways to answer "nothing is safely droppable"
    #
    # Both are honest no-ops with different causes, and a caller debugging a
    # session that mysteriously stopped compacting must be able to tell them
    # apart. {#empty?}: `keep_last` covered the whole history, so there was
    # never anything to drop. {#declined?}: the request was real but the only
    # legal cut is 0 -- a single droppable message which IS the `tool_use`
    # answered by the first retained one.
    #
    # Through a {Compaction::Derivation} a decline is unreachable OUTRIGHT, and
    # changing the cut rule here is what would change that: both routes to one
    # in {#snapped} require either a `tool_use` at index 0 or one message
    # carrying both a `tool_result` and a `tool_use`, and
    # {Context::Conversation} refuses both. That coupling is pinned as a
    # characterization example in `spec/lain/compaction/derivation_spec.rb`
    # ("cannot reach a declined cut"), which is the example a new cut rule here
    # will break. Breaking it is not automatically wrong; leaving it broken
    # silently is.
    #
    # Neither state ever raises: a `Boundary` that raised would do so inside
    # `Context#render`, mid-turn, on a history that is perfectly legal -- worse
    # than just not compacting this turn. Both answer {#index} as 0, so a
    # caller that only wants "can I drop anything" needs neither predicate.
    class Boundary
      # @param messages [Array<Hash>] the full rendered message list. Only
      #   READ -- the caller keeps its array, untouched and unfrozen. Each
      #   entry must be a canonical-normalized projection (String-keyed
      #   `"content"`); the pair check reads `"content"` with `Hash#fetch`, so
      #   a Symbol-keyed entry surfaces as a loud `KeyError` rather than as a
      #   message that silently appears to carry no tool blocks and gets its
      #   pair split. `"role"` is not read at all, since the cut rule stopped
      #   depending on roles when the replacement's role became fixed.
      # @param keep_last [Integer] must be positive; the module's rule
      #   ({Compaction.validate_keep_last}), consulted rather than restated so
      #   this object and {Head} cannot drift onto two refusals for one question.
      # @param pins [Context::PinnedMessages] accepted for interface parity
      #   with {Head} and {Context::Compact}, and never consulted: pin
      #   exemption is applied downstream against the fixed span this object
      #   answers, as {Head#droppable} does AFTER its own slice. Holding it in
      #   an inert ivar was tried and reverted -- a non-frozen duck-typed pins
      #   collaborator would make this object fail `Ractor.shareable?`.
      def initialize(messages:, keep_last:, pins: Context::PinnedMessages::NONE) # rubocop:disable Lint/UnusedMethodArgument
        @keep_last = Compaction.validate_keep_last(keep_last)
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
      #   was never taken), 1 when it moved off one, and the full naive
      #   distance when it {#declined?} -- so `index + moved == raw` holds in
      #   every state, which is what the specs assert.
      attr_reader :moved

      def empty? = @index.zero? && !@declined

      def declined? = @declined

      private

      # @return [Array(Integer, Boolean, Integer)] index, declined?, moved
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
      # bare String content is a shape the Messages API itself accepts and
      # refusing it would raise inside `Context#render` over something legal.
      # A missing KEY is a broken precondition, and stays loud.
      def blocks(message)
        content = message.fetch("content")

        content.is_a?(Array) ? content.grep(Hash) : []
      end
    end
  end
end
