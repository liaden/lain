# frozen_string_literal: true

module Lain
  class Context
    # Reopens the combinators' shared carrier namespace (see prune.rb) to
    # hold PurgeFailedInputs's construction contract beside the class it
    # guards.
    module Guards
      # `turns` is a window WIDTH, consumed as `messages.first(boundary)` /
      # `messages.last(turns)`. A negative value would silently flip that
      # slicing math -- `messages.last(-1)` raises, but the boundary
      # arithmetic upstream would first hand back a boundary larger than
      # `messages.size`, purging turns the caller meant to protect as
      # "recent." Fail loudly at construction instead, matching
      # Guards::Prune's and Guards::CacheBreakpoints's house style.
      class PurgeFailedInputs < Guard
        attribute :turns
        validates :turns, numericality: { greater_than_or_equal_to: 0, message: "must not be negative, got %<value>s" }
      end
    end

    # Redacts a failed tool_use's `input` once it ages out of the trailing
    # `turns:` window, while leaving its answering tool_result (the error
    # text a later turn may still need to reason about) untouched. A large
    # failed input -- the retry that never needed to be replayed -- is
    # exactly the token cost this earns back; the same slicing idiom
    # {Compact} uses (`messages.first(boundary)` / `messages.last(turns)`)
    # keeps "recent" a plain positional window rather than a second concept.
    #
    # `#requires` is the inherited {Combinator} default: this is a pure
    # rewrite of tool_use blocks already in the message list, so it needs
    # nothing from the Provider.
    class PurgeFailedInputs < Combinator
      def initialize(turns:, protected_patterns: ProtectedPatterns::NONE)
        Guards::PurgeFailedInputs.check!(turns:)

        super()
        @turns = Integer(turns)
        @protected_patterns = protected_patterns
        freeze
      end

      def call(messages)
        return messages if messages.size <= @turns

        boundary = messages.size - @turns
        failed_ids = failed_tool_use_ids(messages)
        aged = messages.first(boundary).map { |message| purge(message, failed_ids) }
        aged + messages.last(@turns)
      end

      private

      # A tool_use's failure is recorded on its ANSWERING tool_result, so the
      # failed set is derived from the whole list -- a tool_use aging out of
      # the window does not imply its tool_result did too.
      def failed_tool_use_ids(messages)
        messages.flat_map { |message| message["content"] }
                .select { |block| block["type"] == "tool_result" && block["is_error"] }
                .map { |block| block["tool_use_id"] }
      end

      # Only assistant messages carry tool_use blocks; a tool_result's
      # message (role "user") is returned as-is, which is precisely how the
      # error text stays put while the input it answers gets redacted.
      #
      # Protection is checked ONCE per message, against the CONTAINING
      # MESSAGE's dump -- the same granularity {Prune} and {Compact} use --
      # rather than per-block: a protected span anywhere in the message
      # (a sibling text block, not just the tool_use's own input) exempts
      # every tool_use the message carries.
      def purge(message, failed_ids)
        return message unless message["role"] == "assistant"

        protected_message = @protected_patterns.protects?(Canonical.dump(message))
        content = message["content"].map { |block| purge_block(block, failed_ids, protected_message) }
        content == message["content"] ? message : message.merge("content" => content)
      end

      def purge_block(block, failed_ids, protected_message)
        redactable = block["type"] == "tool_use" && failed_ids.include?(block["id"]) && !protected_message
        redactable ? block.merge("input" => {}) : block
      end
    end
  end
end
