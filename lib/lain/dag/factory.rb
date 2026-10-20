# frozen_string_literal: true

module Lain
  module Dag
    # The one place a Timeline or a Store is built, so which implementation
    # backs the DAG is decided here and nowhere else.
    module Factory
      def self.store = Store.new

      def self.timeline(store:, head_digest: nil) = Timeline.new(head_digest:, store:)

      def self.implementation = :ruby
    end
  end
end
