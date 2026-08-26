# frozen_string_literal: true

module Lain
  class Question
    Answer = Data.define(:question_id, :option_ids, :comment)

    # One human reply to one {Question}: answered by SELECTION (`option_ids`),
    # by PROSE (`comment` -- the whole answer on a `free_text?` question, a note
    # beside the ticks on any other), or not at all. "Not at all" is a record
    # and not an absence: submitting is never blocked, so `:w` resolves every
    # question in the set and the model must tell a DECLINED question from a
    # MISSED one. `answered?` is DERIVED from the two fields, so an "unanswered"
    # record carrying a selection cannot be built.
    #
    # Whether the selection is legal is a fact about the PAIR, so {AnswerSet} --
    # which holds both -- is where those rules live.
    #
    # Reopened rather than folded into the `Data.define` block, because a
    # constant or a `class` keyword written inside that block binds to `Lain`
    # and not to the Data class (see {Request::SYSTEM_PREFIX}).
    class Answer
      # Bounded well under {Question::MAX_BODY}: the model writes the question,
      # the human writes the reply, and the reply is the shorter half. Refused
      # rather than truncated, for {Question::MAX_BODY}'s reason.
      MAX_COMMENT = 64 * 1024

      # Validated on a throwaway carrier that is checked and discarded, so the
      # frozen value never carries ActiveModel's ivars
      # ({Lain::Declarative::Carrier}). `check!` and not `settle!`: the one field
      # it judges is already interned by {Rules.identifier}, and the two it does
      # not judge are coerced by rules no declared type expresses.
      class Fields < Declarative::Carrier
        attribute :question_id
        validates :question_id, presence: { message: "must name the question it answers, got blank" }
      end

      # Not a subclass and not a nil, so every reader walks one list of one type.
      def self.unanswered(question_id) = new(question_id:)

      # Both defaults are the permissive reading of an under-specified body, and
      # exactly {.unanswered}'s shape. Unknown keys are ignored, so a richer body
      # still rebuilds the answer.
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

      # Plain wire form: every field always present so the shape is stable across
      # answers, `nil` being a leaf {Canonical} accepts. A fresh copy at every
      # level, so the caller emitting this as an event body can add its own keys.
      def to_body
        { "question_id" => question_id, "option_ids" => option_ids.dup, "comment" => comment }
      end

      private

      # The order the human ticked them, preserved rather than sorted. Copied
      # rather than frozen in place: the caller keeps ownership of its Array.
      def selection(option_ids)
        chosen = Rules.array!(option_ids, "an answer's option_ids")
                      .map { |id| Rules.identifier(id, "an answer option_id", MAX_ID) }
        Rules.distinct!(chosen, "an answer's option_ids")
        chosen.freeze
      end

      # {Blankness} rather than `strip`: a single U+00A0 passes `strip != ""`,
      # and an editor puts one in more easily than a human does. Blank becomes
      # nil rather than "" so a whitespace-only reply cannot read as prose.
      def written(comment)
        return nil if comment.nil? || Blankness.blank?(comment)

        Rules.bounded(Rules.prose(comment, "an answer comment"), "an answer comment", MAX_COMMENT)
      end
    end
  end
end
