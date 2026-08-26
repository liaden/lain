# frozen_string_literal: true

module Lain
  # Everything that goes to a model, in Lain's own vocabulary and nothing
  # Anthropic-shaped. That anti-corruption is what makes dry replay (re-render a
  # recorded Timeline under a different Context and diff the bytes, at zero API
  # cost) and honest cross-provider comparison possible at all.
  #
  # Prompt-cache breakpoints are neutral too: a content or system block may carry
  # `"cache" => true`, and it is the Provider's job to render that as
  # `cache_control: {type: "ephemeral"}` or to declare via `Provider#capabilities`
  # that it cannot.
  #
  # Frozen and content-addressed: two Contexts rendering to the same #digest hit
  # the same prompt cache, and two that do not, will not. The bench leans on this.
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
    #
    # Canonical wire form BY CONSTRUCTION -- keys sorted, frozen, every value
    # already normalized by #initialize -- so `Canonical.normalize` of this Hash
    # is a structural no-op and {Telemetry::RequestSent.from} can journal it
    # without a second deep walk of the full message history. The odd-looking
    # alphabetical key order is that contract, and request_spec pins it.
    def cache_payload
      { "max_tokens" => max_tokens, "messages" => messages, "model" => model,
        "reasoning" => reasoning, "system" => system, "tools" => tools }.freeze
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

    # The human-facing projection; inspect keeps the class-tagged debug form.
    def to_s
      "#{model} msgs=#{messages.size} tools=#{tools.size} #{digest[0, 19]}..."
    end
  end

  class Request
    # Reopened rather than folded into the `Data.define` block above: a `class`
    # keyword or bare constant written INSIDE that block is scoped to its lexical
    # position -- this file, i.e. `Lain` -- not to the Data-defined class, however
    # natural `Request::AmbiguousMarkerPosition` looks from the call site.

    include Inspectable

    # MORE THAN ONE cache marker inside a single message. A message names one
    # position on the wire, so two marked blocks have no single place to hang a
    # chain entry, and this fails loudly rather than guess. A marker on a NON-final
    # block is NOT ambiguous: `cache_control` covers bytes through its own block
    # (per-block, not per-message), so a single marker followed only by unmarked
    # trailing blocks -- the Recall/workspace-tail pattern -- has an unambiguous
    # cut point and is handled, not raised.
    class AmbiguousMarkerPosition < Error; end

    # System precedes every message on the wire, so a marker there always reads as
    # "nothing from messages yet". Chosen so `states[position + 1]` (see #entry_at)
    # generalizes to the seed state without the negative-range footgun
    # `messages[0..-1]` would be -- that slice means "the whole array", not
    # "nothing".
    SYSTEM_PREFIX = -1

    # Journaled alongside the chain (see {Telemetry::RequestSent}). Format 1 --
    # implicit in journals recorded before the version existed -- digested the FULL
    # stripped prefix per marker; format 2 is the rolling chain below. The two
    # formats' digests never agree on a shared position, which is why the version
    # must ride with the chain: {Bench::Rewrites} refuses to compare across formats
    # rather than misread the migration as a rewrite.
    PREFIX_CHAIN_VERSION = 2

    # `[[position, digest], ...]`, one entry per neutral cache marker in ascending
    # position order, mirroring the Timeline's Merkle structure over the
    # breakpoint-partitioned prompt so a bench projection finds a rewrite the way
    # `diverge_at` does. `position` is a message index, or {SYSTEM_PREFIX}.
    #
    # A ROLLING hash (format {PREFIX_CHAIN_VERSION}): seed over the fixed prefix,
    # then `state = H(previous state, message)` per message. Linear, where format 1
    # re-digested the full prefix per marker -- O(turns^2) journaling cost per
    # session. Prefix sensitivity survives: a change at message k changes every
    # entry at or beyond k, and only those.
    #
    # The chain must survive MARKER MOVEMENT. `CacheBreakpoints` marks a message's
    # last block and its cap slides which messages get marked as a session grows,
    # so a chain sampled over marker-BEARING bytes would read every append as a
    # rewrite. Every hashed message is therefore marker-STRIPPED.
    #
    # The cut is BLOCK-granular, matching what `cache_control` covers on the wire:
    # bytes through the marked block, not the whole message. A non-final marker
    # therefore yields an entry invariant to unmarked blocks appended after it,
    # which is what lets Recall append a `<recall>` block to the tail without the
    # entry reading as a rewrite. The rolling STATE still folds the whole message
    # in, because later entries cover every earlier message's full wire bytes.
    def prefix_digests
      cuts = marked_cuts
      cuts.empty? ? [] : rolled_entries(cuts.to_h)
    end

    private

    # Ascending by position for free: SYSTEM_PREFIX (-1) sorts before every
    # message index, and messages are walked in order.
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

    # A single marker anywhere in the message, final or not, is a clean cut point;
    # more than one is {AmbiguousMarkerPosition}.
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

    # `states[k]` is the chain state after k messages. The walk stops at the
    # deepest cut -- later messages cannot enter any entry.
    def rolled_entries(cuts)
      stripped = messages.first(cuts.keys.max + 1).map { |message| strip_cache_markers(message) }
      states = stripped.each_with_object([fixed_prefix_digest]) do |message, chain|
        chain << Canonical.digest([chain.last, message])
      end
      cuts.map { |position, block_index| [position, entry_at(position, block_index, stripped, states)] }
    end

    # A marker on a message's final block cuts exactly where the rolling state
    # does; a non-final marker digests the truncation `cache_control` actually
    # covers -- the one extra digest in the whole walk.
    def entry_at(position, block_index, stripped, states)
      return states[position + 1] if position == SYSTEM_PREFIX || final_block?(stripped[position], block_index)

      Canonical.digest([states[position], truncate_through(stripped[position], block_index)])
    end

    def final_block?(message, block_index)
      block_index == message["content"].size - 1
    end

    # Model and tools lead system lead messages on the wire, and none carries a
    # position of its own, so together they seed every entry.
    def fixed_prefix_digest
      Canonical.digest("model" => model, "tools" => strip_cache_markers(tools),
                       "system" => strip_cache_markers(system))
    end

    # The bytes `cache_control` covers: content through the marked block.
    def truncate_through(message, block_index)
      { "role" => message["role"], "content" => message["content"].first(block_index + 1) }
    end

    # Neither neutral marker is a wire field, and both move for reasons that are
    # not rewrites: a "cache" breakpoint slides across messages as a session grows,
    # and the "workspace" tail (Workspace::WORKSPACE_MARKER) is re-rendered fresh
    # every turn.
    def strip_cache_markers(value)
      case value
      when Hash then value.except("cache", Workspace::WORKSPACE_MARKER).transform_values { |v| strip_cache_markers(v) }
      when Array then value.map { |v| strip_cache_markers(v) }
      else value
      end
    end
  end
end
