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
      # against, and, since T17, the very number {Need::TokenThreshold} fires
      # ON: it reads this measurement instead of dumping the same list a second
      # time, so "what Need fired over" and "what a compaction would drop" are
      # one measurement rather than two that have to agree. (See
      # {Context::Compact}'s header for why a proxy and not a tokenizer.)
      #
      # Unconditional, so an EMPTY head measures 2, the bytes of `"[]"`, rather
      # than 0: special-casing it made this object answer its own question two
      # ways and bought nothing. Now that {Need} reads the number, that costs
      # one honest oddity -- a byte threshold of 1 or 2 fires
      # `:token_threshold` over a head holding nothing -- and it stays harmless
      # because {Compaction::Source#decide} defers on {#empty?} in the same
      # breath, so the signal is journalled and never acted on. Ask {#empty?}
      # for emptiness.
      # @return [Integer]
      attr_reader :bytesize

      # @param messages [Array<Hash>] the full rendered message list. Only READ
      #   -- the caller keeps its array, untouched and unfrozen.
      # @param keep_last [Integer] must be positive; see {#validated}
      # @param pins [Context::PinnedMessages] see {.from_timeline}
      def initialize(messages:, keep_last:, pins: Context::PinnedMessages::NONE)
        # The cut RULE, consulted rather than restated. {Context::Compact} asks
        # the same object the same question with the same arguments, and a
        # `Boundary` is a pure function of `(messages, keep_last)` -- which is
        # what makes "one answer, two consumers" hold across two objects that
        # cannot pass an instance between them (Compact receives its messages
        # per `#call`, long after it was frozen).
        @boundary = Boundary.new(messages:, keep_last: validated(keep_last))
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

      # How far the cut moved off a tool pair, and whether it found no legal cut
      # at all -- {Boundary}'s two diagnostics, answered HERE because this is
      # the object {Compaction::Source} already holds when it journals the
      # turn's decision (`source.rb:355`), so a consumer needs no new
      # collaborator.
      #
      # READ THIS BEFORE ACTING ON `#moved`. It is NOT a degradation signal, and
      # it must not be journalled as one. It was one under the rule this class
      # first shipped against, where the cut walked backward to an `assistant`
      # landing: one assistant at index 1 followed by thirty user messages
      # reported `moved` 28 and a head of ONE message where three were asked,
      # with {Need} then never crossing threshold and compaction silently
      # ceasing while every predicate read normally. The relaxed rule (T4) took
      # the cut where it was asked for and that failure mode no longer exists,
      # so `#moved` now means one thing: a tool pair was in the way, and the cut
      # moved the single position that clears it.
      #
      # This object deliberately does not ACT on either answer: "is this span
      # worth compacting" is {Need}'s and {Scheduler}'s decision, and a second
      # authority over it could only disagree (`source.rb:72-86`). It reports;
      # they decide.
      def moved = @boundary.moved

      # Distinct from {#empty?} for the reason {Boundary} states: an empty head
      # whose boundary DECLINED was refused a legal cut, while an ordinary empty
      # one was never asked for one. Both drop nothing; only one is a shape a
      # reader needs to know about.
      def declined? = @boundary.declined?

      private

      # Both degenerate values USED TO diverge from Compact silently, which is
      # why they are refused rather than measured (panel probe, 2026-07-25):
      #
      #   0 -- `messages[0...0]` and `messages.last(0)` are both empty, so above
      #     threshold Compact replaced the ENTIRE history with a summary of ZERO
      #     messages while this head reported nothing droppable. Total history
      #     loss, and the disagreement ran opposite to the one that motivated
      #     the class.
      #   negative -- this head sliced happily; `messages.last(-1)` raised
      #     `ArgumentError: negative array size` inside `Compact#call`, which
      #     means inside `Context#render`.
      #
      # T4 closed the divergence at its source: {Context::Compact} now asks
      # {Boundary}, which refuses both values by this very rule (it borrows this
      # method), so the two objects agree at the degenerate values instead of
      # one refusing what the other silently mishandles. The rule stays HERE
      # because this is where its reasons are, and because
      # {Compaction::Source#validated_keep_last} builds a throwaway Head to
      # apply it at wiring time.
      def validated(keep_last)
        integer = Integer(keep_last)
        raise ArgumentError, "keep_last must be positive, got #{integer}" unless integer.positive?

        integer
      end

      # Slices at {Boundary}'s index, which is what {Context::Compact#call} also
      # slices at -- the coupling is now one shared rule rather than two copies
      # of one expression that had to be kept reading alike. An index of 0
      # (nothing droppable, whether {Boundary#empty?} or {Boundary#declined?})
      # falls out as the empty slice, so the guard this method used to carry is
      # gone rather than restated.
      #
      # The exemption comes AFTER the slice for the same reason it does there:
      # the kept tail is sliced off the FULL list, so a pinned turn sitting
      # inside the tail must not shift the window -- it survives because it is
      # the tail, not because it is pinned.
      #
      # Positions, never a per-message `Canonical.dump`: this runs on every turn
      # including the ~1.47 ms deferring ones, and the one dump this object pays
      # for is {#bytesize}. {Context::PinnedMessages#indices_in} answers nothing
      # at all for an unpinned session.
      def droppable(messages, pins)
        candidates = messages[0...@boundary.index]
        exempt = pins.indices_in(candidates)
        exempt.empty? ? candidates : candidates.reject.with_index { |_, index| exempt.include?(index) }
      end
    end
  end
end
