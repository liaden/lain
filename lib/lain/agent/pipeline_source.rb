# frozen_string_literal: true

module Lain
  class Agent
    # Where the Context for THIS turn comes from.
    #
    # `Agent#context` is construction-fixed -- assigned once, no writer -- and
    # every render went straight through it. That is right for a fixed render
    # strategy and wrong for one that must re-decide each turn: compaction reads
    # the history that just grew, the warmth of the cache the last response
    # reported, and the plan step the Session just finished, none of which exist
    # at construction. `turn_middleware` cannot serve either -- it wraps the turn
    # two frames above `#render_request` and never sees the Context.
    #
    # The duck is one message:
    #
    #   context_for(base:, timeline:, usage:, session:) -> Context
    #
    # `base` is the Agent's own Context, `timeline` the history as of this
    # render, `usage` the LAST turn's billed input tokens (nil before any turn --
    # distinct from zero, which would read as an empty context on a resumed
    # session), and `session` the run's single mutable Session. `session:` is
    # here because the Agent is the only place it and the base Context both
    # exist: Wiring builds the Session and hands it to `Agent.new` separately
    # from the Context, so a source constructed anywhere else cannot reach it.
    #
    # An implementation answers `base` itself when it decides to change nothing,
    # and `base.with_pipeline(...)` when it does -- never a mutated Context,
    # which is frozen by design.
    module PipelineSource
      # Null Object, the Agent's default. It answers the SAME Context, so an
      # Agent built without a source renders the identical frozen value it
      # always did -- byte-identical, not merely equivalent -- and no caller
      # writes `if source`.
      #
      # `(**)` swallows `timeline:`/`usage:`/`session:` without naming them,
      # which says "decides on nothing" more plainly than three underscored
      # parameters would.
      module Null
        module_function

        def context_for(base:, **) = base
      end
    end
  end
end
