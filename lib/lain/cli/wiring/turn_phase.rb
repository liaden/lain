# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # The chat's own turn-phase members, which sit ahead of the chronicle's.
      module TurnPhase
        # @param window [Object] the run's one window book
        # @param mailbox [#post] the chat's inbox
        # @param agent [#call] answers the chat's Agent, which is built after this stack
        # @return [Array<Middleware::Base>]
        def self.members(window, mailbox, agent)
          # A thunk because the ask in flight may have raised the ceiling.
          ceiling = -> { agent.call&.budget&.iterations }
          [Middleware::ResolveWindow.new(book: window), Middleware::WrapUp.new(mailbox:, ceiling:)]
        end
      end
    end
  end
end
