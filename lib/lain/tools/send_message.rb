# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): lets an orchestrator put a note in a running actor's
    # mailbox, so it can steer a child it launched without waiting for it to
    # finish. Reaches actors only; a one-shot child has no mailbox to fill.
    class SendMessage < Tool
      # The two values a tell needs: where it goes and what it says.
      class Input < Tool::Input
        field :address, :string, required: true,
                                 description: "The actor's address, as the spawn that launched it reported it."
        field :text, :string, required: true, description: "The note to leave in the actor's mailbox."
      end

      input_model Input

      # Keep a refusal short however long an address the model sends or however many actors run.
      ECHO_LIMIT = 80
      LISTED_LIMIT = 10
      private_constant :ECHO_LIMIT, :LISTED_LIMIT

      # @param live [#call] a thunk over the running actors, each answering
      #   `address` and `tell`; read at call time because actors come and go
      def initialize(live:)
        super()
        @live = live
      end

      def name = "send_message"

      def description
        "Sends a note to a running actor you launched, by its address; the actor reads it at its next turn. " \
          "Refuses an address that is not running and lists the ones that are."
      end

      # Two tells to one actor land in call order, and that order is the message.
      def parallel_safe? = false

      protected

      def perform(input, _invocation)
        actors = @live.call
        actor = actors.find { |candidate| candidate.address == input.address }
        return Tool::Result.error(unknown(input.address, actors)) if actor.nil?

        actor.tell(input.text)
        Tool::Result.ok("delivered to #{input.address.truncate(ECHO_LIMIT)}")
      rescue Lain::Error => e
        Tool::Result.error(e.message)
      end

      private

      def unknown(address, actors)
        "no live actor at #{address.truncate(ECHO_LIMIT)}; live addresses: #{listed(actors.map(&:address))}"
      end

      def listed(addresses)
        return "none" if addresses.empty?

        shown = addresses.first(LISTED_LIMIT).join(", ")
        addresses.size > LISTED_LIMIT ? "#{shown} and #{addresses.size - LISTED_LIMIT} more" : shown
      end
    end
  end
end
