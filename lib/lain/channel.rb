# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  # A thread-safe, bounded queue of structured events (see {Lain::Telemetry}).
  #
  # Deliberately NOT a byte buffer. `parallel_safe?` tools run concurrently and
  # subagents run async; a shared byte buffer would let two writers interleave
  # mid-line and destroy provenance -- you could no longer tell which
  # `tool_use_id` produced which line. Bytes only ever live *inside* an event
  # (e.g. {Lain::Telemetry::ToolOutput}), never smeared across the medium.
  #
  # Overflow BLOCKS the producer: a full `SizedQueue` throttles a runaway
  # producer (a `bash` command spewing megabytes) to the rate its consumer can
  # drain -- bounded memory, no data loss, at the cost of a producer that stalls.
  #
  # That policy is right for a consumer that must not miss an event, and wrong
  # for the frontend, which renders and is not the record -- there a blocked
  # producer is a deadlock the moment the render thread raises. Hence
  # {Lain::Channel::DropOldest}, which drops the oldest event and surfaces a
  # {Lain::Telemetry::Dropped} count. Both satisfy the same
  # `push`/`pop`/`drain`/`close`/`Null` duck, so the WIRING chooses the policy,
  # not the producer. Durability is not on this channel at all: {Lain::Journal}
  # writes synchronously to its own fd under a mutex.
  #
  # Blocking risks deadlock only if *nobody* drains, and two things guard it: a
  # consumer thread whose sole job is to drain and render, and {#close} waking
  # every blocked producer with a `ClosedQueueError`.
  class Channel
    # The two-mode destructive `drain`, shared by every channel policy. The
    # dispatch loop is pure duck (`pop` plus a private `drain_buffered`), so
    # each includer keeps only the half where the policies genuinely differ.
    # A plain module, not an `ActiveSupport::Concern`, per the {Lain::Freezable}
    # precedent: no `ClassMethods`, no dependency ordering, just one method.
    module Draining
      # Without a block: non-blocking. Every event currently buffered, in FIFO
      # order, `[]` if none. This is the frontend's per-render-tick drain.
      #
      # With a block: blocking, until the channel is closed AND drained.
      #
      # Named `drain` rather than `each`/`Enumerable` deliberately: `each`
      # promises a *repeatable* walk over a receiver that owns its elements, and
      # this empties the channel as it goes and can only ever run once.
      #
      # @yieldparam event [Object]
      # @return [Array<Object>] every currently-buffered event, when called without a block
      # @return [self] when called with a block
      def drain
        return drain_buffered unless block_given?

        event = pop
        while event
          yield event
          event = pop
        end
        self
      end
    end

    include Draining

    # Default number of in-flight events before {#push} applies backpressure.
    # Large enough to absorb bursts, small enough that a runaway producer is
    # throttled long before it exhausts memory.
    DEFAULT_CAPACITY = 1024

    # Named rather than declared inline because {DropOldest} constructs against
    # this same contract deliberately -- a channel's capacity means one thing
    # whatever the overflow policy, and the shared name is what would make a
    # divergence a visible edit rather than a silent drift.
    #
    # Channel is stateful, not a frozen value object, so there is no
    # {Lain::Freezable} companion here -- just the check.
    class Capacity < Declarative::Carrier
      attribute :capacity
      validates :capacity, numericality: { only_integer: true, greater_than: 0,
                                           message: "must be a positive Integer, got %<value>s" }
    end

    # @param capacity [Integer] maximum number of buffered events (>= 1)
    def initialize(capacity: DEFAULT_CAPACITY)
      Capacity.check!(capacity:)

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

    # Close the channel. Blocked and future producers see a `ClosedQueueError`;
    # consumers drain the remaining events and then receive `nil`. Idempotent.
    #
    # @return [self]
    def close
      @queue.close
      self
    end

    delegate :closed?, :size, to: :queue
    alias length size

    # @return [Integer] the configured capacity (backpressure threshold)
    def capacity
      @queue.max
    end

    private

    # `delegate`'s target must be a message the receiver answers, not a bare
    # ivar -- a private reader is the whole adapter.
    attr_reader :queue

    def drain_buffered
      drained = []
      loop { drained << @queue.pop(true) }
    rescue ThreadError
      # Raised by `pop(true)` when the queue is empty (whether or not it is
      # closed): the queue is drained, so we are done.
      drained
    end

    # The default channel for a {Tool::Invocation} carrying no live output
    # destination, so a tool never needs an `if channel` guard before pushing --
    # {Sink::Null}'s role one layer up.
    class Null
      # @return [self]
      def push(_event) = self
      alias << push

      # One shared frozen Null: it has no state, so every `journal:`/`channel:`
      # default reuses this eager constant rather than allocating a fresh no-op
      # per object (or racing a lazy memo across threads).
      INSTANCE = new.freeze

      # @return [Null] the shared instance
      def self.instance = INSTANCE
    end
  end
end

require_relative "channel/drop_oldest"
