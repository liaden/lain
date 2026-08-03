# frozen_string_literal: true

module Lain
  class Question
    AnswerSet = Data.define(:questions, :answers, :text)

    # The human's reply to one {Question::Set}, and the value that renders into
    # the text the model receives.
    #
    # It carries the questions as well as the answers, for two reasons. It is
    # what makes the pair rules checkable at all -- "one option on a
    # single-select", "an option this question actually offers" are facts about
    # the pair, and neither value alone can see them. And it is what lets
    # {#render} print the LABELS the model wrote rather than the ids the
    # document joins on: an answer read back off an event would otherwise need a
    # second lookup to say anything a reader understands.
    #
    # There is exactly one answer per question, always, in the order they were
    # asked. Submitting is never blocked, so `:w` resolves the whole set: a
    # question the human never touched is filled in as an explicitly unanswered
    # {Answer} rather than dropped, because the model has to be able to tell
    # DECLINED from MISSED and an omission says neither.
    #
    # `text` is the second answer shape and not a fallback: the TTY reply path
    # is always live, and a human who types a sentence at the terminal has
    # answered the whole set in prose rather than by selection. The two are
    # mutually exclusive -- a set carrying both would have two different
    # answers to the same question and no rule for which one wins.
    class AnswerSet
      include Enumerable

      # A whole-set reply is one thing a human types, so it is bounded like one
      # {Answer::MAX_COMMENT}.
      MAX_TEXT = Answer::MAX_COMMENT

      # {Set::MAX_SET} bounds the questions; this bounds the whole record that
      # actually reaches the request, which is those questions PLUS everything
      # the human wrote back. Eight wordy questions each answered at the comment
      # maximum is megabytes, and nothing else objects.
      MAX_ANSWER_SET = 512 * 1024

      # Reads only the keys it owns, so a richer event body -- one carrying who
      # answered, or when -- still rebuilds exactly the reply that was given.
      # The questions ride along in the same body, which is what makes an answer
      # read back off the Timeline renderable without a join.
      def self.from_body(body)
        fields = Rules.string_keyed(body, "an answer set body")
        listed = Rules.array!(Rules.required(fields, "answers", "an answer set body"), "an answer set's answers")
        new(questions: Set.from_body(body), text: fields.fetch("text", nil),
            answers: listed.each_with_index.map { |answer, index| answer_at(answer, index) })
      end

      # {Set.question_at}'s reason: a malformed answer in a five-answer body
      # used to surface as `KeyError: key not found: "question_id"`, and the
      # position is the only handle a reader has before the value exists.
      def self.answer_at(body, index)
        Answer.from_body(body)
      rescue ArgumentError => e
        raise ArgumentError, "answer #{index + 1} in this set cannot be read -- #{e.message}"
      end
      private_class_method :answer_at

      def initialize(questions:, answers: [], text: nil)
        asked = set!(questions)
        given = Given.new(asked, answers, text)
        super(questions: asked, answers: given.filled, text: given.prose)
        bounded!
      end

      def each(&block) = answers.each(&block)
      def size = answers.size
      def ids = answers.map(&:question_id)
      def key?(id) = answers.any? { |answer| answer.question_id == id }
      def prose? = !text.nil?

      # KeyError rather than this unit's ArgumentError, for {Set#fetch}'s
      # reason: every ArgumentError here means "this value cannot be built",
      # while this is a lookup miss on a value that built fine.
      def fetch(id)
        found = answers.find { |answer| answer.question_id == id }
        raise KeyError, "no answer for #{id.inspect} in this set (it answers #{ids.join(", ")})" if found.nil?

        found
      end

      # `Enumerable#to_h` sits ahead of `Data#to_h` in the ancestor chain and
      # would read our answers as [key, value] pairs. Restored because every
      # Data-aware reader expects the member hash -- including the shareability
      # walk in `be_deeply_frozen`, which reaches for it only on the FAILURE
      # path, so nothing but a direct spec notices when this goes missing.
      def to_h = { questions:, answers:, text: }

      # The text the model receives. A String, because that is what a
      # {Tool::Result} carries.
      def render = Rendering.new(self).to_s

      # Plain wire form for {Canonical}: the question set's own body plus what
      # came back. A fresh copy, like {Set#to_body}, so the emitter can add its
      # own keys beside ours.
      def to_body = questions.to_body.merge("answers" => answers.map(&:to_body), "text" => text)

      private

      def set!(questions)
        return questions if questions.is_a?(Set)

        raise ArgumentError, "an answer set must answer a Question::Set (got #{questions.class})"
      end

      def bounded!
        Rules.bounded(Canonical.dump(to_body), "an answer set", MAX_ANSWER_SET)
      end
    end

    class AnswerSet
      # The rules that need BOTH sides of the pair, on a throwaway carrier that
      # is checked and discarded -- {Lain::Guard}'s convention, in plain Ruby
      # because none of these are field-shaped: "one option on a single-select"
      # and "an option this question offers" are joins, not presence checks.
      #
      # It also does the FILLING, because the two are the same pass: an answer
      # is matched to its question to be validated, and what has no match is a
      # question nobody touched.
      class Given
        def initialize(questions, answers, text)
          @questions = questions
          @given = indexed(answers)
          @prose = spoken(text)
          # One record per question, in the order they were asked, so a reader
          # never has to ask whether a missing entry means declined or missed.
          # Built BEFORE the pair rules because it is what they walk: the same
          # index answers "which question is this" and "which question got
          # nothing", so the join happens once.
          @filled = @questions.map { |question| @given.fetch(question.id) { Answer.unanswered(question.id) } }
                              .freeze
          check!
        end

        attr_reader :prose, :filled

        private

        def indexed(answers)
          given = Rules.members!(answers, Answer, "an answer set's answers")
          Rules.distinct!(given.map(&:question_id), "an answer set's answers")
          given.to_h { |answer| [answer.question_id, answer] }
        end

        # {Answer#written}'s predicate, for its reason: a whitespace-only reply
        # typed at the terminal is not an answer, and `strip` would not say so.
        def spoken(text)
          return nil if text.nil? || Blankness.blank?(text)

          Rules.bounded(Rules.prose(text, "an answer set's text"), "an answer set's text", MAX_TEXT)
        end

        def check!
          unknown!
          exclusive!
          @questions.zip(@filled).each { |question, answer| legal!(answer, question) }
        end

        # An answer nobody asked for is the one thing the fill cannot show: it
        # is silently absent from {#filled}. ArgumentError rather than the
        # KeyError {Set#fetch} raises -- this is a value that cannot be built,
        # not a lookup miss on one that was.
        def unknown!
          stray = (@given.keys - @questions.ids).first
          return if stray.nil?

          raise ArgumentError, "an answer names #{stray.inspect}, which this set does not ask " \
                               "(it asks #{@questions.ids.join(", ")})"
        end

        def exclusive!
          return if @prose.nil? || @filled.none?(&:answered?)

          raise ArgumentError, "an answer set answered in prose cannot also carry selections -- they are two " \
                               "different replies to the same questions, and nothing says which one wins"
        end

        def legal!(answer, question)
          offered!(answer, question)
          return unless question.single? && answer.option_ids.size > 1

          raise ArgumentError, "question #{question.id.inspect} takes one option and was answered with " \
                               "#{answer.option_ids.size} (#{answer.option_ids.join(", ")})"
        end

        def offered!(answer, question)
          offered = question.options.map(&:id)
          stranger = answer.option_ids.find { |id| !offered.include?(id) }
          return if stranger.nil?

          raise ArgumentError, "question #{question.id.inspect} does not offer #{stranger.inspect} " \
                               "(it offers #{offered.empty? ? "no options at all" : offered.join(", ")})"
        end
      end

      # The answer set as the model reads it. A separate object because
      # rendering is a separate responsibility from construction, and because
      # the two arms -- a set answered by selection and a set answered in prose
      # -- read as two documents rather than one document with a branch in it.
      class Rendering
        def initialize(set)
          @set = set
        end

        def to_s = (@set.prose? ? spoken : selections).join("\n\n")

        private

        def spoken
          ["The human answered the whole set in prose rather than by selection.",
           "Questions asked: #{@set.questions.ids.map { |id| "`#{id}`" }.join(", ")}",
           "Reply:\n#{quoted(@set.text)}"]
        end

        def selections = [counted, *@set.map { |answer| section(answer) }]

        def counted
          asked = @set.size == 1 ? "question" : "questions"
          "The human answered #{@set.count(&:answered?)} of #{@set.size} #{asked}."
        end

        def section(answer)
          question = @set.questions.fetch(answer.question_id)
          ["### `#{answer.question_id}`", *lines(answer, question)].join("\n")
        end

        # An unanswered question is NAMED and reported, never omitted: an
        # omission would read as an answer the renderer forgot, and the model
        # has to be able to tell declined from missed. On a `free_text?`
        # question the prose IS the answer, so calling it a comment would say
        # the question went unanswered when it did not.
        def lines(answer, question)
          return ["Unanswered."] unless answer.answered?
          return ["Answered:", quoted(answer.comment)] if question.free_text?

          [chosen(answer, question), *(answer.comment? ? ["Comment:", quoted(answer.comment)] : [])]
        end

        # The human's prose is the one part of this document nobody reviewed,
        # and every line of the grammar around it -- the `### `id`` heading, the
        # `Chose:`/`Unanswered.` lines, the count header, the blank line that
        # ends a section -- is something a pasted diff or stack trace can hold
        # verbatim. Unquoted, a comment forges sections: the model receives one
        # document asserting both `Chose: X` and `Unanswered.` for the same
        # question. This is {Rules.fenced!}'s concern on the reply side.
        #
        # A blockquote prefix rather than a fence, because containment must not
        # depend on the content: a fence can be ESCAPED by prose that holds a
        # longer run of the same marker, so it would need the marker computed
        # from the text (what {Question::Fence} has to do to read one). A
        # per-line prefix cannot be escaped at all -- no line of human text
        # reaches column 0, so none can be read as one of ours, and prose
        # holding its own fence just nests.
        #
        # Split on every line ending rather than `String#lines`, which only
        # breaks on \n: a lone \r is a line break to a renderer and would carry
        # the rest of the line out from behind its marker. The stored comment
        # keeps its bytes verbatim; only this rendering normalizes them.
        def quoted(prose)
          prose.split(/\r\n|\r|\n/).map { |line| line.empty? ? ">" : "> #{line}" }.join("\n")
        end

        def chosen(answer, question)
          return "No option chosen." unless answer.selected?

          "Chose: #{labels(answer, question).join(", ")}"
        end

        # Labels rather than ids, because the model wrote the labels and joins
        # on the ids. Listed in the question's own option order, which is the
        # order the model reads them in.
        def labels(answer, question)
          question.options.select { |option| answer.option_ids.include?(option.id) }.map(&:label)
        end
      end
    end
  end
end
