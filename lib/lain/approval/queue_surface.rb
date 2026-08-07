# frozen_string_literal: true

require "async"

require_relative "queue_surface/pruning"

module Lain
  module Approval
    # The template every meta-agent surface over {Approval::Queue}'s PARKED set
    # shares: poll the parked list, take the pendings that are this surface's
    # question, ask about each exactly once, and route the answer. Where
    # {Frontend::ApprovalPolicy} draws pendings off the ARRIVAL queue and asks a
    # person, a QueueSurface observes ({Queue#each}) and never consumes --
    # draining `dequeue` here would STEAL pendings the human surface then never
    # sees (`queue.rb`'s two-surface discipline). {Queue::Pending#decide}'s
    # first-answer-wins is what makes the observe-and-answer race safe.
    #
    # == Why a template, and what the subclass owes
    #
    # {AutoSurface} and {SecretSurface} had ~45 lines of identical watch, sweep,
    # seen-set and polling code around two hand-written filters, with one
    # reaching sideways into the other's `Pruning` for a default. That is not a
    # tidiness complaint: the two filters must PARTITION the queue -- disjoint,
    # so no pending gets two LLM opinions, and total, so none is silently
    # dropped -- and a partition maintained by two separately-authored
    # predicates in two files is a partition that survives until somebody
    # narrows one of them, with a green suite either way.
    #
    # So the shared half lives here and a subclass answers exactly one question
    # about a pending, {#judges?}, over its {Queue::Outstanding} alone. The two
    # implementations are then literally `outstanding.any?` and
    # `outstanding.none?` -- complementary by inspection, over a value object
    # that owns both predicates -- and `queue_surface_spec.rb` asserts the
    # exclusive-or over both cases rather than each half pinning only itself.
    #
    # A subclass supplies {#judges?}, {#settle} and a `SURFACE` name.
    class QueueSurface
      # Between polls of the parked set. A surface is a sibling fiber, so the
      # sleep is a scheduler yield, not a wall-clock stall.
      DEFAULT_POLL_INTERVAL = 0.05

      # The journal record type a sweep that raised lands as. Not a {Telemetry}
      # record because there is no shape for "a surface fell over" yet and
      # inventing one is a different card; the Hash wears the same
      # self-describing form {Approval::Queue#degrade} writes, which
      # {Journal.records} reads by `type`.
      FAULT_TYPE = "approval_surface_fault"

      # @param poll_interval [Numeric] seconds between sweeps of the parked set.
      # @param pruning [#call] releases `@adjudicated` entries for pendings that
      #   have since settled ({Pruning}); injected so the seen-set's own
      #   eviction policy carries its own spec.
      # @param journal [#<<] where a sweep that raised is recorded; the shared
      #   Null channel by default, so no caller guards `if journal`.
      def initialize(poll_interval: DEFAULT_POLL_INTERVAL, pruning: Pruning.new, journal: Channel::Null::INSTANCE)
        @poll_interval = poll_interval
        @pruning = pruning
        @journal = journal
        # Identity-keyed (Pending is a plain object, so `eql?`/`hash` are
        # identity): a pending gets ONE adjudication, so a declined answer is
        # not re-asked on every poll until the clock denies it.
        @adjudicated = {}.compare_by_identity
        # Faults already journaled, so a permanently-broken pending cannot turn
        # a 50ms poll into a Journal flood. Keyed by the failure's own text,
        # because that is what a reader would otherwise see repeated.
        @reported = {}
      end

      # The surface loop: sweep the parked set, then yield until the next poll.
      # Runs in its own fiber beside the human surface; stops with its task.
      #
      # The sweep is guarded because a raise here would kill the FIBER, and a
      # dead surface fiber is silent: every later pending simply never gets
      # asked about, for the rest of the session, with the queue still looking
      # healthy. Fail-closed still holds -- the clock denies what nobody
      # answered -- so the cost of a fault is that an OPT-IN surface quietly
      # stops being opt-in, which is precisely the failure that must not be
      # quiet. `Async::Stop` descends from Exception, so stopping the task still
      # unwinds this loop.
      #
      # @param queue [Approval::Queue]
      # @return [void]
      def watch(queue)
        loop do
          swept(queue)
          Async::Task.current.sleep(@poll_interval)
        end
      end

      # One pass over the parked set: adjudicate each pending that is this
      # surface's question and that it has not already seen. The snapshot is
      # collected with NO IO yield (the filter only reads flags and a frozen
      # value), so the enumeration cannot mutate under a concurrent park or
      # settle; the ASK -- which yields -- happens afterwards, over the
      # materialized array. Pruned first, every sweep, for {Pruning}'s own
      # seen-set-growth reason.
      #
      # @param queue [Approval::Queue]
      # @return [void]
      def sweep(queue)
        @pruning.call(@adjudicated)
        queue.select { |pending| mine?(pending) }.each { |pending| adjudicate(pending) }
      end

      # Whether this surface is the one to answer `pending` right now. Public
      # because the PARTITION between two surfaces is a property of these
      # answers taken together, and a property nothing can assert is a property
      # nothing maintains.
      #
      # @param pending [Approval::Queue::Pending]
      # @return [Boolean]
      def mine?(pending)
        judges?(pending.outstanding) && !pending.decided? && !@adjudicated.key?(pending)
      end

      # Whether pendings releasing THIS much is the kind of question this
      # surface exists to answer -- the one discriminator a subclass owns, and
      # deliberately a function of the {Queue::Outstanding} alone, so two
      # subclasses' answers can be compared directly.
      #
      # @param outstanding [Approval::Queue::Outstanding]
      # @return [Boolean]
      def judges?(outstanding)
        raise NotImplementedError, "#{self.class} must answer judges?(#{outstanding.class})"
      end

      private

      # Route one answer onto the pending. Only a confident verdict should act;
      # abstaining must always be available, and must always be the no-op that
      # leaves the pending to the human or the clock.
      #
      # @param pending [Approval::Queue::Pending]
      # @param answer [Object] whatever {#answer_for} produced
      # @return [void]
      def settle(pending, answer)
        raise NotImplementedError, "#{self.class} must settle(#{pending.class}, #{answer.class})"
      end

      # The subclass's own ask. It owns its failure handling, because what a
      # failed ask MEANS differs per surface; anything that escapes lands in
      # {#swept}'s guard.
      def answer_for(pending)
        raise NotImplementedError, "#{self.class} must answer_for(#{pending.class})"
      end

      def adjudicate(pending)
        @adjudicated[pending] = true
        # A sibling surface may have decided it after the parked snapshot was
        # collected: skip the wasted ask -- first-answer-wins already stands.
        return if pending.decided?

        settle(pending, answer_for(pending))
      end

      def swept(queue)
        sweep(queue)
      rescue StandardError => e
        journal_fault(e)
      end

      # Once per distinct failure. Swallowing a failed write is
      # {Approval::Queue#degrade}'s answer to the same problem: evidence about a
      # decision must never be able to cost the decision, and here it would kill
      # the very fiber this guard exists to keep alive.
      def journal_fault(error)
        text = "#{error.class}: #{error.message}"
        return if @reported.key?(text)

        @reported[text] = true
        @journal << { "type" => FAULT_TYPE, "surface" => self.class::SURFACE, "error" => text }
      rescue StandardError
        nil
      end
    end
  end
end
