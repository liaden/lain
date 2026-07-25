# frozen_string_literal: true

module Lain
  module Compaction
    # The candidate-for-drop head: the one answer to "what would
    # {Context::Compact} elide this turn, and how big is it."
    #
    # It exists because that question had two answers. {Compact#call} derives
    # its own drop set internally from its `keep_last`; {Need} byte-measures a
    # head its *caller* supplies. Nothing made the two agree, and a
    # one-message disagreement is invisible: Need raises the flag over a window
    # Compact then declines to drop, every turn, with no error anywhere. So the
    # slice and the measurement live here, and both collaborators are handed
    # the same object.
    #
    # The projection in {.from_timeline} is `Context#render`'s, deliberately
    # verbatim -- the head must be the bytes that will actually be rendered,
    # not a parallel rendering of the same turns.
    #
    # RULING 2026-07-25: this head is the whole CANDIDATE span, so a Compact it
    # is paired with must keep `protected_patterns` at
    # {Context::ProtectedPatterns::NONE}. Wire a real policy and this object
    # silently over-reports: `compact.rb:56-58` partitions the drop set and the
    # protected messages SURVIVE, so the head becomes a superset of what is
    # removed and Need fires on bytes no compaction will reclaim -- the exact
    # silent disagreement this class was written to delete. Changing that is a
    # deliberate re-ruling, not a quiet wiring change. Pinned by the "names the
    # whole candidate span" example in the spec.
    class Head
      # @param timeline [Lain::Timeline]
      # @param keep_last [Integer] the trailing messages a Compact keeps verbatim
      # @return [Head]
      def self.from_timeline(timeline:, keep_last:)
        new(messages: timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } },
            keep_last:)
      end

      include Enumerable

      # @return [Array<Hash>] deeply frozen, in timeline order
      attr_reader :messages

      # Canonical bytes of {#messages} -- the same proxy Compact thresholds
      # against and Need's TokenThreshold fires on (see {Context::Compact}'s
      # header for why a proxy and not a tokenizer). Unconditional, so an EMPTY
      # head measures 2, the bytes of `"[]"`, rather than 0: special-casing it
      # made this object answer its own question two ways, and bought nothing
      # (`Need::TokenThreshold` re-dumps the messages itself at `need.rb:51` and
      # never reads this, while `Compact` declines at `compact.rb:50` whatever
      # the number says). Ask {#empty?} for emptiness.
      # @return [Integer]
      attr_reader :bytesize

      # @param messages [Array<Hash>] the full rendered message list. Only READ
      #   -- the caller keeps its array, untouched and unfrozen.
      # @param keep_last [Integer] must be positive; see {#validated}
      def initialize(messages:, keep_last:)
        @keep_last = validated(keep_last)
        # A deeply frozen SNAPSHOT, taken by copy. Deep, because a value object
        # whose elements a caller can still mutate is one whose @bytesize goes
        # stale, and being the single answer is this object's whole job; it also
        # satisfies `Ractor.shareable?`, which CLAUDE.md requires of value
        # objects and which A6 needs when it hands one to shareable code.
        # By COPY, because freezing in place reaches back into an array the
        # caller still owns and -- since only the slice is frozen -- leaves it
        # half-frozen, with a mutable tail and nothing frozen at all when the
        # slice is empty. Two Heads over one list at different `keep_last` is a
        # thing A6 may well do. The copy is affordable: it measures as noise
        # beside the `Canonical.dump` on the next line.
        @messages = Ractor.make_shareable(droppable(messages), copy: true)
        @bytesize = Canonical.dump(@messages).bytesize
        freeze
      end

      def each(&block) = @messages.each(&block)

      def empty? = @messages.empty?

      private

      # Both degenerate values diverge from Compact silently, so they are
      # refused rather than measured (panel probe, 2026-07-25):
      #
      #   0 -- `messages[0...0]` and `messages.last(0)` are both empty, so above
      #     threshold Compact replaces the ENTIRE history with a summary of ZERO
      #     messages while this head reports nothing droppable. Total history
      #     loss, and the disagreement runs opposite to the one that motivated
      #     the class.
      #   negative -- this head slices happily; `messages.last(-1)` raises
      #     `ArgumentError: negative array size` inside `Compact#call`, which
      #     means inside `Context#render`.
      def validated(keep_last)
        integer = Integer(keep_last)
        raise ArgumentError, "keep_last must be positive, got #{integer}" unless integer.positive?

        integer
      end

      # Mirrors {Context::Compact#call}'s guard and slice line for line
      # (`compact.rb:50-52`). The guard is redundant with Ruby's range
      # clamping, and kept anyway: it is the coupling being pinned, and it
      # should read as the same decision, not as a slice that happens to
      # coincide.
      def droppable(messages)
        messages.size <= @keep_last ? [] : messages[0...-@keep_last]
      end
    end
  end
end
