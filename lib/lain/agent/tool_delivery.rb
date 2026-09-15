# frozen_string_literal: true

require "async"

module Lain
  class Agent
    # Where ONE tool-calling turn's results land on the Timeline.
    #
    # Third in the split this class already makes: the {Agent} decides *when*
    # tools run, {ToolRunner} decides *how* they run, and this decides how what
    # they produced becomes a commit -- settled, or torn by an interrupt that
    # arrived mid-dispatch. Its own object because the torn case is not one more
    # line in {Agent#perform_tools}: it is a rescue arm, an uninterruptible
    # commit, a journal record and a re-raise, over answers that have to outlive
    # the unwind.
    #
    # The window that strands a `tool_use` is exactly the gap this object spans
    # -- the assistant turn is committed ({Agent#commit_and_account}) and its
    # results are not -- and before this, an interrupt in that gap unwound
    # {ToolRunner#run}'s accumulator while it was still a LOCAL, losing every
    # block including the ones tools had already earned.
    # {CLI::Resume::Cancellation} repairs the same tear at LOAD, which is
    # trigger-agnostic and covers the SIGKILL, OOM and reactor-teardown cases
    # nothing here can see; this is the improvement on top, telling the
    # *running* model in the turn where it happened. The two commit the same
    # block, from the same mint ({Tool::Cancellation}), deliberately.
    class ToolDelivery
      # `journal:` defaults to the Null channel for {Accounting}'s reason: no
      # caller writes `if journal`.
      # `snapshots:` is a {SnapshotSlot}, read at every settle rather than
      # captured here, so a posture flip between two turns reaches the next
      # snapshot.
      def initialize(runner:, snapshots:, journal: Channel::Null.instance)
        @runner = runner
        @snapshots = snapshots
        @journal = journal
      end

      # `rescue`/`else` rather than a `begin` around the commit: an `else` body
      # is NOT covered by the rescue clauses, so a stop landing on the settled
      # commit or on the snapshot write cannot re-enter the cancellation arm and
      # answer, a second time, the calls the first commit already answered.
      #
      # The Timeline is YIELDED rather than returned because the torn path both
      # commits and re-raises, and a return value would be discarded by the very
      # interrupt the commit exists to survive.
      #
      # The slot is primed before the tools run: a shadow scope's before-tree
      # has to predate the first write the turn's undo will put back. The
      # session's pre-images open at the same moment, for the write-set
      # scope's undo, which has no tree to read that from.
      #
      # @param response [Lain::Response] the assistant turn carrying the calls
      # @param timeline [Lain::Timeline] the timeline as of the assistant commit
      # @param session [Lain::Session] the tools' context, and the snapshot's paths
      # @yieldparam committed [Lain::Timeline] the commit this delivery produced
      # @raise [Async::Stop] re-raised after the cancellation commit, so an
      #   interrupt still ends the run it was asked to end
      # @raise [StandardError] whatever refused the settled commit, re-raised
      #   after the errored commit answers the calls
      def perform(response, timeline:, session:, &commit)
        answers = ToolRunner::Answers.for(response)
        @snapshots.prime
        session.open_pre_images
        delivery = @runner.delivery(response, context: session, answers:)
      rescue Async::Stop => e
        cancel(answers, timeline, &commit)
        raise e
      else
        settle(delivery, timeline, session, &commit)
      end

      private

      # The snapshot rides here, not with the assistant commit: that commit
      # happens BEFORE the tools run, so this is the earliest point where both
      # halves of the snapshot exist -- the written bytes on disk and the turn
      # digest the event names as its cause.
      def settle(delivery, timeline, session, &commit)
        committed = settled(delivery, timeline, &commit)
        yield committed
        @snapshots.write(timeline: committed, paths: session.writes, pre_images: session.pre_images)
        session.settle_pre_images
      end

      # Only the commit is covered, never the yield or the snapshot after it:
      # once this commit lands the calls ARE answered, and a failure past it
      # repaired here would answer them twice.
      #
      # The repair rebuilds every block rather than committing `delivery`'s:
      # those are the blocks whose commit just raised, and they would raise
      # again.
      def settled(delivery, timeline, &commit)
        timeline.commit(role: :user, **delivery)
      rescue StandardError => e
        errored(timeline, delivery.fetch(:causal_parents), &commit)
        raise e
      end

      # A repair runs on the way out of the failure being handled, and that
      # failure outranks it, for {#cancel}'s reason: whatever stops the repair
      # -- an unpairable call, a store refusing this commit too -- must never
      # replace the error its caller is unwinding from. The head it leaves is
      # answered at the next ask. Only the commit is covered; the yield is not.
      def errored(timeline, causal_parents)
        repaired = errored_commit(timeline, Tool::Cancellation.new(timeline.head, kind: :errored).blocks,
                                  causal_parents)
      rescue StandardError
        nil
      else
        yield repaired
      end

      # The delivery's citations are kept first, because the harvest behind
      # them is exactly-once: an answered question left uncited here can never
      # be cited by a later turn. But a citation is also something the Store
      # checks, so a commit refused with them is retried once without them --
      # answering the calls outranks retiring the question.
      def errored_commit(timeline, content, causal_parents)
        timeline.commit(role: :user, content:, causal_parents:)
      rescue StandardError
        raise if causal_parents.empty?

        timeline.commit(role: :user, content:)
      end

      # Shielded as ONE atom for {Agent#commit_and_account}'s reason and one
      # more: this runs while the task is ALREADY unwinding. `defer_stop` resets
      # its tri-state guard in both its `rescue Cancel` arm and its `ensure`, so
      # a fresh region entered here arms correctly even though the Cancel that
      # brought us in is still in flight. Without the shield the journal write
      # -- IO, and so a suspension point -- is cancelled on the spot, leaving a
      # committed turn nothing ever recorded.
      #
      # **What async guarantees is ONE deferral, and this comment used to claim
      # more.** `Task#cancel` defers only while the guard reads `false`; once it
      # holds a cause it `Fiber.scheduler.raise`s immediately, so a SECOND
      # cancel arriving inside this region is raised, not deferred. Measured
      # 2026-08-22 with two extra stops inside the region: the Timeline commit
      # still lands -- pure Ruby, no suspension point, and it runs first -- and
      # the {Telemetry::ToolCancelled} record is LOST, 0 written rather than 1.
      # So the turn is answered and the witness is missing. Not reachable from a
      # double Ctrl-C ({CLI::Shutdown} blocks in `force_stop`'s `@run_task.wait`
      # and reads no second key), but reachable from an ancestor task or a
      # reactor teardown landing on an already-unwinding run.
      # {Agent#commit_and_account} carries the identical exposure and claims
      # nothing about it either.
      #
      # The delivery is built BEFORE the region opens: {Tool::ResultBlock.of}
      # refuses an unpairable id, and that refusal raised inside the shield
      # would replace the interrupt with an ArgumentError and leave the region
      # half-run.
      #
      # No snapshot write, unlike {#settle}. The uninterruptible region is kept
      # free of file IO, and the snapshot is the one thing here that costs
      # nothing to lose: disk is its source of truth, and the next mutating turn
      # re-derives it.
      def cancel(answers, timeline)
        torn = timeline.head_digest
        delivery = @runner.cancelled_delivery(answers)
        Async::Task.current.defer_stop do
          yield timeline.commit(role: :user, **delivery)
          record_cancellation(answers, torn)
        end
      rescue Tool::Cancellation::Unpairable
        # An unpairable turn cannot be answered at all, and the INTERRUPT
        # OUTRANKS that: {#perform} re-raises the stop the moment this returns,
        # because losing a Ctrl-C is strictly worse than losing a repair, and a
        # bare ArgumentError out of a repair leaves its caller holding neither
        # the repair nor the failure it was handling. Nothing is committed and
        # nothing is journalled -- the behaviour from before the cancellation
        # commit, for this one shape -- and the honest torn head it leaves is
        # what {CLI::Resume::Cancellation} still refuses namedly at load,
        # through the same translation.
        nil
      end

      # Silent for a turn torn AFTER every tool returned: that turn commits real
      # results, cancelled nothing, and so has nothing to report. The presence
      # of a record is itself the signal.
      def record_cancellation(answers, torn)
        return unless answers.cancelled?

        @journal << Telemetry::ToolCancelled.new(head: torn, **answers.partition)
      end
    end
  end
end
