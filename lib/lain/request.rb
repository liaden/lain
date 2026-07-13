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

  # Reopened rather than folded into the `Data.define` block above: a `class`
  # keyword or bare constant written INSIDE that block is scoped to its
  # lexical position -- this file, i.e. `Lain` -- not to the Data-defined
  # class, however natural `Request::AmbiguousMarkerPosition` looks from the
  # call site. Reopening puts `AmbiguousMarkerPosition` and `SYSTEM_PREFIX`
  # where they read, and where every method below can find them by ordinary
  # lexical lookup.
  class Request
    # A marker sat on a content block that is not its message's last block.
    # The default pipeline (`Context::CacheBreakpoints`) only ever marks a
    # message's final block, so this should never fire against Lain's own
    # renderer -- it exists to fail loudly, rather than guess a position, the
    # moment a foreign pipeline breaks that assumption.
    class AmbiguousMarkerPosition < Error; end

    # The sentinel position for a marker that sits in `system`: system
    # precedes every message on the wire, so its chain entry always reads as
    # "nothing from messages yet". Chosen so `messages.first(position + 1)`
    # (see #digest_through) generalizes to the empty array at position -1
    # without the negative-range footgun `messages[0..-1]` would be (that
    # slice means "the whole array", not "nothing").
    SYSTEM_PREFIX = -1

    # A digest CHAIN, one entry per neutral cache marker, in ascending
    # position order: `[[position, digest], ...]`. This mirrors the
    # Timeline's Merkle structure over the breakpoint-partitioned prompt
    # (CE-2), so a bench projection can find where a rewrite happened the
    # same way `diverge_at` finds it in the Timeline.
    #
    # The chain must survive MARKER MOVEMENT: `CacheBreakpoints` always marks
    # a message's last block, and its cap slides which messages get marked
    # as a session grows, so a chain sampled over marker-BEARING bytes would
    # read every append as a rewrite. Each entry is instead the digest of the
    # marker-STRIPPED prefix through that position -- the same content
    # prefix hashes identically whether or not a marker sits on it today.
    # `position` is a message index, or {SYSTEM_PREFIX} for a marker in
    # `system` (which precedes every message on the wire). `tools` carries no
    # position of its own -- it enters every entry unconditionally, alongside
    # `model`, as the fixed part of the prefix.
    def prefix_digests
      marker_positions.map { |position| [position, digest_through(position)] }
    end

    private

    # Ascending by construction: SYSTEM_PREFIX (-1) sorts before every
    # message index, and messages are walked in order.
    def marker_positions
      positions = []
      positions << SYSTEM_PREFIX if system_marked?
      messages.each_index { |index| positions << index if message_marked?(messages[index]) }
      positions
    end

    def system_marked?
      system.is_a?(Array) && system.any? { |block| cache_marker?(block) }
    end

    # A marker is only ever unambiguous on a message's LAST content block --
    # that is the only position the message's own index can name. A marker
    # anywhere else means some other pipeline placed it, and this method
    # raises rather than invent a rule for that case (see
    # AmbiguousMarkerPosition).
    def message_marked?(message)
      content = message["content"]
      return false unless content.is_a?(Array) && !content.empty?

      marked = content.each_index.select { |index| cache_marker?(content[index]) }
      return false if marked.empty?

      unless marked == [content.size - 1]
        raise AmbiguousMarkerPosition,
              "cache marker at block(s) #{marked.inspect} of #{content.size}, " \
              "expected only the last block to carry one"
      end

      true
    end

    def cache_marker?(block)
      block.is_a?(Hash) && block["cache"] == true
    end

    # Tools lead system lead messages on the wire and enter every entry
    # unconditionally; `messages.first(position + 1)` is what varies, and
    # generalizes to the empty array at SYSTEM_PREFIX (see its comment).
    def digest_through(position)
      Canonical.digest(
        "model" => model,
        "tools" => strip_cache_markers(tools),
        "system" => strip_cache_markers(system),
        "messages" => strip_cache_markers(messages.first(position + 1))
      )
    end

    def strip_cache_markers(value)
      case value
      when Hash then value.except("cache").transform_values { |v| strip_cache_markers(v) }
      when Array then value.map { |v| strip_cache_markers(v) }
      else value
      end
    end
  end
end
