# frozen_string_literal: true

module Lain
  # The seam: a pure function from (Timeline, Toolset, Workspace) to a Request.
  # A first-class object rather than a method on the Agent, so that swapping it
  # and re-rendering a recorded Timeline is a byte diff -- dry replay, for free.
  #
  # `#render` must be PURE. No `Time.now`, no session ids, no `Dir.pwd` -- and
  # that is not style, it is the same constraint prompt caching imposes.
  # Anthropic's cache is a prefix match over tools -> system -> messages, so a
  # timestamp interpolated into the system prompt invalidates the whole cached
  # prefix every turn: full input price forever, and nothing errors.
  class Context
    # Owned by {CacheBreakpoints}, restated here because the lookback/spacing
    # relationship is part of what #render promises a Provider rather than an
    # implementation detail of one combinator.
    CACHE_LOOKBACK_BLOCKS = CacheBreakpoints::LOOKBACK_BLOCKS
    BREAKPOINT_EVERY = CacheBreakpoints::EVERY

    # The strategy a Context renders through when none is injected. There is no
    # constant snapshot of its capabilities: a reader asks {#requires}, which
    # answers for the pipeline actually in effect.
    def self.pipeline(workspace)
      Reminder.new(workspace:) >> CacheBreakpoints.new
    end

    attr_reader :system, :max_tokens, :stream, :extra, :requires

    # The catalog name the pipeline was chosen by, or nil when nobody named one
    # -- the class default, or a pipeline injected as a value. Carried by every
    # copy, because a copy is how the chat grafts its live model and how a spawn
    # reshapes its persona, and the session record must name what rendered.
    attr_reader :pipeline_name

    # The model in force NOW. A fixed model wears a {StaticModel}, a live
    # `/model` slot is a {ModelSwitch}, and BOTH answer `#current`, so every
    # reader gets the model in force at read time. The switch is the one
    # deliberate, journaled impurity here.
    def model = @model.current

    # `extra` (temperature, seed, num_ctx) rides through to Request#extra, which
    # Request excludes from cache_payload/digest by design -- so threading it
    # here keeps #render pure WITHOUT letting a temperature change read as a
    # different prompt. Normalized, and so deeply frozen, at construction.
    #
    # `pipeline` is the injected render strategy, duck-typed by shape: a
    # Combinator (it answers `#requires`) is used as-is, anything else is a pure
    # `->(workspace)` provider called per render. It must be Ractor-shareable
    # like every combinator, and a bare lambda whose self is `main` is not.
    #
    # @note a raw Combinator injected here freezes whatever Workspace it was
    #   constructed with -- `#pipeline_for` hands it straight back and never
    #   sees the per-render Workspace. A stage that must read the LIVE Workspace
    #   MUST come from the `->(workspace)` provider form; a raw Combinator built
    #   around Workspace A keeps emitting A even under `render(workspace: B)`,
    #   silently defeating "Workspace is sent, not stored".
    #
    # The requires slot is derived from the EFFECTIVE pipeline in both the
    # injected and the fallback case: a `self.pipeline`-overriding subclass
    # would otherwise report the base class's capabilities for a pipeline that
    # never uses them. One extra `#pipeline_for` call per construction is that
    # guarantee's price.
    #
    # `pipeline_name` is a label and is never resolved here: a name becomes a
    # pipeline before construction ({CLI::ContextPipeline}), so #render reads
    # nothing a name could change.
    def initialize(model:, max_tokens:, system: nil, stream: true, extra: {}, pipeline: nil, pipeline_name: nil)
      # A delegating slot is stored AS the slot; flattening it to its current
      # value would fix the model at construction, which is the very seam
      # `/model` exists to escape.
      @model = model.respond_to?(:current) ? model : StaticModel.new(model)
      @max_tokens = Integer(max_tokens)
      @system = system && Canonical.normalize(system)
      @stream = stream
      @extra = Canonical.normalize(extra)
      @pipeline = pipeline
      @pipeline_name = pipeline_name && -pipeline_name
      @requires = pipeline_for(Workspace.empty).requires
      freeze
    end

    # How Wiring grafts a live {ModelSwitch} onto the Context a Backend already
    # assembled, without Backend learning about slots. A copy, because Context
    # is frozen by design.
    def with_model(model) = copy(model:)

    # How a spawn gives a child its persona: the system prompt replaced, the
    # render strategy and everything else kept.
    def with_system(system) = copy(system:)

    # The mirror of #with_model: how a per-turn source
    # ({Agent::PipelineSource}) swaps the render strategy without rebuilding the
    # Context from parts it does not own.
    #
    # The name is KEPT. That is true of compaction's swap, a composition over
    # the named base whose collapse policy the scheduler journals. A caller that
    # replaces the pipeline outright ({Plan::Runner}) keeps a label that no
    # longer describes what renders, so it must be handed an unnamed Context.
    def with_pipeline(pipeline) = copy(pipeline:)

    # The default strategy is one point in the combinator space a caller reaches
    # for directly, never a parallel implementation of it.
    #
    # @return [Lain::Request] deterministic for identical inputs
    def render(timeline:, toolset:, workspace: Workspace.empty)
      pipeline = pipeline_for(workspace)

      Request.new(
        model:,
        system: cache_marked(system_blocks),
        tools: toolset.to_schema,
        messages: pipeline.call(projected(timeline, pipeline)),
        max_tokens:,
        stream:,
        extra:
      )
    end

    # The render pipeline in effect for this workspace. #render and #requires
    # both route through here, which is what keeps a declared capability from
    # drifting from the behavior it names.
    #
    # PUBLIC because #with_pipeline is a write that needs a matching read: a
    # per-turn source ({Agent::PipelineSource}) wrapping the render strategy
    # must first ask what that strategy would otherwise have been.
    #
    # `self.class.pipeline(workspace)` is NOT a substitute for that read -- it
    # discards an injected `@pipeline` and rebuilds the class default. Neither
    # is a hand-rolled stand-in: a base that omits {Reminder} drops the
    # Session's live reminders from every wrapped render, and NOTHING catches
    # it, because the composed `#requires` is a union and still reports
    # `[:prompt_caching]`.
    def pipeline_for(workspace)
      return self.class.pipeline(workspace) if @pipeline.nil?

      Context.combinator_for(@pipeline, workspace)
    end

    # What an injected pipeline MEANS for one render. The duck is PUBLIC and has
    # four consumers, each of which used to hold this same expression under a
    # comment telling the next reader to keep it in sync by hand.
    #
    # It tests for `#requires` rather than for `#call` because BOTH shapes
    # answer `#call`, so `#requires` is the only thing telling them apart.
    #
    # `Context.` and not `self.class.`: this is the published duck's resolution
    # rule, not a subclass hook. A subclass chooses its default strategy by
    # overriding `self.pipeline`, but what an INJECTED pipeline means must be
    # the same answer everywhere, or a bench user's own combinator resolves
    # differently depending on which Context received it.
    #
    # @param pipeline [#requires, #call] a Combinator, or a `->(workspace)`
    #   provider of one
    # @param workspace [Workspace] this render's Workspace, live
    # @return [Context::Combinator]
    def self.combinator_for(pipeline, workspace)
      pipeline.respond_to?(:requires) ? pipeline : pipeline.call(workspace)
    end

    private

    # The one place every attribute is listed, so a copy cannot drop one.
    #
    # `model: @model` is the STORED slot, deliberately not the `#model` reader.
    # The reader unwraps to `.current`, so copying it would flatten a live
    # {ModelSwitch} to whatever it held at copy time and silently break `/model`
    # from the next turn on.
    def copy(**changes)
      self.class.new(model: @model, max_tokens:, system:, stream:, extra:, pipeline: @pipeline, pipeline_name:,
                     **changes)
    end

    # Hoisted, because a `[].freeze` literal allocates a fresh Array per read
    # and this one is read on every turn of a compacting session.
    NO_MESSAGES = [].freeze
    private_constant :NO_MESSAGES

    # The Timeline as the message list a Provider sees. {Compaction::Head} and
    # {Compaction::Derivation.projected} project the same two keys the same way,
    # deliberately: a head must be measured, and a derived chain validated, in
    # the very bytes this line produces.
    #
    # NOT MADE AT ALL for a pipeline whose first stage substitutes its own list.
    # The walk is O(n) in history length and its result is discarded unread on
    # every turn a compaction renders through a derived chain; nothing
    # downstream of a substituting stage can observe the argument, so skipping
    # it cannot move a byte.
    def projected(timeline, pipeline)
      return NO_MESSAGES if substituting?(pipeline)

      timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }
    end

    # `respond_to?` and not a bare send, because the injected-pipeline duck is
    # PUBLIC and older than this question: widening it in place would break
    # every existing implementer with a `NoMethodError` from inside `#render`.
    # Silence therefore means "reads its messages" -- a stage opts OUT by saying
    # so, and the saving belongs to the stage that claims it.
    #
    # Kept apart from {.combinator_for} on purpose: that RESOLVES a pipeline
    # value against a workspace for four callers, while this asks a property of
    # an already-resolved combinator for one.
    def substituting?(pipeline)
      pipeline.respond_to?(:reads_messages?) && !pipeline.reads_messages?
    end

    # The system prompt in Anthropic's block form, normalized ONCE -- the one
    # type check a public input accepting either shape costs, confined here
    # rather than smeared through render.
    #
    # It lives in render, NOT the constructor, on purpose: `#system` keeps the
    # shape it was given, which is what Bench::Session serializes verbatim into
    # its header. Normalizing the stored value would silently rewrite that
    # header (String -> blocks), and the session round trip with it.
    def system_blocks
      return nil if system.nil?

      system.is_a?(String) ? [{ "type" => "text", "text" => system }] : system
    end

    # Caching the system prompt caches the tools with it, since tools lead the
    # matched prefix. Marks the final block; a no-op on nil or an empty list.
    def cache_marked(blocks)
      return blocks if blocks.nil? || blocks.empty?

      blocks[0..-2] + [blocks.last.merge("cache" => true)]
    end
  end
end
