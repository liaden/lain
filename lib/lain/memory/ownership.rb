# frozen_string_literal: true

module Lain
  module Memory
    # Whose items a writer may replace: a clerk writes out of chat with nobody to
    # confirm it, so the one thing it cannot replace is an id the chat holds.
    # One rule, asked twice -- of the view the writer sees, and of the store's
    # head under its lock -- because the view is a snapshot and a chat may have
    # written since.
    module Ownership
      class Refused < Error; end

      # @param item [Item] the write
      # @param held [Item, nil] what the id currently resolves to
      # @raise [Refused]
      def self.permit!(item, held)
        return if held.nil? || item.author.chat? || !held.author.chat?

        raise Refused, "memory item #{item.id.inspect} belongs to the human and is not yours to overwrite; " \
                       "write your finding under a new id instead"
      end
    end
  end
end
