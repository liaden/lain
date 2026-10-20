# frozen_string_literal: true

module Lain
  module Dag
    # The one place a Timeline, a Store or a stored event is built, so which
    # implementation backs the DAG is decided here and nowhere else.
    #
    # `LAIN_DAG` names the implementation, `rust` or `ruby`, so while both exist
    # the default is one word here and the flip between them one revertible commit.
    module Factory
      # A store of the implementation not selected: the Ruby timeline would run
      # over it in silence, and the Rust one refuses it with no word of why.
      class ForeignStore < Error; end

      IMPLEMENTATIONS = {
        "rust" => { timeline: Ext::Timeline, store: Ext::Store },
        "ruby" => { timeline: Timeline, store: Store }
      }.freeze

      # @return [Lain::Ext::Store, Lain::Store] a fresh, empty store
      def self.store = chosen.fetch(:store).new

      # @param store [Lain::Ext::Store, Lain::Store] built by {.store}
      # @param head_digest [String, nil] a digest the store holds
      # @return [Lain::Ext::Timeline, Lain::Timeline]
      # @raise [ForeignStore] when `store` belongs to the implementation not selected
      def self.timeline(store:, head_digest: nil)
        implementation = chosen
        refuse_foreign!(store)
        implementation.fetch(:timeline).new(head_digest:, store:)
      end

      # An event carrying its payload, for a caller that puts both: each store
      # takes only its own implementation's events.
      #
      # @param kind [Symbol] one of {EventLog::Kinds::KINDS}
      # @param body [Hash] what the payload carries, addressed apart from the envelope
      # @param envelope [Hash] `from:`, `to:`, `render_parent:`, `causal_parents:`, `correlation:`
      # @return [Lain::Ext::Event, Lain::Event]
      def self.event(kind:, body:, **envelope)
        return Ext::Event.new(kind:, body:, **envelope) if implementation == :rust

        Event.new(kind:, carried_payload: Event::Payload.new(kind:, body:), **envelope)
      end

      # @return [Symbol] :rust or :ruby
      def self.implementation = IMPLEMENTATIONS.key(chosen).to_sym

      # @raise [Lain::Error] when `LAIN_DAG` names no implementation
      def self.chosen
        IMPLEMENTATIONS.fetch(selected) do
          raise Error, "LAIN_DAG=#{selected.inspect} names no DAG implementation; " \
                       "choose #{IMPLEMENTATIONS.keys.join(" or ")}"
        end
      end

      def self.selected = ENV.fetch("LAIN_DAG", "rust")

      # @raise [ForeignStore] when `store` belongs to the implementation not selected
      def self.refuse_foreign!(store)
        foreign = IMPLEMENTATIONS.except(selected).each_value.map { |pair| pair.fetch(:store) }
        kind = foreign.find { |candidate| store.is_a?(candidate) }
        raise ForeignStore, "a #{kind} cannot back a timeline while LAIN_DAG selects #{selected}" if kind
      end
      private_class_method :chosen, :selected, :refuse_foreign!
    end
  end
end
