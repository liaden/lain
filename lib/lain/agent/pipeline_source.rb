# frozen_string_literal: true

module Lain
  class Agent
    # Where the Context for THIS turn comes from.
    #
    # `Agent#context` is construction-fixed, which is right for a fixed render
    # strategy and wrong for one that must re-decide each turn: compaction reads
    # the history that just grew, the cache warmth the last response reported,
    # and the plan step the Session just finished, none of which exist at
    # construction. `turn_middleware` cannot serve either -- it wraps the turn
    # two frames above `#render_request` and never sees the Context.
    #
    # The duck is one message:
    #
    #   context_for(base:, timeline:, usage:, session:) -> Context
    #
    # `usage` is the LAST turn's billed input tokens, nil before any turn --
    # distinct from zero, which would read as an empty context on a resumed
    # session. `session:` is here because the Agent is the only place it and the
    # base Context both exist: Wiring hands the two to `Agent.new` separately, so
    # a source constructed anywhere else cannot reach the Session.
    #
    # An implementation answers `base` itself when it decides to change nothing,
    # and `base.with_pipeline(...)` when it does -- never a mutated Context,
    # which is frozen by design.
    module PipelineSource
      # Null Object, the Agent's default: the SAME Context back, byte-identical
      # rather than merely equivalent, so no caller writes `if source`.
      #
      # `(**)` swallows `timeline:`/`usage:`/`session:` without naming them,
      # which says "decides on nothing" more plainly than three underscored
      # parameters would.
      module Null
        module_function

        def context_for(base:, **) = base

        # Compaction is off, so there is never anything it could drop.
        def droppable? = false
      end
    end
  end
end
