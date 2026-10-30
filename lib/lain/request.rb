# frozen_string_literal: true

require "json"

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
  #
  # The `chain:` a caller passes is a memo of earlier walks ({Request::PrefixChain}),
  # never a member: the digest is the same whichever chain built it.
  Request = Data.define(:model, :system, :tools, :messages, :max_tokens, :stream, :reasoning, :extra, :effort) do
    def initialize(model:, messages:, max_tokens:, system: nil, tools: [], stream: true, reasoning: nil, extra: {},
                   effort: nil, chain: Request::PrefixChain::NONE)
      raise ArgumentError, "messages must be an Array, got #{messages.class}" unless messages.is_a?(Array)

      ceiling = Integer(max_tokens)
      # A non-positive ceiling is not a small ceiling. Ollama reads
      # `num_predict` -1 as "generate until the model stops" and -2 as "fill
      # the context", so such a Request asks for the OPPOSITE of the bound it
      # states, and 0 asks for no tokens at all. {CLI::Backend::Ceiling}
      # refuses these at the flag, so what arrives here is a ceiling nobody
      # typed: a bench arm, an Oracle, a hand-assembled Request -- and the one
      # worth naming, a RECORDED SESSION HEADER, which `--resume` reads
      # `max_tokens` back out of as data through {Bench::Session::Loader}.
      # That path is the one that escapes, because {Context} accepts the value:
      # the resume succeeds and this raise lands at the first #render instead,
      # mid-turn, where no rescue watching for a {Lain::Error} sees it. Raised
      # rather than clamped all the same -- a bound corrected in silence is a
      # bound nobody can see.
      raise ArgumentError, "max_tokens must be positive, got #{ceiling}" unless ceiling.positive?

      identity = { model: -model.to_s, system: system && Canonical.normalize(system),
                   tools: Canonical.normalize(tools), messages: Canonical.normalize(messages),
                   max_tokens: ceiling, reasoning: reasoning && Canonical.normalize(reasoning),
                   effort: effort && -effort.to_s }
      # Digested once, before `super` freezes the instance: a model call asks
      # for it five or six times (the retry guard, the stream frame, the
      # journal, the budget).
      @digest = self.class.digest_through(chain, **identity)
      super(**identity, stream: !stream.nil? && stream != false, extra: Canonical.normalize(extra))
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
    #
    # `effort` is keyed only when set, so a request without one journals the payload it always did.
    def self.cache_payload_of(model:, system:, tools:, messages:, max_tokens:, reasoning:, effort: nil)
      payload = { "max_tokens" => max_tokens, "messages" => messages, "model" => model,
                  "reasoning" => reasoning, "system" => system, "tools" => tools }
      payload = { "effort" => effort }.merge(payload) if effort
      payload.freeze
    end

    def cache_payload
      self.class.cache_payload_of(**to_h.except(:stream, :extra))
    end

    # The prefix chain's last state, combined with what the states leave out:
    # `max_tokens`, `reasoning`, `effort`, and every marker the walk stripped,
    # so 2 requests differing only there still differ. A warm chain rolls only
    # the messages it has not seen.
    #
    # @return [String]
    attr_reader :digest

    # @return [String] see {#digest}, walked through a chain answering `#seed` and `#entry`
    def self.digest_through(chain, model:, system:, tools:, messages:, max_tokens:, reasoning:, effort:)
      seed = chain.seed(model, tools, system)
      markers = seed.markers.dup
      state = seed.state
      # A local rather than `inject`: its destructured pair is an allocation per
      # message, a third of a warm 10,000-message walk.
      messages.each_with_index do |message, index|
        entry = chain.entry(index, message, state)
        state = entry.state
        entry.markers.each { |path, key, value| markers << [["messages", index, *path], key, value] }
      end
      # Every part is canonical already, so dumping it again through Canonical would only re-walk it.
      Canonical.digest_bytes(JSON.generate([state, max_tokens, reasoning, effort, markers]))
    end

    # Anthropic's cache is a prefix match over tools -> system -> messages. Any
    # byte change invalidates everything after it, so the prefix is what a
    # cache-break search bisects.
    def cache_prefix
      { "tools" => tools, "system" => system }
    end

    # The human-facing projection; inspect keeps the class-tagged debug form.
    def to_s
      "#{model} msgs=#{messages.size} tools=#{tools.size} #{Canonical.abbreviate(digest)}..."
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

    # Journaled alongside the chain (see {Telemetry::RequestSent}). Format 2 is the
    # rolling chain below; the retired format 1 digested the FULL stripped prefix per
    # marker. Two formats' digests never agree on a shared position, which is why the
    # version must ride with the chain: {Bench::Rewrites} reads this format only and
    # refuses any other rather than misread a change of format as a rewrite.
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
    #
    # A caller that walks the same growing conversation turn after turn passes
    # its own {PrefixChain}, so each walk digests only the messages it has not
    # seen; the result is the same either way.
    #
    # @param chain [#seed, #entry] the states of an earlier walk; {PrefixChain::NONE} remembers nothing
    def prefix_digests(chain: PrefixChain::NONE)
      cuts = marked_cuts
      cuts.empty? ? [] : rolled_entries(cuts.to_h, chain)
    end

    # Neither neutral marker is a wire field, and both move for reasons that are
    # not rewrites: a "cache" breakpoint slides across messages as a session grows,
    # and the "workspace" tail (Workspace::WORKSPACE_MARKER) is re-rendered fresh
    # every turn. The recap marker is kept: it is on every recap block whenever one
    # is rendered, so it never moves and prefix digests stay stable.
    #
    # @param value [Object] a message, a block, or any part of one
    # @return [Object] the value with both markers removed at every depth
    def self.strip_cache_markers(value) = without_markers(value).first

    # @param value [Object] a message, a block, or any part of one
    # @return [Array(Object, Array)] the value stripped, and a frozen `[path, key, value]` per marker taken
    def self.without_markers(value)
      removed = []
      [stripped(value, [].freeze, removed), removed.freeze]
    end

    MARKER_KEYS = ["cache", Workspace::WORKSPACE_MARKER].freeze
    private_constant :MARKER_KEYS

    # An unmarked value comes back as itself, already canonical, so the digest
    # that follows does not normalise a copy of it; only the path down to a
    # marker is copied.
    def self.stripped(value, path, removed)
      return value unless marked?(value)

      case value
      when Hash then stripped_hash(value, path, removed)
      when Array then value.each_with_index.map { |inner, index| stripped(inner, [*path, index].freeze, removed) }
      end
    end

    # A hand-filled Hash rather than `except` and `to_h`: this runs per marked
    # message on a replay, and those allocate a pair per key.
    def self.stripped_hash(hash, path, removed)
      kept = {}
      hash.each do |key, inner|
        if MARKER_KEYS.include?(key)
          removed << [path, key, inner].freeze
        else
          kept[key] = stripped(inner, [*path, key].freeze, removed)
        end
      end
      kept
    end

    # @param value [Object] a message, a block, or any part of one
    # @return [Boolean] whether a marker sits anywhere in it
    def self.marked?(value)
      case value
      when Hash then value.any? { |key, inner| MARKER_KEYS.include?(key) || marked?(inner) }
      when Array then value.any? { |inner| marked?(inner) }
      else false
      end
    end
    private_class_method :stripped, :stripped_hash

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
      return nil unless content.is_a?(Array) && content.any? { |block| cache_marker?(block) }

      marked = content.each_index.select { |index| cache_marker?(content[index]) }

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
    # deepest cut -- later messages cannot enter any entry. A message is
    # stripped only when its state is computed or a cut needs it, since a
    # memo hit needs neither.
    def rolled_entries(cuts, chain)
      states = rolled_states(cuts.keys.max + 1, chain)
      cuts.map { |position, block_index| [position, entry_at(position, block_index, states)] }
    end

    def rolled_states(count, chain)
      seed = chain.seed(model, tools, system).state
      messages.first(count).each_with_index.with_object([seed]) do |(message, index), states|
        states << chain.entry(index, message, states.last).state
      end
    end

    # A marker on a message's final block cuts exactly where the rolling state
    # does; a non-final marker digests the truncation `cache_control` actually
    # covers -- the one extra digest in the whole walk.
    def entry_at(position, block_index, states)
      return states[position + 1] if position == SYSTEM_PREFIX || final_block?(messages[position], block_index)

      stripped = self.class.strip_cache_markers(messages[position])
      Canonical.digest([states[position], truncate_through(stripped, block_index)])
    end

    def final_block?(message, block_index)
      block_index == message["content"].size - 1
    end

    # The bytes `cache_control` covers: content through the marked block.
    def truncate_through(message, block_index)
      { "role" => message["role"], "content" => message["content"].first(block_index + 1) }
    end
  end
end
