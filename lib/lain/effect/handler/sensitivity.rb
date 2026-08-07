# frozen_string_literal: true

module Lain
  module Effect
    class Handler
      # Refuses a call naming a DENIED path outright, ahead of {Gate}.
      #
      # A denied path is not approvable. No policy, no `--yolo`, no
      # {Gate::ApproveAll} lifts it -- which is exactly why it cannot be a Gate
      # policy answer: that answer is a Boolean, and every Boolean is
      # approvable by construction. So the two axes sit in two handlers, in
      # this order: what may not be touched at all is refused here, and what is
      # merely worth asking about falls through to the Gate, where a human
      # still has a move.
      #
      # It refuses READS and WRITES alike, because {Lain::Sensitivity::Policy}'s
      # table names `write_file`, `edit_file`, `bash` and `core_exec` beside the
      # readers. Writing to `~/.ssh/id_ed25519` is not a lesser act than reading
      # it, and narrowing this handler to read-shaped fields would open a hole
      # rather than close one.
      #
      # == Loud, because a quiet refusal gets retried
      #
      # The message names the path, names WHY (the classifier's own
      # {Lain::Sensitivity::Verdict#explanation}, so a project's `[sensitivity]`
      # denial reads as the project's rather than as ours), and says the
      # boundary cannot be moved. A model told only "no" resends the same call
      # spelled differently; one told "no approval can lift this" spends its
      # next turn somewhere useful. The advice names no VERB, because the same
      # sentence answers a refused write.
      #
      # It never names the file's BYTES, and cannot: the refusal is decided
      # from the path alone, before anything is opened. That is the same
      # discipline {Middleware::RefuseSecretWrites} keeps on the write side,
      # and {Telemetry::ReadRefused} is where the path itself is the
      # deliberate widening.
      #
      # == It holds no table and no Null of its own
      #
      # Which input field names a path, per tool, is
      # {Lain::Sensitivity::Policy}'s one piece of tool coupling, pinned by a
      # completeness spec with no allowlist in it. This handler asks that same
      # object one further question -- {Lain::Sensitivity::Denial}, or nil -- so
      # the gate's axis and this one read ONE table and cannot drift apart.
      #
      # Its default is that same class's Null for the same reason. A Null
      # answering only `denial` would be an object this layer accepts and the
      # Gate rejects (`NoMethodError: gates?`), which contradicts the premise
      # that both layers take THE SAME injected object.
      class Sensitivity < Handler
        # @param sensitivity [#denial] the session's ONE path policy, answering
        #   `(effect) -> Lain::Sensitivity::Denial | nil`. Injected, never built
        #   here: building a {Lain::Sensitivity} raises on an unusable cwd, and a
        #   raise on the synchronous dispatch path becomes a fault a human is
        #   then invited to allow -- a disarm the model controls the timing of.
        #
        #   ROOT-QUALIFIED for {Gate#initialize}'s reason, and more sharply
        #   here: inside this class body a bare `Sensitivity` is THIS CLASS.
        # @param journal [#<<] where {Telemetry::ReadRefused} lands
        # @param inner [Lain::Effect::Handler, nil] runs everything this
        #   handler declines -- the {Gate}, in the session's chain
        def initialize(sensitivity: Lain::Sensitivity::Policy::Null.instance,
                       journal: Channel::Null.instance, inner: nil)
          super(inner:)
          @sensitivity = sensitivity
          @journal = journal
        end

        def handles?(effect) = !@sensitivity.denial(effect).nil?

        protected

        # Reported, never raised -- {Gate#perform}'s contract, for the same
        # reason: a raised refusal wedges the loop, where an is_error Result
        # is something the next turn can read and act on.
        #
        # The nil branch is not defensive habit. {Handler#call} asks `handles?`
        # and then calls this, and the two questions can straddle a board
        # change: {CLI::Wiring::ToolsetBuild::LiveSensitivity} -- what both
        # production chains are wired with -- re-reads `board.call` on EVERY
        # call, which is the liveness property T11's spec asserts by moving the
        # board slot between two calls. So a fixed Policy answers the same
        # thing twice and the delegator need not, and `nil.path` here would be
        # a NoMethodError on the synchronous dispatch path -- the shape
        # {Lain::Sensitivity::Policy#denial}'s own comment calls the worst a
        # security control can take. Declining is the honest reading of
        # "nothing denies this now".
        def perform(effect, context)
          denial = @sensitivity.denial(effect)
          denial.nil? ? decline(effect, context) : refuse(denial)
        end

        private

        def refuse(denial)
          @journal << Telemetry::ReadRefused.new(tool_use_id: denial.tool_use_id, tool: denial.tool,
                                                 path: denial.path, reason: denial.reason.to_s)
          Tool::Result.error(
            "refused: #{denial.path} is #{denial.verdict.explanation}; no approval can lift this, " \
            "so name a different path rather than retrying this one in another form"
          )
        end

        # {Handler#call}'s own fallback, reachable from {#perform}, because this
        # is the one handler that can stop handling an effect between the two.
        def decline(effect, context)
          raise UnhandledEffect, "#{self.class} cannot handle #{effect.class}" unless @inner

          @inner.call(effect, context)
        end
      end
    end
  end
end
