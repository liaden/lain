# frozen_string_literal: true

module Lain
  module Middleware
    # Refuses a call naming a DENIED path outright, one layer ahead of {Gate}.
    #
    # A denied path is not approvable -- no policy, no `/mode auto`, no
    # {Gate::ApproveAll} lifts it -- which is exactly why it cannot be a gate
    # policy answer: that answer is a Boolean, and every Boolean is approvable
    # by construction. So the two axes sit in two layers, in this order: what
    # may not be touched at all is refused here, and what is merely worth
    # asking about passes on to the gate, where a human still has a move.
    #
    # It refuses READS and WRITES alike, because {Lain::Sensitivity::Policy}'s
    # table names `write_file`, `edit_file` and `bash` beside the readers.
    # Writing to `~/.ssh/id_ed25519` is not a lesser act than reading it, and
    # narrowing this layer to read-shaped fields would open a hole rather than
    # close one.
    #
    # == Loud, because a quiet refusal gets retried
    #
    # A model told only "no" resends the same call spelled differently, so the
    # message names the path, names WHY (the classifier's own
    # {Lain::Sensitivity::Verdict#explanation}, so a project's `[sensitivity]`
    # denial reads as the project's rather than as ours), and says the boundary
    # cannot be moved. It names no VERB: one sentence answers a refused write.
    #
    # It never names the file's BYTES, and cannot: this is the gate-on-the-
    # effect half of the secret boundary, decided from the path alone before
    # anything is opened, the discipline {RefuseSecretWrites} keeps on the write
    # side. {Telemetry::ReadRefused} is the deliberate widening.
    #
    # == It holds no table and no Null of its own
    #
    # Which input field names a path, per tool, is {Lain::Sensitivity::Policy}'s
    # one piece of tool coupling. This layer asks that same object one further
    # question -- {Lain::Sensitivity::Denial}, or nil -- so the gate's axis and
    # this one read ONE table and cannot drift apart. Its default is that same
    # class's Null for the same reason: a Null answering only `denial` would be
    # an object this layer accepts and the gate rejects (`NoMethodError:
    # gates?`), contradicting the premise that both layers take THE SAME
    # injected object.
    #
    # The policy is asked ONCE per call. Its live delegator re-reads the board
    # on every question, so a layer that asked twice -- once to decide, once to
    # refuse -- could be told two different things about one call.
    class Sensitivity < Base
      # @param sensitivity [#denial] the session's ONE path policy, answering
      #   `(effect) -> Lain::Sensitivity::Denial | nil`. Injected, never built
      #   here: building a {Lain::Sensitivity} raises on an unusable cwd, and a
      #   raise on the synchronous dispatch path becomes a fault a human is
      #   then invited to allow -- a disarm the model controls the timing of.
      #   ROOT-QUALIFIED, because inside this class body a bare `Sensitivity`
      #   is THIS CLASS.
      # @param journal [#<<] where {Telemetry::ReadRefused} lands
      def initialize(sensitivity: ::Lain::Sensitivity::Policy::Null.instance, journal: Channel::Null.instance)
        @sensitivity = sensitivity
        @journal = journal
        super()
        freeze
      end

      # Reported, never raised -- {Gate#call}'s contract, for the same reason:
      # a raised refusal wedges the loop, where an is_error Result is something
      # the next turn can read and act on.
      def call(env, &app)
        denial = @sensitivity.denial(env.fetch(:effect))
        return downstream(env, &app) if denial.nil?

        env.merge(result: refuse(denial))
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
    end
  end
end
