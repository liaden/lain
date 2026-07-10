# frozen_string_literal: true

require_relative "canonical"
require_relative "error"

module Lain
  # Everything that goes to a model, expressed in Lain's own vocabulary.
  #
  # This is the anti-corruption layer. A Provider translates a Request into its
  # own wire payload; nothing Anthropic-shaped leaks in here. That is what makes
  # dry replay (re-render a recorded Timeline under a different Context and diff
  # the bytes, at zero API cost) and honest cross-provider comparison possible at
  # all.
  #
  # Prompt-cache breakpoints are expressed neutrally: a content block or system
  # block may carry `"cache" => true`, and it is the Provider's job to render
  # that as `cache_control: {type: "ephemeral"}` or to declare, via
  # `Provider#capabilities`, that it cannot.
  #
  # A Request is frozen and content-addressed. Two Contexts that render to the
  # same #digest will hit the same prompt cache; two that do not, will not. The
  # bench leans on this directly.
  Request = Data.define(:model, :system, :tools, :messages, :max_tokens, :stream, :reasoning, :extra) do
    def initialize(model:, messages:, max_tokens:, system: nil, tools: [], stream: true, reasoning: nil, extra: {})
      super(
        model: -model.to_s,
        system: system && Canonical.normalize(system),
        tools: Canonical.normalize(tools),
        messages: Canonical.normalize(messages),
        max_tokens: Integer(max_tokens),
        stream: !stream.nil? && stream != false,
        reasoning: reasoning && Canonical.normalize(reasoning),
        extra: Canonical.normalize(extra)
      )
    end

    # The bytes that matter for cache identity: `stream` and `extra` are transport
    # concerns and deliberately excluded, so toggling streaming does not read as a
    # different prompt.
    def cache_payload
      { "model" => model, "tools" => tools, "system" => system, "messages" => messages,
        "max_tokens" => max_tokens, "reasoning" => reasoning }
    end

    def digest
      Canonical.digest(cache_payload)
    end

    # Anthropic's cache is a prefix match over tools -> system -> messages. Any
    # byte change invalidates everything after it, so the prefix is what a
    # cache-break search bisects.
    def cache_prefix
      { "tools" => tools, "system" => system }
    end

    def to_s
      "#<Lain::Request #{model} msgs=#{messages.size} tools=#{tools.size} #{digest[0, 19]}...>"
    end
    alias_method :inspect, :to_s
  end
end
