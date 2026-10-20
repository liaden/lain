# frozen_string_literal: true

module Lain
  module Dag
    # The one place a Timeline, a Store or a stored event is built, so no
    # caller binds itself to the extension's constructors and a different DAG
    # is one edit here.
    module Factory
      # @return [Lain::Ext::Store] a fresh, empty store
      def self.store = Ext::Store.new

      # @param store [Lain::Ext::Store] built by {.store}
      # @param head_digest [String, nil] a digest the store holds
      # @return [Lain::Ext::Timeline]
      def self.timeline(store:, head_digest: nil) = Ext::Timeline.new(head_digest:, store:)

      # An event carrying its payload, for a caller that puts both.
      #
      # @param kind [Symbol] one of {EventLog::Kinds::KINDS}
      # @param body [Hash] what the payload carries, addressed apart from the envelope
      # @param envelope [Hash] `from:`, `to:`, `render_parent:`, `causal_parents:`, `correlation:`
      # @return [Lain::Ext::Event]
      def self.event(kind:, body:, **envelope) = Ext::Event.new(kind:, body:, **envelope)
    end
  end
end
