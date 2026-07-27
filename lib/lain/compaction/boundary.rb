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
    # Two corrections to the naive `messages.size - keep_last` slice, both
    # from Grounding F1/F2:
    #
    #   1. never cut between a `tool_use` message and its answering
    #      `tool_result` -- they are always exactly two adjacent messages
    #      (Correctness gate 2, `agent.rb:326-328`);
    #   2. land the retained tail on `assistant`, the only role that can
    #      follow the fixed-`user` replacement (Open decisions ruling) -- a
    #      strategy or a summarizer never computes a role from history
    #      parity, so this object takes no role parameter at all.
    #
    # Both corrections turn out to be the SAME search. A `tool_use` message is
    # always `assistant`-role and always the message immediately before its
    # `tool_result`, so "the tail starts on assistant" and "the pair is not
    # split" are one invariant, not two -- the rule is: **the greatest index
    # <= the naive split whose message begins an assistant turn.** Walking
    # backward from the naive split for that index satisfies both at once.
    # The tool-pair language survives in this doc because it is what
    # motivates the rule, not because it needs a second code path. A caller
    # that later relaxes the role rule (to permit a `user`-starting tail, say)
    # loses tool-pair safety along with it -- there is no separate guard to
    # fall back on.
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
    #   {#declined?} -- the request was real, but no `assistant`-starting
    #     message exists at or before the naive split, so no cut satisfies
    #     the rule above. This is NOT exotic: T1 ruled that adjacent `user`
    #     messages are legal production shape (a tool_result turn followed by
    #     the human's next ask), so a long run of `user` messages is real, and
    #     the backward search can run off the front of it. The naive
    #     `land_on_assistant` walk used to return 0 here and let {#empty?}
    #     lie about why -- `Need` would then never fire and compaction would
    #     silently stop happening, forever, with no error anywhere. This is
    #     never allowed to raise: a `Boundary` that raised would do so inside
    #     `Context#render`, mid-turn, on a history that is perfectly legal --
    #     worse than just not compacting this turn.
    #
    # Both states answer {#index} as 0 (nothing droppable, the same safe
    # default either way), so a caller that only wants "can I drop anything"
    # needs neither predicate. {#moved} is the diagnostic surface for the
    # case that is neither: how far the search walked. It is what
    # `spec/lain/compaction/head_spec.rb:357-372`'s cross-object agreement
    # sweep needs to say more than "these two integers differ" if it ever
    # goes red.
    class Boundary
      # @param messages [Array<Hash>] the full rendered message list. Only
      #   READ -- the caller keeps its array, untouched and unfrozen. Each
      #   entry must be a canonical-normalized projection (String-keyed
      #   `"role"`), the same precondition {Context::PinnedMessages}
      #   documents at `pinned_messages.rb:70-80` -- a Symbol-keyed or
      #   role-less entry does not raise on ITS OWN, but the backward search
      #   below reads `"role"` with `Hash#fetch`, so it surfaces as a loud
      #   `KeyError` the first time the walk reaches that message, rather
      #   than being silently treated as non-assistant forever.
      # @param keep_last [Integer] must be positive; see {#validated}, which
      #   borrows {Head}'s refusal rather than inventing a second.
      # @param pins [Context::PinnedMessages] accepted for interface parity
      #   with {Head} and {Context::Compact}, which both take the SAME pins
      #   object (F3) -- T4 hands one `Boundary` instance to both. It is
      #   never consulted: pin exemption is applied downstream against the
      #   fixed span this object answers, exactly as {Head#droppable} already
      #   applies it AFTER its own slice. Holding it anyway (an inert ivar,
      #   "for future introspection") was tried and reverted: it bought
      #   nothing, and a non-frozen duck-typed pins collaborator would have
      #   made this object fail its own `Ractor.shareable?` AC.
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

      # @return [Integer] how far the backward search moved from the naive
      #   `messages.size - keep_last` split: 0 when the naive split already
      #   landed on `assistant` (or was never taken, {#empty?}), the full
      #   distance attempted when it {#declined?}.
      attr_reader :moved

      # The request was vacuous: `keep_last` already covered the whole
      # history, so nothing was ever droppable.
      def empty? = @index.zero? && !@declined

      # The request was real, but no `assistant`-starting message exists at
      # or before the naive split -- there is no valid cut, so this object
      # declines rather than lying about why nothing dropped. See the class
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
      def snapped(messages)
        raw = [messages.size - @keep_last, 0].max
        return [0, false, 0] if raw.zero?

        land_on_assistant(messages, raw)
      end

      # Walks backward from `raw` for the greatest index whose message is
      # `assistant`-role -- resolving F1's role-landing rule and F2's
      # tool-pair rule in the same search (see class doc). Index 0 is never a
      # valid landing (`messages[0]` is always `user` in a well-formed
      # conversation), so reaching it without finding `assistant` means the
      # search exhausted the span: DECLINED, not "landed at 0."
      def land_on_assistant(messages, raw)
        index = raw
        index -= 1 while index.positive? && messages.fetch(index).fetch("role") != "assistant"
        index.positive? ? [index, false, raw - index] : [0, true, raw]
      end
    end
  end
end
