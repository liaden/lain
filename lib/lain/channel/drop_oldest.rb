# frozen_string_literal: true

module Lain
  class Channel
    # A bounded event channel that DROPS THE OLDEST event when it overflows,
    # rather than blocking the producer the way {Lain::Channel} does. It satisfies
    # the same duck -- `push`/`pop`/`drain`/`close`/`closed?`/`size`/`capacity`,
    # plus {Channel::Null} for the no-op case -- so it is a drop-in wherever a
    # Channel feeds the frontend.
    #
    # == Two consumers, two policies
    #
    # Losslessness used to live in {Lain::Channel}'s backpressure, justified by
    # "the channel feeds the Journal." It no longer does. The {Lain::Journal}
    # writes synchronously to its own fd under a mutex, so durability lives THERE.
    # That frees the consumer that never needed losslessness -- the render loop --
    # from the strictest policy. Conflating the two forced blocking `push` onto
    # the frontend path, where a drain thread that raised would deadlock every
    # producer. Splitting them is the resolution: this channel is the frontend's,
    # and the frontend may freely drop.
    #
    # Dropping is never silent. Each overflow bumps a counter; the next {#drain}
    # or {#pop} surfaces a single {Lain::Event::Dropped} marker carrying the count
    # lost since the last one, ahead of the surviving events (which are newer than
    # everything dropped). A consumer thus always knows the record it is rendering
    # is incomplete, and by how much -- the honest analog of backpressure for a
    # consumer whose job is to keep up, not to be the record.
    #
    # Built on a plain Array under a Mutex with a ConditionVariable rather than a
    # `SizedQueue`, because drop-oldest is exactly the compound "evict then enqueue"
    # that a SizedQueue cannot express: its `push` blocks and its `pop(true)` only
    # removes. One lock covers the whole compound so two producers cannot race the
    # eviction.
    #
    # Why not a library instead of hand-rolling this? The design plan's
    # Concurrency section already ruled `concurrent-ruby-edge` out entirely --
    # its `Channel`/`Actor`/`Cancellation` sit behind an explicitly unstable API,
    # and M1 has no chosen concurrency model to build a dependency against yet.
    # Stable `concurrent-ruby` has no evict-oldest queue either; its bounded
    # queues share `SizedQueue`'s blocking-push limitation. So there was no
    # off-the-shelf structure that already expressed "evict, then enqueue,
    # atomically" -- the Mutex/ConditionVariable is the smallest thing that
    # does, not a shortcut around a library. Revisit once M5 picks fibers via
    # `async` (the plan's likely answer): `Async::LimitedQueue` is a
    # scheduler-aware bounded queue and could replace this Thread-based
    # implementation outright, at the same point the rest of the concurrency
    # model gets chosen with the bench in hand.
    class DropOldest
      # The same two-mode `drain` as {Lain::Channel} -- see {Channel::Draining}
      # for the contract and the drain-not-each WHY. The block form yields any
      # pending {Lain::Event::Dropped} marker first, because it rides {#pop}.
      include Draining

      # @param capacity [Integer] maximum buffered events before the oldest is
      #   evicted (>= 1)
      def initialize(capacity: Channel::DEFAULT_CAPACITY)
        Channel::Guard.check!(capacity:)

        @capacity = capacity
        @buffer = []
        @dropped = 0
        @closed = false
        @mutex = Mutex.new
        @available = ConditionVariable.new
      end

      # Enqueue an event without ever blocking. When the buffer is full the oldest
      # event is evicted and the drop counter bumped, so a runaway producer costs
      # bounded memory and a visible dropped-count, never a stalled thread.
      #
      # @param event [Object]
      # @return [self]
      # @raise [ClosedQueueError] if the channel has been closed
      def push(event)
        @mutex.synchronize do
          raise ClosedQueueError if @closed

          if @buffer.size >= @capacity
            @buffer.shift
            @dropped += 1
          end
          @buffer.push(event)
          @available.signal
        end
        self
      end
      alias << push

      # Remove and return the next event, blocking until one is available. A
      # pending drop surfaces first as a {Lain::Event::Dropped} marker; once the
      # channel is closed and drained, returns `nil`.
      #
      # @return [Object, nil]
      def pop
        @mutex.synchronize do
          @available.wait(@mutex) while @buffer.empty? && @dropped.zero? && !@closed
          return dropped_marker if @dropped.positive?

          @buffer.shift
        end
      end

      # Close the channel. Future producers raise `ClosedQueueError`; blocked
      # consumers wake and drain the remainder, then receive `nil`. Idempotent.
      #
      # @return [self]
      def close
        @mutex.synchronize do
          @closed = true
          @available.broadcast
        end
        self
      end

      # @return [Boolean]
      def closed?
        @mutex.synchronize { @closed }
      end

      # @return [Integer] events currently buffered (excludes the pending marker)
      def size
        @mutex.synchronize { @buffer.size }
      end
      alias length size

      # @return [Integer] the configured capacity
      attr_reader :capacity

      private

      # The non-blocking mode's mechanics: every buffered event in FIFO order,
      # led by a single {Lain::Event::Dropped} marker if any were dropped since
      # the last surface; `[]` when nothing is queued and nothing was dropped.
      def drain_buffered
        @mutex.synchronize do
          drained = @dropped.positive? ? [dropped_marker] : []
          drained.concat(@buffer)
          @buffer = []
          drained
        end
      end

      # Consume and reset the drop counter into a marker. Caller holds the lock.
      def dropped_marker
        count = @dropped
        @dropped = 0
        Event::Dropped.new(count:)
      end
    end
  end
end
