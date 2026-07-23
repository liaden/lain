# frozen_string_literal: true

require "async"

require_relative "auto_surface/pruning"

module Lain
  module Approval
    # A meta-agent standing in for the human at {Approval::Queue}'s second
    # surface. Where {Frontend::ApprovalPolicy} draws pendings off the arrival
    # queue and asks a person, this observes the PARKED set ({Queue#each}) and
    # asks the `auto_approver` role -- opt-in, never wired by default.
    #
    # It observes, it does not consume: draining `dequeue` here would STEAL
    # pendings the human surface then never sees (`queue.rb`'s two-surface
    # discipline). {Pending#decide}'s first-answer-wins is what makes the
    # observe-and-answer race safe -- a human who answers first wins, and this
    # surface's later verdict is a quiet no-op.
    #
    # Every decision it makes is signed {SURFACE}, so a transcript can never
    # confuse an auto approval with a human one. Its doctrine is deny-when-
    # unsure: only a confident `approve`/`deny` settles a pending; a `defer`,
    # an unparseable answer, or a failed spawn leaves the pending for the human
    # surface or the fail-closed timeout -- an ambiguous answer MUST fall toward
    # defer, never toward approve.
    class AutoSurface
      # The plan-pinned surface name every decision wears in the Journal.
      SURFACE = "auto_approver"

      # The catalog role and the prefix mode it spawns under: a fresh root over
      # the shared Store, so the adjudicator reads only the call it is judging,
      # never the parent's conversation.
      ROLE = :auto_approver
      CONTEXT_MODE = :fresh

      # Between polls of the parked set. The surface is a sibling fiber, so the
      # sleep is a scheduler yield, not a wall-clock stall.
      DEFAULT_POLL_INTERVAL = 0.05

      # The template's contract is ONE word: the WHOLE stripped answer must be a
      # verdict token (an optional trailing period tolerated). A hedged answer
      # ("approve the read but deny the write") or any trailing prose fails to
      # match and falls to defer -- deny-when-unsure, at the grammar level.
      VERDICT = /\A(approve|deny|defer)\.?\z/i
      private_constant :VERDICT

      # @param role_spawn [#call] the `(role, context_mode, prompt) -> Tool::Result`
      #   seam ({Skill::RoleSpawn}); injected, so the surface depends on the
      #   message, not on how the child is assembled.
      # @param poll_interval [Numeric] seconds between sweeps of the parked set.
      # @param pruning [#call] releases `@adjudicated` entries for pendings
      #   that have since settled ({Pruning}); injected so the seen-set's
      #   own eviction policy carries its own spec.
      def initialize(role_spawn:, poll_interval: DEFAULT_POLL_INTERVAL, pruning: Pruning.new)
        @role_spawn = role_spawn
        @poll_interval = poll_interval
        @pruning = pruning
        # Identity-keyed (Pending is a plain object, so `eql?`/`hash` are
        # identity): a pending gets ONE adjudication, so a defer is not re-asked
        # on every poll until the clock denies it.
        @adjudicated = {}.compare_by_identity
      end

      # The surface loop: sweep the parked set, then yield until the next poll.
      # Runs in its own fiber beside the human surface; stops with its task.
      def watch(queue)
        loop do
          sweep(queue)
          Async::Task.current.sleep(@poll_interval)
        end
      end

      # One pass over the parked set: adjudicate each undecided pending this
      # surface has not already seen. The parked snapshot is collected with NO
      # IO yield (the block only reads flags), so the enumeration cannot mutate
      # under a concurrent park/settle; the spawn -- which yields -- happens
      # afterwards, over the materialized array. Pruned first, every sweep: a
      # settled pending's `@adjudicated` entry is released before it can pile
      # up over a long watch (the seen-set-growth doctrine {Pruning} carries).
      def sweep(queue)
        @pruning.call(@adjudicated)
        queue.reject { |pending| pending.decided? || @adjudicated.key?(pending) }
             .each { |pending| adjudicate(pending) }
      end

      private

      def adjudicate(pending)
        @adjudicated[pending] = true
        # A sibling surface may have decided it after the parked snapshot was
        # collected: skip the wasted spawn -- first-answer-wins already stands.
        return if pending.decided?

        settle(pending, verdict(pending))
      end

      # Only a confident verdict acts; defer is a deliberate no-op that leaves
      # the pending for the human or the clock.
      def settle(pending, verdict)
        pending.approve(surface: SURFACE) if verdict == :approve
        pending.deny(surface: SURFACE) if verdict == :deny
      end

      def verdict(pending)
        result = @role_spawn.call(ROLE, CONTEXT_MODE, prompt_for(pending))
        parse(result)
      end

      # Fail toward defer: an error result is never signed by this surface at
      # all (BOTH branches gate on ok?), and only a lone verdict token settles a
      # pending. The `defer` token and every non-match alike return :defer,
      # which {#settle} treats as the no-op that leaves the pending to the human
      # or the clock.
      def parse(result)
        match = result.ok? && text_of(result).strip.match(VERDICT)
        match ? match[1].downcase.to_sym : :defer
      end

      def text_of(result)
        content = result.content
        content.is_a?(String) ? content : content.filter_map { |block| block["text"] }.join("\n")
      end

      def prompt_for(pending)
        <<~PROMPT
          A tool call is requesting approval. Judge it and answer with exactly one word.

          requester: #{pending.requester}
          tool: #{pending.tool}
          input: #{pending.input.inspect}

          Answer APPROVE only if the call is plainly safe and appropriate, DENY if it is
          plainly unsafe, and DEFER if you are not sure. When in doubt, DEFER -- never
          approve on doubt.
        PROMPT
      end
    end
  end
end
