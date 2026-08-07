# frozen_string_literal: true

module Lain
  module Approval
    # A meta-agent standing in for the human at {Approval::Queue}'s second
    # surface. Where {Frontend::ApprovalPolicy} draws pendings off the arrival
    # queue and asks a person, this observes the PARKED set and asks the
    # `auto_approver` role -- opt-in, never wired by default. The observing,
    # the seen-set and the polling are {QueueSurface}'s; this class is the
    # role, the prompt, the verdict grammar and the abstention.
    #
    # Every decision it makes is signed {SURFACE}, so a transcript can never
    # confuse an auto approval with a human one, and
    # {Escalation::Surfaces::AUTOMATIC} lists that name so the ladder reads the
    # decision as the machine judgement it is. Its doctrine is deny-when-
    # unsure: only a confident `approve`/`deny` settles a pending; a `defer`,
    # an unparseable answer, or a failed spawn leaves the pending for the human
    # surface or the fail-closed timeout -- an ambiguous answer MUST fall toward
    # defer, never toward approve.
    class AutoSurface < QueueSurface
      # The plan-pinned surface name every decision wears in the Journal.
      SURFACE = "auto_approver"

      # The catalog role and the prefix mode it spawns under: a fresh root over
      # the shared Store, so the adjudicator reads only the call it is judging,
      # never the parent's conversation.
      ROLE = :auto_approver
      CONTEXT_MODE = :fresh

      # The template's contract is ONE word: the WHOLE stripped answer must be a
      # verdict token (an optional trailing period tolerated). A hedged answer
      # ("approve the read but deny the write") or any trailing prose fails to
      # match and falls to defer -- deny-when-unsure, at the grammar level.
      VERDICT = /\A(approve|deny|defer)\.?\z/i
      private_constant :VERDICT

      # @param role_spawn [#call] the `(role, context_mode, prompt) -> Tool::Result`
      #   seam ({Skill::RoleSpawn}); injected, so the surface depends on the
      #   message, not on how the child is assembled. Every other keyword
      #   forwards to {QueueSurface} -- `poll_interval:`, `pruning:`, `journal:`.
      def initialize(role_spawn:, **)
        super(**)
        @role_spawn = role_spawn
      end

      # ORDINARY approvals -- the ones that release nothing sensitive -- and
      # that abstention is the half of the partition this class owns.
      #
      # {ROLE}'s catalog and the one-word prompt below were built for those, and
      # neither is told that a file's sensitive regions are what a yes would
      # release. So an approve on a region-carrying pending would release
      # secrets with NO human in the loop at all, on a judgement that was never
      # asked the question. {SecretSurface} is the surface that IS asked it, and
      # it judges exactly the complement of this.
      #
      # @param outstanding [Approval::Queue::Outstanding]
      # @return [Boolean]
      def judges?(outstanding) = outstanding.none?

      private

      # Only a confident verdict acts; defer is a deliberate no-op that leaves
      # the pending for the human or the clock.
      def settle(pending, verdict)
        pending.approve(surface: SURFACE) if verdict == :approve
        pending.deny(surface: SURFACE) if verdict == :deny
      end

      def answer_for(pending)
        parse(@role_spawn.call(ROLE, CONTEXT_MODE, prompt_for(pending)))
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
