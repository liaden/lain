# frozen_string_literal: true

module Lain
  module Compaction
    # The candidate-for-drop head: the one answer to "what would
    # {Context::Compact} elide this turn, and how big is it."
    #
    # It exists because that question had two answers. {Compact#call} derives
    # its own drop set internally from its `keep_last`; {Need} byte-measures a
    # head its *caller* supplies. Nothing made the two agree, and a one-message
    # disagreement is invisible: Need raises the flag over a window Compact
    # then declines to drop, every turn, with no error anywhere. So the slice
    # and the measurement live here, and both collaborators are handed the same
    # object.
    #
    # The projection in {.from_timeline} is `Context#render`'s, deliberately
    # verbatim -- the head must be the bytes that will actually be rendered,
    # not a parallel rendering of the same turns.
    #
    # This head is the candidate span MINUS whatever the pin policy exempts,
    # and the Compact it is paired with must be handed the SAME `pins` value.
    # `compact.rb` partitions the drop set and the pinned messages SURVIVE, so
    # a head that named them would be a superset of what is removed and Need
    # would fire on bytes no compaction reclaims. One object, one policy, both
    # consumers.
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
      # against, and the very number {Need::TokenThreshold} fires ON, so "what
      # Need fired over" and "what a compaction would drop" are one measurement
      # rather than two that have to agree. (See {Context::Compact}'s header
      # for why a proxy and not a tokenizer.)
      #
      # Unconditional, so an EMPTY head measures 2, the bytes of `"[]"`, rather
      # than 0: special-casing it made this object answer its own question two
      # ways. The one oddity that costs -- a byte threshold of 1 or 2 firing
      # `:token_threshold` over a head holding nothing -- is harmless because
      # {Compaction::Source#decide} defers on {#empty?} in the same breath.
      # @return [Integer]
      attr_reader :bytesize

      # @param messages [Array<Hash>] the full rendered message list. Only READ
      #   -- the caller keeps its array, untouched and unfrozen.
      # @param keep_last [Integer] must be positive. Checked by the {Boundary}
      #   built below, not here: a second call would be
      #   unreachable-by-construction, which is worse than absent, since a spec
      #   aimed at it passes whether or not it is there.
      # @param pins [Context::PinnedMessages] see {.from_timeline}
      def initialize(messages:, keep_last:, pins: Context::PinnedMessages::NONE)
        # A `Boundary` is a pure function of `(messages, keep_last)`, which is
        # what makes "one answer, two consumers" hold across two objects that
        # cannot pass an instance between them: {Context::Compact} receives its
        # messages per `#call`, long after it was frozen.
        @boundary = Boundary.new(messages:, keep_last:)
        # DEEP, because a value object whose elements a caller can still mutate
        # is one whose bytesize goes stale. By COPY, because freezing in place
        # reaches back into an array the caller still owns and -- since only
        # the slice is frozen -- leaves it half-frozen, with a mutable tail and
        # nothing frozen at all when the slice is empty; two Heads over one
        # list at different `keep_last` is a thing a caller may well do. The
        # copy measures as noise beside the `Canonical.dump` below.
        @messages = Ractor.make_shareable(droppable(messages, pins), copy: true)
        @bytesize = Canonical.dump(@messages).bytesize
        freeze
      end

      def each(&block) = @messages.each(&block)

      def empty? = @messages.empty?

      # {Boundary}'s diagnostic, answered HERE because this is the object
      # {Compaction::Source} already holds when it journals the turn's decision.
      #
      # NOT a degradation signal, and it must not be journalled as one. It was
      # one under the rule this class first shipped against, where the cut
      # walked backward to an `assistant` landing: one assistant at index 1
      # followed by thirty user messages reported `moved` 28 and a head of ONE
      # message where three were asked, with {Need} then never crossing
      # threshold and compaction silently ceasing while every predicate read
      # normally. Under the relaxed rule it means one thing: a tool pair was in
      # the way, and the cut moved the single position that clears it.
      #
      # This object deliberately does not ACT on it -- "is this span worth
      # compacting" is {Need}'s and {Scheduler}'s decision, and a second
      # authority over it could only disagree.
      def moved = @boundary.moved

      # Distinct from {#empty?}: an empty head whose boundary DECLINED was
      # refused a legal cut, while an ordinary empty one was never asked for
      # one. Both drop nothing; only one is a shape a reader needs to know about.
      def declined? = @boundary.declined?

      private

      # Slices at {Boundary}'s index, which is where {Context::Compact#call}
      # also slices -- one shared rule rather than two copies of an expression
      # that had to be kept reading alike. An index of 0 falls out as the empty
      # slice, so no guard is needed for it.
      #
      # The exemption comes AFTER the slice for the same reason it does there:
      # the kept tail is sliced off the FULL list, so a pinned turn inside the
      # tail must not shift the window -- it survives because it is the tail,
      # not because it is pinned.
      #
      # Positions, never a per-message `Canonical.dump`: this runs on every
      # turn including the ~1.47 ms deferring ones, and the one dump this
      # object pays for is {#bytesize}.
      def droppable(messages, pins)
        candidates = messages[0...@boundary.index]
        exempt = pins.indices_in(candidates)
        exempt.empty? ? candidates : candidates.reject.with_index { |_, index| exempt.include?(index) }
      end
    end
  end
end
