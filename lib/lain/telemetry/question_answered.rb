# frozen_string_literal: true

module Lain
  module Telemetry
    # A human's answer to the model's own question, kept where the next agent
    # can read it. `answer` and `question` arrive already withheld of
    # credential shapes: this record outlives the session, like the history.
    #
    # @!attribute [r] requester
    #   @return [String, nil] the role that asked
    # @!attribute [r] epic_slug
    #   @return [String, nil] the epic the asker works under
    QuestionAnswered = Data.define(:question, :answer, :requester, :epic_slug) do
      include Journalable

      def initialize(question:, answer:, requester: nil, epic_slug: nil)
        super(question: -question.to_s, answer: -answer.to_s, requester: requester&.then { -_1.to_s },
              epic_slug: epic_slug&.then { -_1.to_s })
      end

      def to_journal = super.compact
    end
  end
end
