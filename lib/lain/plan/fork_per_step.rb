# frozen_string_literal: true

module Lain
  module Plan
    # The fork-per-step execution shape: each chunk runs on a FORK of the
    # mainline, and at the seam that fork DIES -- only the chunk's {Closure}
    # digest is committed to the mainline, never the chunk's turns. So the
    # mainline is strictly append-only (it gains one closure-reference turn per
    # seam and nothing else) and its prompt-cache prefix is never rewritten; the
    # chunk's own turns live on a branch nobody continues.
    #
    # It acts on the {Continuation}'s TIMELINE half and leaves the pipeline
    # untouched: subsequent turns render exactly as before, which is what makes a
    # fork-per-step run show ZERO prefix rewrites against a {LinearRewrite} run's
    # one-per-seam (PC-3's visible-difference AC).
    #
    # Unlike {Compaction::Scheduler} (a frozen, stateless policy) this one is
    # STATEFUL by necessity: the mainline is exactly the thing continuations
    # chain on, and +state.head_digest+ at a seam names the FORK's tail, not the
    # mainline -- so the policy must carry the mainline head across seams itself.
    # That is why it "takes the store-backed timeline" (PC-3): +mainline+ is the
    # Timeline it advances, and the {Runner} adopts the head it returns, so the
    # two never drift.
    class ForkPerStep
      include SeamPolicy

      # @return [Timeline] the mainline as advanced so far -- append-only
      attr_reader :mainline

      # @return [Array<Supersession>] the reopen references recorded so far, in
      #   the order steps reopened; empty until a step closes a second time
      attr_reader :supersessions

      # @param mainline [Timeline] the store-backed mainline every fork branches
      #   from; the {Runner}'s run starts from this same Timeline
      def initialize(mainline:)
        @mainline = mainline
        @closed = {}
        @supersessions = []
      end

      # Commit the closure's digest to the mainline and hand back a continuation
      # that continues ON the extended mainline with the SAME pipeline. The
      # fork whose tail +state.head_digest+ named is simply not carried forward:
      # abandoning it IS the fork dying.
      #
      # A step that already closed is REOPENING: the new closure supersedes the
      # old by reference ({Supersession}), recorded in the Store beside the old
      # record -- which stays byte-for-byte untouched, since the Store is
      # append-only and nothing here rewrites it.
      #
      # @param state [Continuation] the current continuation (pipeline preserved)
      # @param closure [Closure] the just-closed chunk's deterministic record,
      #   already put in the Store by the {Runner}
      # @return [Continuation]
      def at_seam(state:, closure:)
        note_supersession(closure) if @closed.key?(closure.step_id)
        @closed[closure.step_id] = closure.digest
        @mainline = @mainline.commit(role: "assistant", content: closure_reference(closure))
        Continuation.new(head_digest: @mainline.head_digest, pipeline: state.pipeline)
      end

      private

      def note_supersession(closure)
        supersession = Supersession.new(step_id: closure.step_id,
                                        superseded: @closed.fetch(closure.step_id),
                                        superseding: closure.digest)
        # Store-borne ONLY for now. P2's {Closure#record} pointer precedent says
        # a reopen must be journal-discoverable too (a later session reading
        # NDJSON alone must find the succession), but the Journalable/Telemetry
        # edit that carries it lands in a SEQUENCED follow-on -- P4 owns this
        # wave's telemetry.rb edit and is in flight. The pointer addendum lands
        # after P4, in its own worktree; the record is in .handback-P3.md.
        @mainline.store.put(supersession)
        @supersessions << supersession
      end

      # The mainline turn that stands in for a whole closed chunk: a single block
      # NAMING the closure in the Store rather than copying its bytes, so the
      # mainline carries a pointer (the elided turns still live in the Store,
      # addressed by the closure) and never the chunk's inflated history.
      def closure_reference(closure)
        [{ "type" => "plan_closure", "step_id" => closure.step_id, "closure" => closure.digest }]
      end
    end
  end
end
