# frozen_string_literal: true

module Lain
  module Approval
    # A meta-agent standing in for the human at {Approval::Queue}'s second
    # surface: it observes the PARKED set and asks the `auto_approver` role.
    # Wired into every session, and silent until the `auto_approve`
    # mode layer is on. The observing, the seen-set and the polling are
    # {QueueSurface}'s; this class is the role, the prompt, the verdict grammar,
    # the abstention and the layer.
    #
    # Every decision is signed {SURFACE}, so a transcript can never confuse an
    # auto approval with a human one, and {Escalation::Surfaces::AUTOMATIC}
    # lists that name so the ladder reads it as the machine judgement it is.
    # DENY-WHEN-UNSURE: only a confident `approve`/`deny` settles a pending, and
    # a `defer`, an unparseable answer or a failed spawn leaves it for the human
    # surface or the fail-closed timeout.
    class AutoSurface < QueueSurface
      # The plan-pinned surface name every decision wears in the Journal.
      SURFACE = "auto_approver"

      # A FRESH root over the shared Store, so the adjudicator reads only the
      # call it is judging and never the parent's conversation.
      ROLE = :auto_approver
      CONTEXT_MODE = :fresh

      # The WHOLE stripped answer must be a verdict token, a trailing period
      # tolerated. A hedged answer ("approve the read but deny the write") or
      # any trailing prose fails to match and falls to defer -- deny-when-unsure
      # at the grammar level.
      VERDICT = /\A(approve|deny|defer)\.?\z/i
      private_constant :VERDICT

      # A session without `--secret-oracle` has no senior; a Null Object so
      # {#claims?} never guards on nil.
      class NoSenior
        def path_gate?(_pending) = false
      end

      NO_SENIOR = NoSenior.new.freeze
      private_constant :NO_SENIOR

      # @param role_spawn [#call, #never_parking] the
      #   `(role, context_mode, prompt) -> Tool::Result` seam ({Skill::RoleSpawn});
      #   injected, so the surface depends on the message, not on how the child
      #   is assembled. Every other keyword
      #   forwards to {QueueSurface} -- `poll_interval:`, `pruning:`, `journal:`.
      # @param enabled [#call] answers whether the `auto_approve` layer is on
      #   RIGHT NOW, read on every sweep and again before a verdict settles, so
      #   `/mode -auto_approve` withdraws the surface without rebuilding it.
      #   Required: an always-on default would turn a forgotten wire into a
      #   surface that decides for a session that never asked it to.
      def initialize(role_spawn:, enabled:, **)
        super(**)
        @role_spawn = role_spawn
        @enabled = enabled
        @senior = NO_SENIOR
      end

      # Nothing is asked while the layer is off, so a session that never turns
      # it on spends nothing on the role. A pending parked meanwhile is left
      # unmarked, and is judged if the layer comes on while it is still parked.
      #
      # It sweeps {Queue#automatic} rather than the whole parked set, so a call
      # only a human may decide is never put to the role.
      #
      # @param queue [Approval::Queue]
      # @return [void]
      def sweep(queue)
        super(queue.automatic) if @enabled.call
      end

      # ORDINARY approvals only -- the ones that release nothing sensitive.
      # {ROLE}'s catalog and the prompt below were built for those, and neither
      # is told that a file's sensitive regions are what a yes would release, so
      # an approve on a region-carrying pending would release secrets with NO
      # human in the loop, on a judgement never asked the question.
      # {SecretSurface} judges exactly the complement of this.
      #
      # @param outstanding [Approval::Queue::Outstanding]
      # @return [Boolean]
      def judges?(outstanding) = outstanding.none?

      # A pending the senior surface takes is not asked here. Declared by the
      # one place that assembles both surfaces, so no session has two models
      # judging one path.
      #
      # @param pending [Approval::Queue::Pending]
      # @return [Boolean]
      def claims?(pending) = super && !@senior.path_gate?(pending)

      # @param surface [#path_gate?] the surface that judges path gates ahead of this one
      # @return [void]
      def yield_path_gates_to(surface)
        @senior = surface
        nil
      end

      private

      # Defer is a deliberate no-op that leaves the pending for the human or
      # the clock, and so is any verdict that returns after the layer went off:
      # the ask yields while the role thinks, and the human may have withdrawn
      # the surface in that window.
      def settle(pending, verdict)
        return unless @enabled.call

        pending.approve(surface: SURFACE) if verdict == :approve
        pending.deny(surface: SURFACE) if verdict == :deny
      end

      # Through the never-parking spawn: this sweep waits on the child, so a
      # child parked on this queue could only be answered once the sweep it
      # blocks had finished.
      def answer_for(pending)
        parse(@role_spawn.never_parking.call(ROLE, CONTEXT_MODE, prompt_for(pending)))
      end

      # Fail toward defer: an error result is never signed by this surface at
      # all -- BOTH branches gate on `ok?` -- and only a LONE verdict token
      # settles a pending.
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
