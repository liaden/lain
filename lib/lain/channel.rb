# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  # A thread-safe, bounded queue of structured events (see {Lain::Telemetry}).
  #
  # This is deliberately NOT a byte buffer. `parallel_safe?` tools run
  # concurrently and subagents run async; a shared byte buffer would let two
  # writers interleave mid-line and destroy provenance -- you could no longer
  # tell which `tool_use_id` produced which line. A queue of whole, already
  # attributed events preserves that provenance by construction. Bytes only
  # ever live *inside* an event (e.g. {Lain::Telemetry::ToolOutput}), never smeared
  # across the shared medium.
  #
  # == Overflow policy: BLOCK the producer (bounded backpressure)
  #
  # Backed by a `SizedQueue`, so when the queue is full {#push} blocks the
  # calling (producer) thread until a consumer drains space. Backpressure
  # throttles a runaway producer (a `bash` command spewing megabytes) to the rate
  # its consumer can drain -- bounded memory, no data loss, at the cost of a
  # producer that can stall.
  #
  # == Which consumer wants this, and which does not
  #
  # An earlier design justified blocking by "the channel feeds the Journal, and
  # the Journal is the record, so it must not drop." That conflated two consumers
  # with opposite needs. The record's durability now lives in {Lain::Journal},
  # which writes synchronously to its own fd under a mutex; the Journal does not
  # ride this channel at all. What remains on the channel is the FRONTEND, a
  # consumer that may freely drop, because it renders -- it is not the record.
  #
  # So the two policies are split (see the plan, "Two consumers, two policies"):
  #
  # - {Lain::Channel} (this class) keeps blocking backpressure, for a consumer
  #   that genuinely must not miss an event and can afford to throttle its
  #   producer. It is still the right default where a stall is acceptable.
  # - {Lain::Channel::DropOldest} drops the oldest event on overflow and surfaces
  #   a {Lain::Telemetry::Dropped} count, for the frontend, where a blocked producer
  #   would be a deadlock if the render thread ever raised.
  #
  # Both satisfy the same `push`/`pop`/`drain`/`close`/`Null` duck, so the wiring
  # -- not the producer -- chooses the policy.
  #
  # The real risk of blocking is deadlock if *nobody* drains. Two things guard
  # against it: (1) a consumer thread whose sole job is to drain and render, so
  # under normal operation a consumer always exists; and (2) {#close} wakes every
  # blocked producer with a `ClosedQueueError`, so teardown can never wedge a
  # producer forever.
  class Channel
    # The two-mode destructive `drain`, shared by every channel policy: the
    # dispatch loop is pure duck (`pop` + a private `drain_buffered`), so it is
    # identical whatever the backing structure, while each includer keeps its
    # own `drain_buffered` -- that is where the policies genuinely differ
    # (SizedQueue's non-blocking pop here; DropOldest's marker-led surface).
    # A plain module, not an `ActiveSupport::Concern`, per the {Lain::Freezable}
    # precedent: no `ClassMethods`, no dependency ordering, just one method.
    module Draining
      # Destructive removal, in one of two modes depending on whether a block
      # is given -- both are "drain" because both consume the channel, just on
      # different schedules.
      #
      # Without a block: non-blocking. Remove and return every event currently
      # buffered, in FIFO order, without waiting for more. Returns `[]` if
      # nothing is queued. This is the frontend's per-render-tick drain: pull
      # whatever has accumulated, render it, come back later.
      #
      # With a block: blocking. Repeatedly {#pop} and yield each event as it
      # arrives, until the channel is closed AND drained (`pop` returning `nil`)
      # -- the exit contract a render loop's `while (event = channel.pop) ...`
      # already relied on, expressed as one call instead of a hand-rolled loop
      # at every call site. Named `drain` rather than `each`/`Enumerable`
      # deliberately: `each` promises a *repeatable* walk over a receiver that
      # owns its elements, and this walk empties the channel as it goes and can
      # only ever run once -- calling it `each` would be a lie about what it does.
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

    # Throwaway carrier for validate-then-freeze construction (Ruling 2, T6).
    # Channel is a lone guarded class in its own namespace, so it nests its own
    # {Lain::Guard} subclass directly rather than joining a sibling `Guards`
    # module (that form is for namespaces with several guarded classes, e.g.
    # {Lain::Telemetry::Guards}). Channel is stateful, not a frozen value object, so
    # there is no {Lain::Freezable} companion here -- just the carrier check.
    # {DropOldest} shares this Guard deliberately (same capacity contract); it
    # splits into its own the day their validations diverge.
    class Guard < Lain::Guard
      attribute :capacity
      validates :capacity, numericality: { only_integer: true, greater_than: 0,
                                           message: "must be a positive Integer, got %<value>s" }
    end

    # @param capacity [Integer] maximum number of buffered events (>= 1)
    def initialize(capacity: DEFAULT_CAPACITY)
      Guard.check!(capacity:)

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

    # A channel that discards everything pushed to it, satisfying the same
    # `#push`-shaped duck as a real Channel. The default channel for a
    # {Tool::Invocation} that carries no live output destination, so a tool
    # never needs an `if channel` guard before pushing -- it mirrors
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
