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
    # RULING 2026-07-25, RE-RULED the same day (B2): this head is the candidate
    # span MINUS whatever the protection policy exempts, and the Compact it is
    # paired with must be handed the SAME `pins` value. The first ruling made it
    # protection-agnostic and forbade a real policy, because `compact.rb`
    # partitions the drop set and the protected messages SURVIVE -- so a head
    # that named them was a superset of what is removed, and Need fired on bytes
    # no compaction reclaims. Wiring session pins made that over-report real, so
    # the exemption moved INTO the head rather than the policy staying unwired.
    # One object, one policy, both consumers: the disagreement this class exists
    # to delete cannot reappear as long as the same `pins` goes to both.
    class Head
      # @param timeline [Lain::Timeline]
      # @param keep_last [Integer] the trailing messages a Compact keeps verbatim
      # @param pins [Context::PinnedMessages] the exemption policy, which must
      #   be the very object the paired {Context::Compact} takes as
      #   `protected_patterns:`
      # @return [Head]
      def self.from_timeline(timeline:, keep_last:, pins: Context::PinnedMessages::NONE)
        new(messages: timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } },
            keep_last:, pins:)
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
      # @param pins [Context::PinnedMessages] see {.from_timeline}
      def initialize(messages:, keep_last:, pins: Context::PinnedMessages::NONE)
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
        @messages = Ractor.make_shareable(droppable(messages, pins), copy: true)
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

      # Mirrors {Context::Compact#call}'s guard, slice and partition line for
      # line (`compact.rb:50-57`). The guard is redundant with Ruby's range
      # clamping, and kept anyway: it is the coupling being pinned, and it
      # should read as the same decision, not as a slice that happens to
      # coincide.
      #
      # The exemption comes AFTER the slice for the same reason it does there:
      # the kept tail is `keep_last` off the FULL list, so a pinned turn sitting
      # inside the tail must not shift the window -- it survives because it is
      # the tail, not because it is pinned.
      #
      # Positions, never a per-message `Canonical.dump`: this runs on every turn
      # including the ~1.47 ms deferring ones, and the one dump this object pays
      # for is {#bytesize}. {Context::PinnedMessages#indices_in} answers nothing
      # at all for an unpinned session.
      def droppable(messages, pins)
        return [] if messages.size <= @keep_last

        candidates = messages[0...-@keep_last]
        exempt = pins.indices_in(candidates)
        exempt.empty? ? candidates : candidates.reject.with_index { |_, index| exempt.include?(index) }
      end
    end
  end
end
