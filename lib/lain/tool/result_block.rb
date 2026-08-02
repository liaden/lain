# frozen_string_literal: true

require "json"

module Lain
  class Tool
    # A read-only view over ONE tool_result block -- the string-keyed
    # `{ "type" => "tool_result", "tool_use_id" =>, "content" =>, "is_error" => }`
    # shape that IS the wire primitive. Same rule its read-side twin
    # {Response::ToolUse} states: `Canonical.normalize` rebuilds plain hashes and
    # raises on anything that is not one, so the hash stays the value and this is
    # only a lens onto it -- nothing here reaches the Store, and a committed
    # digest cannot move because a caller wrapped.
    #
    # {.of} is the write side that {Response::ToolUse} has no need of: the ONE
    # place a {Result} becomes a wire block. Two correctness gates are
    # constructor invariants here rather than four lines in a dispatcher --
    # gate 4 (the block names the tool_use it answers) because {.of} refuses to
    # build without an id, and gate 3 (a failed tool is reported, never dropped)
    # because `is_error` is read off the {Result} and is never inferred from the
    # shape of the content.
    #
    # **{.of} is the SOLE writer of a string-keyed tool_result block in `lib/`,
    # reached only from `ToolRunner#delivery`.** That fact is what every named
    # reader's `fetch` rests on, so a second writer must either come through
    # here or retire the readers. `is_error` is OPTIONAL on Anthropic's wire and
    # is not optional on ours: a tool_result that reached a reader was built
    # here, with all four keys, so a missing one is a builder bug rather than a
    # shape to tolerate -- and readers may raise on it instead of reading a
    # failure as a success. The pre-T8 builder wrote all four keys too, so
    # Stores, journals, and fixtures recorded before this class existed read
    # exactly the same way.
    class ResultBlock
      # How much of a malformed block {#field} quotes. A `read_file`-shaped
      # tool_result carries a whole file in `content`, so an unbounded `inspect`
      # puts a megabyte of it in an exception message and from there into
      # whatever logs it. The raised KeyError sets `receiver:`, so a rescue site
      # that wants the WHOLE block still has it; only the human-readable half is
      # capped.
      INSPECT_LIMIT = 300

      # The four keys are written in the order the wire documents them. That
      # order is a CONVENTION this one builder keeps, not an invariant anything
      # downstream can observe: `Canonical` sorts keys for the digest, and the
      # only NDJSON line that carries a tool_result (`request_sent`) has already
      # been through `normalize`, so it is key-sorted too. The spec pins the
      # order so the sole builder cannot drift away from the documented shape --
      # it does not pin any byte a replay diffs.
      #
      # The hash is FROZEN because this is the last place the block is a value
      # rather than a record. `ToolRunner` hands it to the observer seam after
      # #result_block and before `Timeline#commit`, so an observer writing
      # `block["content"]` would rewrite the committed experiment record after
      # gates 3 and 4 had been enforced -- measured, not feared. Frozen, that
      # write raises where it happens. This does NOT make the lens
      # `Ractor.shareable?`: the freeze is shallow and a {Result}'s content
      # String is mutable. Shareability arrives after `Canonical.normalize`
      # deep-freezes the block, which is the shape {.wrap} sees.
      def self.of(result, tool_use_id:)
        refuse_unpaired(tool_use_id)

        new({
          "type" => "tool_result",
          "tool_use_id" => tool_use_id,
          "content" => result.content,
          "is_error" => result.error?
        }.freeze)
      end

      # Re-lenses a block that has already been built (or has come back through
      # `Canonical.normalize`) so a reader gets the named accessors. Idempotent,
      # and `new` is private below because `new(wrap(hash))` nests a lens and
      # {#to_h} would then answer a lens where every caller -- and `Canonical` --
      # has been promised a Hash.
      #
      # A non-Hash subject is refused here rather than left to surface three
      # different ways downstream. The class is the whole diagnosis, so the
      # message quotes no value and cannot itself grow unbounded.
      def self.wrap(block)
        return block if block.is_a?(self)
        raise ArgumentError, "a tool_result lens wraps a Hash block, got #{block.class}" unless block.is_a?(Hash)

        new(block)
      end

      # Gate 4 is a *pairing*, so an id that cannot pair is refused where the
      # block is built. Most of the shapes this rejects are already unreachable
      # from a real turn, which is the point: `Response#initialize` normalizes,
      # and `Canonical` maps Symbol to String, so no Symbol survives to
      # {Response::ToolUse#id}; a block with no id raises `KeyError` at that
      # lens's `fetch` before it ever reaches here; both providers mint Strings.
      # The one shape genuinely foreclosed is a NUMERIC id, which Anthropic's
      # wire rejects anyway -- an ArgumentError at the sole builder beats a 400.
      #
      # The message names the class and never the value: an id is
      # model-supplied text, and an exception message is the wrong place for it.
      # The empty String is the exception that proves it -- "got String" names
      # the RIGHT class and so reads as a contradiction of the rule it follows.
      def self.refuse_unpaired(tool_use_id)
        return if tool_use_id.is_a?(String) && !tool_use_id.empty?

        got = tool_use_id.is_a?(String) ? "an empty String" : tool_use_id.class.to_s
        raise ArgumentError, "a tool_result names the tool_use it answers with a non-empty String id, got #{got}"
      end
      private_class_method :refuse_unpaired

      def initialize(hash)
        @hash = hash
        freeze
      end
      private_class_method :new

      # The ORIGINAL hash, by identity (`equal?`, not a defensive copy) -- the
      # same rule {Context::MessageEnvelope#to_h} keeps, for the same reason.
      def to_h = @hash

      # Delegated, never inherited: without this a lens serializes as the `to_s`
      # of its own object header -- VALID JSON carrying a debug string, which the
      # NDJSON Journal accepts in silence where a raise would be caught. This
      # lens sits one hop from the Journal's `JSON.generate`, so the delegation
      # is what keeps a wrapped block honest there.
      def to_json(...) = @hash.to_json(...)

      def fetch(...) = @hash.fetch(...)

      # The compatibility ramp for consumers still reading raw keys off the
      # block; the named readers below are the intended surface.
      def [](key) = @hash[key]

      def tool_use_id = field("tool_use_id")

      def content = field("content")

      def error? = field("is_error")

      private

      # A `fetch`, not a `[]`: a tool_result missing one of its four keys is a
      # builder bug, and it surfaces here -- naming both the key and the block --
      # rather than as a nil that unpairs a result or reports a failure as a
      # success.
      def field(key)
        @hash.fetch(key) do
          raise KeyError.new("tool_result block has no #{key.inspect}: #{brief}", receiver: @hash, key:)
        end
      end

      def brief
        text = @hash.inspect
        text.length <= INSPECT_LIMIT ? text : "#{text[0, INSPECT_LIMIT]}... (#{text.length} chars)"
      end
    end
  end
end
