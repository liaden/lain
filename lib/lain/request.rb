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
    # MORE THAN ONE cache marker inside a single message. A message names one
    # position on the wire, so two marked blocks within it have no single
    # place to hang a chain entry, and this fails loudly rather than guess
    # which one the prefix runs through. A marker on a NON-final block is NOT
    # ambiguous: `cache_control` covers bytes through its own block (per-block,
    # not per-message), so a single marker followed only by unmarked trailing
    # blocks -- exactly the Recall/workspace-tail pattern -- has an
    # unambiguous cut point and is handled, not raised.
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
    #
    # The cut is BLOCK-granular, matching what `cache_control` actually covers
    # on the wire: bytes through the marked block, not through the whole
    # message. So a marker on a non-final block yields a digest over the
    # content UP TO AND INCLUDING that block, invariant to any unmarked blocks
    # appended after it -- which is what lets Recall append a `<recall>` block
    # to the tail without the entry reading as a rewrite of the cached prefix.
    def prefix_digests
      marked_cuts.map { |position, block_index| [position, digest_through(position, block_index)] }
    end

    private

    # `[position, block_index]` per marker, ascending by position:
    # SYSTEM_PREFIX (-1, block_index nil) sorts before every message index,
    # and messages are walked in order. `block_index` is the marked block
    # within that message -- the point the cut slices at.
    def marked_cuts
      cuts = []
      cuts << [SYSTEM_PREFIX, nil] if system_marked?
      messages.each_index do |index|
        block_index = marked_block(messages[index])
        cuts << [index, block_index] unless block_index.nil?
      end
      cuts
    end

    def system_marked?
      system.is_a?(Array) && system.any? { |block| cache_marker?(block) }
    end

    # The index of the single marked block in a message, or nil when none is
    # marked. More than one marked block is genuinely ambiguous -- a message
    # names one position on the wire -- so that raises (see
    # AmbiguousMarkerPosition). A single marker anywhere (final or not) is a
    # clean cut point.
    def marked_block(message)
      content = message["content"]
      return nil unless content.is_a?(Array) && !content.empty?

      marked = content.each_index.select { |index| cache_marker?(content[index]) }
      return nil if marked.empty?

      unless marked.size == 1
        raise AmbiguousMarkerPosition,
              "cache marker on #{marked.size} blocks (at #{marked.inspect}) of one message; " \
              "at most one block per message may carry one"
      end

      marked.first
    end

    def cache_marker?(block)
      block.is_a?(Hash) && block["cache"] == true
    end

    # Tools lead system lead messages on the wire and enter every entry
    # unconditionally; the messages slice is what varies. At SYSTEM_PREFIX the
    # slice is empty; at a message position it is every preceding message plus
    # that message truncated through its marked block.
    def digest_through(position, block_index)
      Canonical.digest(
        "model" => model,
        "tools" => strip_cache_markers(tools),
        "system" => strip_cache_markers(system),
        "messages" => strip_cache_markers(messages_through(position, block_index))
      )
    end

    def messages_through(position, block_index)
      return [] if position == SYSTEM_PREFIX

      messages.first(position) + [truncate_through(messages[position], block_index)]
    end

    # The marked message, keeping only its content up to and including the
    # marked block -- the bytes `cache_control` covers, invariant to any
    # unmarked blocks appended after it.
    def truncate_through(message, block_index)
      { "role" => message["role"], "content" => message["content"].first(block_index + 1) }
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
