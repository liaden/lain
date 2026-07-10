# frozen_string_literal: true

require_relative "canonical"
require_relative "error"
require_relative "request"
require_relative "workspace"

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
    # Anthropic looks back a bounded number of content blocks when matching a
    # cache breakpoint. Agentic turns, which pile up tool_use/tool_result pairs,
    # blow past it easily, so intermediate breakpoints are placed well inside the
    # window rather than at its edge.
    CACHE_LOOKBACK_BLOCKS = 20
    BREAKPOINT_EVERY = 15

    # Capabilities this renderer needs. A Provider lacking one degrades (loudly,
    # into the Journal) rather than silently producing a different prompt.
    REQUIRES = %i[prompt_caching].freeze

    attr_reader :system, :model, :max_tokens, :stream

    def initialize(model:, max_tokens:, system: nil, stream: true)
      @model = -model.to_s
      @max_tokens = Integer(max_tokens)
      @system = system && Canonical.normalize(system)
      @stream = stream
      freeze
    end

    def requires
      REQUIRES
    end

    # @return [Lain::Request] deterministic for identical inputs
    def render(timeline:, toolset:, workspace: Workspace.empty)
      messages = timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }
      messages = inject_workspace(messages, workspace)

      Request.new(
        model: model,
        system: cache_marked_system,
        tools: toolset.to_schema,
        messages: mark_cache_breakpoints(messages),
        max_tokens: max_tokens,
        stream: stream
      )
    end

    private

    # Workspace state is SENT, never STORED: it rides at the tail of the last user
    # message rather than being appended to the Timeline. Note the placement --
    # after the last cache breakpoint would be ideal, and since the tail of the
    # final message *is* where the last breakpoint goes, injecting here means the
    # workspace sits inside the uncached suffix. Injecting it into `system`
    # instead would rewrite the cached prefix on every turn.
    def inject_workspace(messages, workspace)
      return messages if workspace.empty? || messages.empty?

      last = messages.last
      return messages unless last["role"] == "user"

      rest = messages[0..-2]
      rest + [{ "role" => "user", "content" => last["content"] + workspace.to_blocks }]
    end

    # Mark the last block of the last message, plus intermediate blocks roughly
    # every BREAKPOINT_EVERY, so a long agentic turn never drifts outside the
    # lookback window. `"cache" => true` is Lain's neutral marker; rendering it as
    # `cache_control` is the Provider's job.
    def mark_cache_breakpoints(messages)
      return messages if messages.empty?

      last_index = messages.size - 1
      blocks_since = 0
      messages.each_with_index.map do |message, index|
        blocks_since += message["content"].size
        breakpoint = index == last_index || blocks_since >= BREAKPOINT_EVERY
        blocks_since = 0 if breakpoint
        breakpoint ? mark_last_block(message) : message
      end
    end

    def mark_last_block(message)
      content = message["content"]
      return message if content.empty?

      marked_tail = content.last.merge("cache" => true)
      { "role" => message["role"], "content" => content[0..-2] + [marked_tail] }
    end

    # Caching the system prompt caches the tools with it, since tools lead the
    # matched prefix.
    def cache_marked_system
      return nil if system.nil?

      blocks = system.is_a?(String) ? [{ "type" => "text", "text" => system }] : system
      return blocks if blocks.empty?

      blocks[0..-2] + [blocks.last.merge("cache" => true)]
    end
  end
end
