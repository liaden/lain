# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # What a chat's board handed its backend: the model slot `/model` writes,
      # which a following tier reads, and the chat agent's spend, which every
      # tier pays into. Bound once; a second board, channel or spend is
      # refused, so neither the holds nor the tiers' payments are re-pointed.
      #
      # A child's judge and summaries pay into this one spend too, not the
      # child's ceiling, because `--max-cost` bounds the whole run.
      class Attachment
        # @return [Budget::Shared]
        attr_reader :spend

        # @param board [#model_switch] the chat's {Switchboard}
        # @param channel [#push] where the board's notices are shown
        # @param spend [Budget::Shared] the chat agent's
        def initialize(board:, channel:, spend:)
          @board = board
          @channel = channel
          @spend = spend
        end

        # @return [String] the model the chat is on now
        def model = @board.model_switch.to_s

        # @param board [Object]
        # @param channel [Object]
        # @param spend [Budget::Shared]
        # @return [self]
        # @raise [Rebound] naming what moved, when any is not the one attached
        def admit!(board, channel, spend)
          moved = { "board" => [@board, board], "channel" => [@channel, channel], "spend" => [@spend, spend] }
                  .reject { |_, (was, now)| was.equal?(now) }.keys
          raise Rebound, "the backend is already attached to another #{moved.join(" and ")}" if moved.any?

          self
        end

        # Before any board (headless, consolidate), where nothing can switch
        # the model and no agent's ceiling stands behind a tier.
        class Detached
          # @return [String] the launch model
          attr_reader :model

          # @param model [String]
          def initialize(model)
            @model = model
          end

          # @return [Budget::Shared::Null]
          def spend = Budget::Shared::Null

          # @return [self]
          def admit!(_board, _channel, _spend) = self
        end
      end
    end
  end
end
