# frozen_string_literal: true

module Lain
  module EventLog
    # Questions about where a chain stands, over any event's envelope: pure Ruby
    # on `role`, `content` and `parent`, so they hold for either DAG implementation.
    module Guards
      # The turn a render over `head` stands on, and so what a reading or a
      # compaction cut taken on that render is believed on. A user turn at the
      # head is the one the render added -- a prompt, a round's results, a
      # cancellation -- and an ask refused before any model saw it withdraws a
      # prompt while the next one takes its place, so the answer is the turn
      # beneath it; the model's own turn at the head is its own answer. nil is
      # the empty chain, which every chain extends.
      #
      # @param head [Ext::Event, nil]
      # @return [String, nil] a turn digest
      def self.stands_on(head)
        return nil if head.nil?

        head.role == "user" ? head.parent : head.digest
      end

      # Whether `event` is an assistant turn still carrying an unanswered
      # tool_use block -- the shape the next request would render as a dangling
      # tool_use, which the API rejects.
      #
      # Such an event must never become a rewind TARGET. The session-loading doors
      # repair rather than refuse -- CLI::Resume#settled commits a projected
      # cancellation turn above the torn head, so a resumed chain legitimately
      # starts from a head that is settled again; only a call naming no tool_use
      # id, which nothing can pair a result with, still refuses there. The doors
      # that move a LIVE head with no load behind them (CLI::Command::Fork#anchor!,
      # CLI::Command::Rewind#settled_target!) still refuse outright.
      #
      # One definition, because this was two copies that had quietly drifted --
      # one guarded a nil event, one did not. Nil-safe on purpose:
      # CLI::Command::Rewind#nearest_valid evaluates it over `(1..heads.length)`,
      # where `heads[heads.length]` is nil by construction.
      def self.pending_tool_use?(event)
        !event.nil? && event.role == "assistant" &&
          event.content.any? { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
      end

      # Text a human asked that nothing answered, so the next ask folds into it.
      # A head of tool results is not one: folding it would put an answer to the
      # model's calls in the human's mouth.
      def self.stranded_prompt?(event)
        !event.nil? && event.role == "user" && event.content.all? { |block| block["type"] == "text" }
      end
    end
  end
end
