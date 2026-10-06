# frozen_string_literal: true

module Lain
  module Memory
    # Whose items a writer may replace: a clerk writes out of chat with nobody to
    # confirm it, so it may replace only what its own spawn wrote. Twin spawns
    # share a digest, so a later pass over the same lineage is the same owner.
    # One rule, asked twice -- of the view the writer sees, and of the store's
    # head under its lock -- because the view is a snapshot and another writer
    # may have written since.
    module Ownership
      class Refused < Error; end

      # @param item [Item] the write
      # @param held [Item, nil] what the id currently resolves to
      # @raise [Refused]
      def self.permit!(item, held)
        return if held.nil? || item.author.chat? || held.author == item.author

        raise Refused, "memory item #{item.id.inspect} #{owner(held.author)} and is not yours to overwrite; " \
                       "write your finding under a new id instead"
      end

      def self.owner(author) = author.chat? ? "belongs to the human" : "was written by another lineage"
      private_class_method :owner
    end
  end
end
