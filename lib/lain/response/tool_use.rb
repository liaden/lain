# frozen_string_literal: true

require "json"

module Lain
  class Response
    # A read-only view over ONE tool_use block -- the string-keyed
    # `{ "type" => "tool_use", "id" =>, "name" =>, "input" => }` shape that IS
    # the wire primitive. `Canonical.normalize` rebuilds plain hashes and
    # raises on anything that is not one, so the hash stays the value and this
    # is only a lens onto it: nothing here ever reaches the Store, and a
    # committed digest cannot move because a caller wrapped.
    #
    # Same wrap/`to_h` idiom as {Middleware::Env} and {Context::MessageEnvelope}:
    # idempotent {.wrap}, a Hash-duck surface so existing `["name"]` readers
    # keep working, and {#to_h} handing back the ORIGINAL object.
    #
    # The three named readers are `fetch`es. A tool_use block missing `id`,
    # `name`, or `input` is a Provider bug, and it surfaces here -- at the first
    # read, naming both the key and the block -- rather than as a nil that
    # dispatches an unnamed tool.
    class ToolUse
      # How much of a malformed block {#field} quotes. A `write_file`-shaped
      # tool_use carries whole file contents in `input`, so an unbounded
      # `inspect` puts a megabyte of it in an exception message and from there
      # into whatever logs it. The raised KeyError sets `receiver:`, so a rescue
      # site that wants the WHOLE block still has it; only the human-readable
      # half is capped.
      INSPECT_LIMIT = 300

      # The only door, so idempotence is total rather than conventional: `new`
      # is private below because `new(wrap(hash))` nests a lens, and {#to_h}
      # would then answer a lens where every caller -- and `Canonical` -- has
      # been promised a Hash.
      #
      # A non-Hash subject is refused here rather than left to surface three
      # different ways downstream (`wrap(nil).to_h` answers nil,
      # `wrap(:sym)["id"]` answers nil through `Symbol#[]`'s substring search,
      # `wrap(nil).id` raises NoMethodError). The class is the whole diagnosis,
      # so the message quotes no value and cannot itself grow unbounded.
      def self.wrap(block)
        return block if block.is_a?(self)
        raise ArgumentError, "a tool_use lens wraps a Hash block, got #{block.class}" unless block.is_a?(Hash)

        new(block)
      end

      def initialize(hash)
        @hash = hash
        freeze
      end
      private_class_method :new

      # The ORIGINAL hash, by identity (`equal?`, not a defensive copy) -- the
      # same rule {Context::MessageEnvelope#to_h} keeps, for the same reason.
      def to_h = @hash

      # Delegated, never inherited: without this a lens serializes as the
      # `to_s` of its own object header -- VALID JSON carrying a debug string,
      # which the NDJSON Journal accepts in silence where a raise would be
      # caught. The lens is a view of the hash, and {#to_h} already hands that
      # hash back by identity, so its JSON is the hash's JSON.
      def to_json(...) = @hash.to_json(...)

      def fetch(...) = @hash.fetch(...)

      # The compatibility ramp for consumers not yet migrated to the named
      # readers -- `spec/support/ollama_wire.rb:57-58` is the one that survives
      # in tree. The named readers are the intended surface; migrating the
      # remaining raw-key readers is T9's job, not this ramp's blessing.
      def [](key) = @hash[key]

      def id = field("id")

      def name = field("name")

      # Already a parsed Hash: the Provider owns that guarantee, including on
      # Anthropic's streaming path where the wire hands `input` back as a raw
      # JSON String (see {Response#tool_uses}).
      def input = field("input")

      private

      def field(key)
        @hash.fetch(key) do
          raise KeyError.new("tool_use block has no #{key.inspect}: #{brief}", receiver: @hash, key:)
        end
      end

      def brief
        text = @hash.inspect
        text.length <= INSPECT_LIMIT ? text : "#{text[0, INSPECT_LIMIT]}... (#{text.length} chars)"
      end
    end
  end
end
