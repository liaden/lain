# frozen_string_literal: true

module Lain
  class Context
    # A read-only view over a single canonical message hash -- the string-keyed
    # `{ "role" => ..., "content" => [...] }` shape that IS the pipeline
    # primitive. `Canonical`, digests, and render purity all depend on that
    # shape, so the hash stays the value; this is only a lens onto it. A
    # combinator wraps at its body's boundary and unwraps via {#to_h}; the
    # envelope answers questions, never rewrites, so equality and digest keep
    # routing through `Canonical` on the raw hash, never through here.
    #
    # Same wrap/`to_h` idiom as {Middleware::Env} -- one boundary shape for both
    # whole values: idempotent {.wrap}, and {#to_h} hands back the ORIGINAL
    # object so identity (and therefore the digest) is stable by construction.
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

      # Provenance is the block's structural marker (R.2, resolved), not its
      # visible text -- mirrors how AnthropicEncoding keys a cache breakpoint
      # off "cache" rather than off any wire-shaped hint. A genuine user
      # message that happens to start with the literal "<workspace>" tag
      # carries no WORKSPACE_MARKER and is real query material, not swallowed.
      def workspace_tagged?(block)
        block[Workspace::WORKSPACE_MARKER] == true
      end

      private

      def content = @hash["content"]
    end
  end
end
