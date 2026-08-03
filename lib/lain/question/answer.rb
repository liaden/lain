# frozen_string_literal: true

module Lain
  class Question
    Answer = Data.define(:question_id, :option_ids, :comment)

    # One human reply to one {Question}: the question it answers, whichever
    # options were ticked, and whatever prose was written under it.
    #
    # Three arms, one class. A question can be answered by SELECTION
    # (`option_ids`), by PROSE (`comment` -- which is the whole answer on a
    # `free_text?` question and a note beside the ticks on any other), or not at
    # all. "Not at all" is a real record and not an absence: submitting is never
    # blocked, so `:w` resolves every question in the set including the ones the
    # human never touched, and the model has to be able to tell a DECLINED
    # question from a MISSED one. {.unanswered} names that record.
    #
    # `answered?` is DERIVED from the two fields rather than stored, so there is
    # no state where a flag and the content disagree -- an "unanswered" record
    # carrying a selection cannot be built.
    #
    # This value knows nothing about the question it answers. Whether the
    # selection is legal (one option on a single-select, an option the question
    # actually offers) is a fact about the PAIR, so {AnswerSet} -- which holds
    # both -- is where those rules live.
    #
    # Reopened rather than folded into the `Data.define` block, because a
    # constant or a `class` keyword written inside that block binds to `Lain`
    # and not to the Data class (see {Request::SYSTEM_PREFIX}).
    class Answer
      # A comment is prose a human types into one section of the answer
      # document, so it is bounded well under {Question::MAX_BODY} -- the model
      # writes the question, the human writes the reply, and the reply is the
      # shorter half. Refused above the maximum rather than truncated, for
      # {Question::MAX_BODY}'s reason.
      MAX_COMMENT = 64 * 1024

      # Validated on a throwaway carrier that is checked and discarded, so the
      # frozen value never carries ActiveModel's ivars (see {Lain::Guard}).
      class Fields < Guard
        attribute :question_id
        validates :question_id, presence: { message: "must name the question it answers, got blank" }
      end

      # The record for a question the human never touched. Not a subclass and
      # not a nil: the same value with nothing in it, so every reader walks one
      # list of one type and asks `answered?`.
      def self.unanswered(question_id) = new(question_id:)

      # The way in from raw data -- an answer read back off an event body. Both
      # defaults are the permissive reading of an under-specified body, and they
      # are exactly {.unanswered}'s shape. Unknown keys are ignored on purpose,
      # so a richer body still rebuilds the answer.
      def self.from_body(body)
        fields = Rules.string_keyed(body, "an answer body")
        new(question_id: Rules.required(fields, "question_id", "an answer body"),
            option_ids: fields.fetch("option_ids", []), comment: fields.fetch("comment", nil))
      end

      def initialize(question_id:, option_ids: [], comment: nil)
        fields = { question_id: Rules.identifier(question_id, "an answer question_id", MAX_ID) }
        Fields.check!(**fields)
        super(**fields, option_ids: selection(option_ids), comment: written(comment))
      end

      def selected? = !option_ids.empty?
      def comment? = !comment.nil?
      def answered? = selected? || comment?

      # Plain wire form: String keys, every field always present so the shape is
      # stable across answers, and `nil` is a leaf {Canonical} accepts. A fresh
      # copy at every level, like {Question#to_body}, so the caller that emits
      # this as an event body can add its own keys beside ours.
      def to_body
        { "question_id" => question_id, "option_ids" => option_ids.dup, "comment" => comment }
      end

      private

      # Selection order is the order the human ticked them, so it is preserved
      # rather than sorted. Copied rather than frozen in place, as
      # {Question#choices} does: the caller keeps ownership of the Array it
      # handed over.
      def selection(option_ids)
        chosen = Rules.array!(option_ids, "an answer's option_ids")
                      .map { |id| Rules.identifier(id, "an answer option_id", MAX_ID) }
        Rules.distinct!(chosen, "an answer's option_ids")
        chosen.freeze
      end

      # {Blankness} rather than `strip`, for the reason written there: a single
      # U+00A0 passes `strip != ""`, and a human's editor puts one in more
      # easily than a human does.
      #
      # Blank becomes nil rather than "" so `comment?` is one question with one
      # answer, and a whitespace-only reply can never read as prose.
      def written(comment)
        return nil if comment.nil? || Blankness.blank?(comment)

        Rules.bounded(Rules.prose(comment, "an answer comment"), "an answer comment", MAX_COMMENT)
      end
    end
  end
end
