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

      # Provenance is inferred from the block's leading tag, not a structural
      # field -- an accepted tradeoff pending R.2 (structural provenance in
      # planning/remaining-work.md). Do NOT fix R.2 here: genuine user text that
      # literally starts with the tag is excluded too, and that is the known cost.
      def workspace_tagged?(block)
        block["text"].to_s.start_with?(Workspace::OPENING_TAG)
      end

      private

      def content = @hash["content"]
    end
  end
end
