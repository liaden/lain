# frozen_string_literal: true

module Lain
  class Question
    Set = Data.define(:questions)

    # The questions one `ask_human` call carries, in the order they are asked.
    #
    # A set exists for cost, not taxonomy: the asking tool is not
    # `parallel_safe?`, so N separate questions are N barriers -- the human
    # answers, the model round-trips, asks again. One set collapses that to one
    # barrier, and the price is that it resolves as a whole.
    #
    # Order is meaning: it is the order the human reads and the order the answer
    # document renders, so the list is preserved rather than sorted. Ids are
    # unique because every downstream reader -- the parser, the answer set, the
    # editor keymap -- joins an answer to a question by id, and two questions
    # answering to one id is a join that silently picks one.
    class Set
      include Enumerable

      # The bound that actually matters. {Question::MAX_BODY} bounds ONE
      # question; what reaches the request, the Store, and the prompt is this
      # whole thing serialized, and nothing bounded that -- 40 maximal questions
      # dumped to 2.6MB and no rule objected. So the check is over the bytes
      # Canonical will really emit, the way {Improvement} asserts its whole
      # record against a line budget rather than trusting its one bounded field.
      # 256KiB is four maximal questions, or hundreds of ordinary ones.
      MAX_SET = 256 * 1024

      # Reads only the keys it owns, so a RICHER body -- an event body carrying
      # a one-line summary beside the set, which is what the inbox line reads --
      # still rebuilds exactly the set that was asked.
      def self.from_body(body)
        fields = Rules.string_keyed(body, "a question set body")
        listed = Rules.array!(Rules.required(fields, "questions", "a question set body"),
                              "a question set's questions")
        new(questions: listed.each_with_index.map { |question, index| question_at(question, index) })
      end

      # A malformed question in a five-question set used to surface as
      # `KeyError: key not found: "body"`, which names neither the set nor which
      # question. The position is the only handle a reader has before the value
      # exists -- an id it cannot trust is exactly what may be missing.
      def self.question_at(body, index)
        Question.from_body(body)
      rescue ArgumentError => e
        raise ArgumentError, "question #{index + 1} in this set cannot be read -- #{e.message}"
      end
      private_class_method :question_at

      def initialize(questions:)
        super(questions: asked(questions))
      end

      def each(&block) = questions.each(&block)
      def size = questions.size
      def ids = questions.map(&:id)
      def key?(id) = questions.any? { |question| question.id == id }

      # KeyError rather than this unit's ArgumentError, deliberately: every
      # ArgumentError here means "this value cannot be built", while this is a
      # lookup miss on a value that built fine -- so it answers the way
      # `Hash#fetch` does.
      def fetch(id)
        found = questions.find { |question| question.id == id }
        raise KeyError, "no question #{id.inspect} in this set (it asks #{ids.join(", ")})" if found.nil?

        found
      end

      # `Enumerable#to_h` sits ahead of `Data#to_h` in the ancestor chain and
      # would read our questions as [key, value] pairs. Data's own member hash
      # is restored here because every Data-aware reader expects it -- the
      # shareability walk in `be_deeply_frozen` reaches for it by name, and it
      # only reaches for it on the FAILURE path, so nothing but a direct spec
      # notices when this method goes missing. There is one.
      def to_h = { questions: }

      # Plain wire form for {Canonical}, and the shape the `:message` event body
      # is built from. A fresh copy, like {Question#to_body}, so the emitter can
      # add its own keys beside ours without reaching this value.
      def to_body = { "questions" => questions.map(&:to_body) }

      private

      # A set of nothing is not an empty set, it is an `ask_human` call with
      # nothing to ask: it would emit a message addressed to a human, park a
      # promise, and never be answerable.
      def asked(questions)
        asked = Rules.members!(questions, Question, "a question set's questions")
        raise ArgumentError, "a question set must ask at least one question" if asked.empty?

        Rules.distinct!(asked.map(&:id), "a question set's questions")
        Rules.bounded(Canonical.dump("questions" => asked.map(&:to_body)), "a question set", MAX_SET)
        asked.dup.freeze
      end
    end
  end
end
