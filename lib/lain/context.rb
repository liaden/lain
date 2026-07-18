# frozen_string_literal: true

require_relative "context/base"
require_relative "context/protected_patterns"
require_relative "context/cache_breakpoints"
require_relative "context/message_envelope"
require_relative "context/tail_injection"
require_relative "context/reminder"
require_relative "context/prune"
require_relative "context/compact"
require_relative "context/dedupe_tool_calls"
require_relative "context/purge_failed_inputs"
require_relative "context/recall"
require_relative "context/mailbox"

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

    attr_reader :system, :model, :max_tokens, :stream, :extra

    # `extra` carries provider-specific sampler params (temperature, seed,
    # num_ctx). It rides through to Request#extra, which Request excludes from
    # cache_payload/digest by design -- so threading it here keeps #render pure
    # (identical inputs, identical bytes) WITHOUT letting a temperature change
    # read as a different prompt. Normalized (and thus deeply frozen) at
    # construction so the frozen Context holds no mutable reference.
    def initialize(model:, max_tokens:, system: nil, stream: true, extra: {})
      @model = -model.to_s
      @max_tokens = Integer(max_tokens)
      @system = system && Canonical.normalize(system)
      @stream = stream
      @extra = Canonical.normalize(extra)
      freeze
    end

    def requires = REQUIRES

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
      messages = timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }

      Request.new(
        model:,
        system: cache_marked(system_blocks),
        tools: toolset.to_schema,
        messages: self.class.pipeline(workspace).call(messages),
        max_tokens:,
        stream:,
        extra:
      )
    end

    private

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
