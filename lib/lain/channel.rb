# frozen_string_literal: true

module Lain
  # A thread-safe, bounded queue of structured events (see {Lain::Event}).
  #
  # This is deliberately NOT a byte buffer. `parallel_safe?` tools run
  # concurrently and subagents run async; a shared byte buffer would let two
  # writers interleave mid-line and destroy provenance -- you could no longer
  # tell which `tool_use_id` produced which line. A queue of whole, already
  # attributed events preserves that provenance by construction. Bytes only
  # ever live *inside* an event (e.g. {Lain::Event::ToolOutput}), never smeared
  # across the shared medium.
  #
  # == Overflow policy: BLOCK the producer (bounded backpressure)
  #
  # Backed by a `SizedQueue`, so when the queue is full {#push} blocks the
  # calling (producer) thread until a consumer drains space. We block rather
  # than drop-oldest because the channel feeds the Journal, and the Journal is
  # the experiment's record: silently dropping a `bash` tool's output would
  # corrupt provenance exactly the way a shared byte buffer would. Backpressure
  # instead throttles a runaway producer (a `bash` command spewing megabytes)
  # to the rate the frontend can drain -- correct-by-construction, no data loss.
  #
  # The real risk of blocking is deadlock if *nobody* drains. Two things guard
  # against it: (1) the frontend owns a thread whose sole job is to drain and
  # render, so under normal operation a consumer always exists; and (2) {#close}
  # wakes every blocked producer with a `ClosedQueueError`, so teardown can
  # never wedge a producer forever. The dropping alternative trades a loud,
  # debuggable stall for silent corruption of the record -- the wrong trade for
  # a bench whose entire value is a trustworthy log.
  class Channel
    # Default number of in-flight events before {#push} applies backpressure.
    # Large enough to absorb bursts, small enough that a runaway producer is
    # throttled long before it exhausts memory.
    DEFAULT_CAPACITY = 1024

    # @param capacity [Integer] maximum number of buffered events (>= 1)
    def initialize(capacity: DEFAULT_CAPACITY)
      unless capacity.is_a?(Integer) && capacity.positive?
        raise ArgumentError, "capacity must be a positive Integer, got #{capacity.inspect}"
      end

      @queue = SizedQueue.new(capacity)
    end

    # Enqueue an event, blocking the caller if the channel is full.
    #
    # @param event [Object] a structured event
    # @return [self]
    # @raise [ClosedQueueError] if the channel has been closed
    def push(event)
      @queue.push(event)
      self
    end
    alias << push

    # Remove and return the next event, blocking until one is available.
    #
    # @return [Object, nil] the next event, or `nil` once the channel is closed
    #   and drained
    def pop
      @queue.pop
    end

    # Non-blocking. Remove and return every event currently buffered, in FIFO
    # order, without waiting for more. Returns `[]` if nothing is queued.
    #
    # This is the frontend's drain step: pull whatever has accumulated, render
    # it, come back later. It never blocks, so it is safe to call on a render
    # tick.
    #
    # @return [Array<Object>]
    def drain
      drained = []
      loop { drained << @queue.pop(true) }
    rescue ThreadError
      # Raised by `pop(true)` when the queue is empty (whether or not it is
      # closed): the queue is drained, so we are done.
      drained
    end

    # Close the channel. Blocked and future producers see a `ClosedQueueError`;
    # consumers drain the remaining events and then receive `nil`. Idempotent.
    #
    # @return [self]
    def close
      @queue.close
      self
    end

    # @return [Boolean] whether {#close} has been called
    def closed?
      @queue.closed?
    end

    # @return [Integer] events currently buffered
    def size
      @queue.size
    end
    alias length size

    # @return [Integer] the configured capacity (backpressure threshold)
    def capacity
      @queue.max
    end

    # A channel that discards everything pushed to it, satisfying the same
    # `#push`-shaped duck as a real Channel. The default channel for a
    # {Tool::Invocation} that carries no live output destination, so a tool
    # never needs an `if channel` guard before pushing -- it mirrors
    # {Sink::Null}'s role one layer up.
    class Null
      # @return [self]
      def push(_event)
        self
      end
      alias << push
    end
  end
end
