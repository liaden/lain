# frozen_string_literal: true

module Lain
  class Context
    # Summarizes the head of the message list once it crosses a token
    # threshold, keeping the trailing `keep_last` messages verbatim.
    #
    # Purity forbids calling a live model mid-#render -- that would make dry
    # replay nondeterministic and break the cache-purity constraint Context
    # itself depends on. So the summary comes from an INJECTED, already pure
    # `summarizer` (a deterministic `#call(dropped_messages) -> String`).
    #
    # The token count is a proxy -- the canonical byte length of the
    # candidate-for-drop messages -- rather than a real tokenizer, which would
    # be one more dependency this pure combinator has no business taking on.
    # Deterministic is the only property #call needs.
    #
    # `#requires` is the inherited {Combinator} default (nothing), NOT an
    # oversight: it is an ENFORCEMENT contract, not a comparison label. This
    # summarizes entirely client-side, so declaring `:server_compaction` would
    # be actively wrong -- on a provider that LACKS native compaction (exactly
    # when you reach for client-side Compact) :strict would raise for a
    # combinator that needs nothing, and :degrade would journal a FALSE
    # degradation.
    class Compact < Combinator
      # @param threshold [Integer] byte-length proxy above which the head
      #   gets summarized
      # @param keep_last [Integer] trailing messages that stay verbatim
      # @param summarizer [#call] pure and deterministic; (Array<Hash>) -> String
      # @param protected_patterns [ProtectedPatterns] spans that survive the
      #   summarization pass verbatim, riding ahead of the summary message --
      #   defaults to {ProtectedPatterns::NONE}, the no-op policy, so an
      #   unconfigured Compact behaves exactly as it did before this
      #   parameter existed.
      def initialize(threshold:, keep_last:, summarizer:, protected_patterns: ProtectedPatterns::NONE)
        super()
        @threshold = Integer(threshold)
        # Applied HERE, at construction, rather than left to fire from inside
        # `#call`: {Compaction::Boundary}'s own doc argues that raising inside
        # `Context#render` is worse than not compacting, and a non-positive
        # `keep_last` would do exactly that, mid-turn, on the first render. The
        # module's one rule, called rather than copied.
        @keep_last = Compaction.validate_keep_last(keep_last)
        @summarizer = summarizer
        @protected_patterns = protected_patterns
        freeze
      end

      # The exemption runs BEFORE the threshold gate. Protected messages survive
      # this pass verbatim, so they are not bytes a compaction reclaims, and
      # thresholding on the whole drop set would fire on a saving that cannot
      # happen -- while {Compaction::Head}, measuring the same span for
      # {Compaction::Need}, subtracts them. One count, `summarizable`, is what
      # keeps the two from disagreeing.
      #
      # Where the cut falls is {Compaction::Boundary}'s answer, not
      # `messages[0...-keep_last]`: the naive slice landed the retained tail on
      # whatever role parity happened to put there, which made the summary and
      # the tail two adjacent assistant messages at every even keep_last, and
      # split tool pairs.
      #
      # Both of the boundary's no-op states answer `index` 0, and BOTH must
      # return `messages` untouched here rather than fall through: an empty span
      # summarizes nothing, and a DECLINED one (the only legal cut is 0) would
      # additionally slice the tail at 0 and prepend a summary of nothing to the
      # whole history.
      #
      # PRECONDITION: this combinator must be the HEAD of the pipeline, called
      # with `Context#render`'s own projection, unmodified. It agrees with
      # {Compaction::Head} only because both compute the same pure `Boundary`
      # from the same `(messages, keep_last)`, so a combinator composed AHEAD of
      # this one that reshapes the array breaks the agreement silently rather
      # than loudly -- measured once as a Head naming 5 messages beside a Compact
      # summarizing 3, with nothing raising. `Compaction::Source` composes it
      # first today; handing ONE `Boundary` to both sites would make it
      # structural.
      def call(messages)
        span = messages[0...Compaction::Boundary.new(messages:, keep_last: @keep_last).index]
        exempt = protected_indices(span)
        summarizable = span.values_at(*(span.each_index.to_a - exempt))
        return messages if summarizable.empty? || Canonical.dump(summarizable).bytesize < @threshold

        surviving(span, exempt, summary(summarizable)) + messages.drop(span.size)
      end

      private

      # The role is `user`, fixed, never computed from the history's parity:
      # with nothing pinned the summary IS `messages[0]` and the Messages API
      # requires that to be `user`; the boundary is what then guarantees the
      # tail can follow it.
      def summary(summarizable)
        { "role" => "user", "content" => [{ "type" => "text", "text" => @summarizer.call(summarizable) }] }
      end

      # Survivors in POSITION -- select indices in order, `values_at` -- rather
      # than the `partition` that hoisted every protected message to the front
      # and put a pin from the middle of the span at index 0, ahead of the
      # summary of what preceded it.
      #
      # One summary replaces a set that pins may have left non-contiguous, so it
      # takes the position of the FIRST message it subsumes: the only placement
      # that is order-preserving for a single replacement.
      #
      # KNOWN DEFECT, characterized in `compact_spec.rb` and NOT fixed here.
      # {Compaction::Boundary} protects the CUT, but a pin punches a hole in the
      # MIDDLE of the span and nothing looks at that hole. A pinned `tool_use`
      # turn survives while the `tool_result` answering it is summarized away
      # (and vice versa), and a pinned assistant turn can end up adjacent to the
      # retained tail's assistant -- measured through the real
      # `Compaction::Source` at the shipped `keep_last: 20`. The fix is a
      # decision about what a PIN MEANS (does a pin that would strand its
      # counterpart drag it along, or get dropped with it), which is not this
      # combinator's to make. The unpinned path -- every render with no pins
      # configured -- is exhaustively valid.
      def surviving(span, exempt, summary)
        first = (span.each_index.to_a - exempt).first

        span.values_at(*exempt.select { |index| index < first }) + [summary] +
          span.values_at(*exempt.select { |index| index > first })
      end

      def protected_indices(span)
        span.each_index.select { |index| @protected_patterns.protects?(Canonical.dump(span[index])) }
      end
    end
  end
end
