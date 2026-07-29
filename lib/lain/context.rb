# frozen_string_literal: true

require_relative "context/base"
require_relative "context/protected_patterns"
require_relative "context/pinned_messages"
require_relative "context/cache_breakpoints"
require_relative "context/message_envelope"
require_relative "context/conversation"
require_relative "context/tail_injection"
require_relative "context/reminder"
require_relative "context/prune"
require_relative "context/compact"
require_relative "context/dedupe_tool_calls"
require_relative "context/purge_failed_inputs"
require_relative "context/recall"
require_relative "context/mailbox"
require_relative "context/static_model"
require_relative "context/model_switch"

module Lain
  # The seam. A pure function from (Timeline, Toolset, Workspace) to a Request.
  #
  # Tool design, context management, and orchestration are three views of this one
  # function, which is why it is a first-class object rather than a method on the
  # Agent. Swap it, re-render a recorded Timeline, diff the bytes: that is dry
  # replay, and it costs nothing.
  #
  # == Purity is not a style preference
  #
  # `#render` must be a pure function of its arguments. No `Time.now`, no session
  # ids, no `Dir.pwd`. This is the *same* constraint prompt caching imposes:
  # Anthropic's cache is a prefix match over tools -> system -> messages, so a
  # timestamp interpolated into the system prompt invalidates the entire cached
  # prefix on every single turn -- you pay full input price forever and nothing
  # errors. One requirement, two payoffs: reproducible dry replay, and a cache
  # that actually hits.
  #
  # M1 ships a single renderer. The composable combinators (Prune, Compact,
  # Reminders) and their monoid land in M3; the seam is shaped for them now so
  # that arrival is a swap rather than a rewrite.
  class Context
    # Delegated to Context::CacheBreakpoints, the combinator that actually
    # owns this policy (3c-2.4) -- kept as Context constants too since the
    # lookback/spacing relationship is part of what #render promises a
    # Provider, not just an implementation detail of one combinator.
    CACHE_LOOKBACK_BLOCKS = CacheBreakpoints::LOOKBACK_BLOCKS
    BREAKPOINT_EVERY = CacheBreakpoints::EVERY

    # The message-list combinator pipeline #render composes: Reminder injects
    # the Workspace tail, then CacheBreakpoints marks the result. Named once
    # so both #render and REQUIRES read from a SINGLE source -- change the
    # strategy here and the declared capabilities follow automatically.
    def self.pipeline(workspace)
      Reminder.new(workspace:) >> CacheBreakpoints.new
    end

    # Capabilities this renderer needs, DERIVED from the pipeline above rather
    # than hardcoded, so the declaration cannot drift from the behavior.
    # Reminder#requires is workspace-independent, so an empty Workspace yields
    # a representative pipeline. A Provider lacking a capability degrades
    # (loudly, into the Journal) rather than silently producing a different
    # prompt.
    REQUIRES = pipeline(Workspace.empty).requires

    attr_reader :system, :max_tokens, :stream, :extra, :requires

    # The model in force NOW. A fixed model wears a {StaticModel}; a live
    # `/model` slot is a {ModelSwitch} -- BOTH answer `#current`, so #render
    # (and every header/serializer reading `context.model`) reads the model in
    # force through one message, at read time. The switch is the one deliberate,
    # journaled impurity here; a StaticModel-wrapped Context renders exactly as
    # the old bare-String path did.
    def model = @model.current

    # `extra` carries provider-specific sampler params (temperature, seed,
    # num_ctx). It rides through to Request#extra, which Request excludes from
    # cache_payload/digest by design -- so threading it here keeps #render pure
    # (identical inputs, identical bytes) WITHOUT letting a temperature change
    # read as a different prompt. Normalized (and thus deeply frozen) at
    # construction so the frozen Context holds no mutable reference.
    #
    # `pipeline` is the injected render strategy, duck-typed by shape: a
    # Combinator (responds to `#requires`) is used as-is; anything else is
    # treated as a pure `->(workspace)` provider and called per render for a
    # Combinator (Reminder needs the live Workspace, which is why the provider
    # form exists). Omitted, #render falls back to `self.class.pipeline(workspace)`,
    # so a default Context -- and any subclass overriding `self.pipeline` --
    # renders exactly its own default. It must be Ractor-shareable like every
    # combinator; a bare lambda whose self is `main` is not, so a provider is
    # built where self is shareable.
    #
    # WARNING: a raw Combinator injected here freezes whatever Workspace it was
    # constructed with -- `#pipeline_for` hands it straight back and never sees
    # the per-render Workspace. A stage that must read the LIVE Workspace (a
    # Reminder over the caller's evolving reminders) MUST come from the
    # `->(workspace)` provider form; a raw Combinator built around Workspace A
    # will keep emitting A even under `render(workspace: B)`, silently defeating
    # "Workspace is sent, not stored." The provider form closes over nothing and
    # is rebuilt against each render's Workspace, so it has no such trap.
    #
    # `@requires` is derived from the effective pipeline for BOTH the injected
    # and the fallback case -- never shortcut to the REQUIRES class constant, or
    # a `self.pipeline`-overriding subclass would report the base class's
    # capabilities for a pipeline that never uses them (drift #render doesn't
    # have). The one extra `#pipeline_for` call here (per construction, not per
    # render) is that guarantee's price.
    def initialize(model:, max_tokens:, system: nil, stream: true, extra: {}, pipeline: nil)
      # A delegating slot ({ModelSwitch}) is stored AS the slot (never flattened
      # to its current value, which would fix the model at construction -- the
      # very seam /model exists to escape); a plain model is wrapped in a frozen
      # {StaticModel}, its immutable sibling, so both answer #current.
      @model = model.respond_to?(:current) ? model : StaticModel.new(model)
      @max_tokens = Integer(max_tokens)
      @system = system && Canonical.normalize(system)
      @stream = stream
      @extra = Canonical.normalize(extra)
      @pipeline = pipeline
      @requires = pipeline_for(Workspace.empty).requires
      freeze
    end

    # This Context rebuilt around `model` (typically a {ModelSwitch}), keeping
    # system/max_tokens/stream/extra/pipeline -- how Wiring grafts the live
    # slot onto the Context a Backend already assembled, without Backend
    # learning about slots. A copy, because Context is frozen by design.
    def with_model(model)
      self.class.new(model:, max_tokens:, system:, stream:, extra:, pipeline: @pipeline)
    end

    # This Context rebuilt around `pipeline` -- the mirror of #with_model, and
    # how a per-turn source ({Agent::PipelineSource}) swaps the render strategy
    # without rebuilding the Context from parts it does not own.
    #
    # `model: @model` is the STORED slot, deliberately not the `#model` reader:
    # the reader unwraps to `.current`, so writing it here would flatten a live
    # {ModelSwitch} to whatever it held at copy time and silently break `/model`
    # from the next turn on. #with_model has the same constraint but never faces
    # it -- `model:` there resolves to its own shadowed parameter.
    #
    # `@requires` re-derives from the NEW pipeline in the constructor, by
    # design: a declared capability that outlived the strategy that needed it is
    # exactly the drift #pipeline_for exists to prevent.
    def with_pipeline(pipeline)
      self.class.new(model: @model, max_tokens:, system:, stream:, extra:, pipeline:)
    end

    # @return [Lain::Request] deterministic for identical inputs
    #
    # The message-list pipeline is itself a Context combinator composition
    # (3c-2): Reminder injects the Workspace tail, then CacheBreakpoints
    # marks the result. Composing via `>>` here is the same seam a caller
    # reaches for directly when building a custom pipeline (Prune, Compact,
    # or a Reminder/CacheBreakpoints reordering) -- #render's default
    # strategy is one point in that same space, not a parallel
    # implementation of it.
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

    # The render pipeline in effect for this workspace. With no injected
    # collaborator this is exactly today's `self.class.pipeline(workspace)`, so
    # a default Context (and any subclass overriding `self.pipeline`) is
    # unchanged. An injected Combinator is used directly; an injected
    # `->(workspace)` provider (no `#requires`, unlike a combinator) is asked for
    # a combinator per render -- the same pure call the class default makes.
    # #render and #requires both route through here, which is what keeps a
    # declared capability from drifting from the behavior it names.
    #
    # PUBLIC because #with_pipeline is a write that needs a matching read: a
    # per-turn source ({Agent::PipelineSource}) that WRAPS the render strategy --
    # compaction composes Compact ahead of it -- must first ask what the strategy
    # would otherwise have been. Read it, wrap it, hand the result back through
    # #with_pipeline.
    #
    # `self.class.pipeline(workspace)` is NOT a substitute for that read: it
    # silently discards an injected `@pipeline` and rebuilds the class default,
    # so an Identity-carrying Context answers with the base pipeline. Neither is
    # a hand-rolled stand-in -- a base that omits {Reminder} drops the Session's
    # live reminders from every wrapped render, and NOTHING catches it: the
    # composed `#requires` is a union, so it still reports `[:prompt_caching]`.
    def pipeline_for(workspace)
      return self.class.pipeline(workspace) if @pipeline.nil?

      @pipeline.respond_to?(:requires) ? @pipeline : @pipeline.call(workspace)
    end

    private

    # Hoisted, because a `[].freeze` literal allocates a fresh Array per read
    # and this one is read on every turn of a compacting session.
    NO_MESSAGES = [].freeze
    private_constant :NO_MESSAGES

    # The Timeline as the message list a Provider sees. {Compaction::Head} and
    # {Compaction::Derivation.projected} project the same two keys the same
    # way, deliberately: a head must be measured, and a derived chain
    # validated, in the very bytes this line produces.
    #
    # NOT MADE AT ALL for a pipeline whose first stage substitutes its own
    # list. That walk is O(n) in history length and its result is then
    # discarded unread on every turn a compaction renders through a derived
    # chain -- and since nothing downstream of a substituting stage can
    # observe the argument, skipping it cannot move a byte. `#render` stays
    # the pure function it was: the same (timeline, toolset, workspace) still
    # renders the same Request, and the pipeline is asked, never told.
    def projected(timeline, pipeline)
      return NO_MESSAGES if substituting?(pipeline)

      timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }
    end

    # `respond_to?` and not a bare send, because the injected-pipeline duck is
    # PUBLIC and older than this question: an object answering `#call` and
    # `#requires` is a pipeline -- that pair is what `#pipeline_for` tests, what
    # {Compaction::Scheduler#pipeline} and {Plan::LinearRewrite} document, and
    # what a bench user writing their own strategy implements. Widening the duck
    # in place would have broken every one of them with a `NoMethodError` from
    # inside `#render`, which is a poor trade for a projection nobody was going
    # to skip anyway.
    #
    # Silence therefore means "reads its messages": the projection is made, and
    # a stage only opts OUT by saying so. The saving belongs to the stage that
    # claims it.
    def substituting?(pipeline)
      pipeline.respond_to?(:reads_messages?) && !pipeline.reads_messages?
    end

    # The system prompt in Anthropic's block form, normalized ONCE. A String
    # prompt becomes a single text block; a caller who already passed blocks is
    # passed through. The `#render` pipeline never asks the system's type again
    # after this line -- the marker logic below is a pure list transform. The
    # one remaining type check is the honest price of a public input that
    # accepts either shape, confined here rather than smeared through render.
    #
    # It lives in render, NOT the constructor, on purpose: `#system` keeps the
    # shape it was given, which is what Bench::Session serializes verbatim into
    # its header. Normalizing the stored value would silently rewrite that
    # header (String -> blocks) and the session round trip with it.
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
