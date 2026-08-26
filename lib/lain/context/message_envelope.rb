# frozen_string_literal: true

require "json"

module Lain
  class Context
    # A read-only view over a single canonical message hash -- the string-keyed
    # `{ "role" => ..., "content" => [...] }` shape that IS the pipeline
    # primitive. `Canonical`, digests, and render purity all depend on that
    # shape, so the hash stays the value and this is only a lens onto it: the
    # envelope answers questions and never rewrites, so equality and digest keep
    # routing through `Canonical` on the raw hash.
    #
    # {Middleware::Env}'s wrap/`to_h` idiom -- idempotent {.wrap}, and {#to_h}
    # hands back the ORIGINAL object so identity, and therefore the digest, is
    # stable by construction.
    class MessageEnvelope
      # Idempotent: an envelope passes through untouched, a hash is adopted.
      def self.wrap(message) = message.is_a?(self) ? message : new(message)

      def initialize(hash)
        @hash = hash
        freeze
      end

      # The ORIGINAL hash, by identity (`equal?`, not a defensive copy): a dup
      # would give a value that digests the same yet is not the same object,
      # which is exactly the drift this whole-value shape exists to prevent.
      def to_h = @hash

      # Delegated, never inherited: an un-delegated lens serializes as the
      # `to_s` of its own object header -- VALID JSON carrying a debug string,
      # which the NDJSON Journal accepts in silence where a raise would be
      # caught. {Response::ToolUse#to_json} states it at length.
      def to_json(...) = @hash.to_json(...)

      def user? = @hash["role"] == "user"

      # The text blocks that are genuine query material: real text, minus the
      # <workspace> tail Reminder injects and any non-text block.
      def real_text_blocks
        content.select { |block| block["type"] == "text" && !workspace_tagged?(block) }
      end

      # The joined real text, or nil when there is none -- so a tool-result or
      # bare-workspace message yields nil and a query walk steps further back.
      def query_text
        texts = real_text_blocks.map { |block| block["text"] }
        texts.join("\n") unless texts.empty?
      end

      # Provenance is the block's structural marker, not its visible text --
      # the way AnthropicEncoding keys a cache breakpoint off "cache" rather
      # than off any wire-shaped hint. A genuine user message that happens to
      # start with the literal "<workspace>" tag carries no WORKSPACE_MARKER and
      # is real query material, not swallowed.
      def workspace_tagged?(block)
        block[Workspace::WORKSPACE_MARKER] == true
      end

      private

      def content = @hash["content"]
    end
  end
end
