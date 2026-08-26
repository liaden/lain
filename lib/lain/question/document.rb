# frozen_string_literal: true

module Lain
  class Question
    class MalformedDocument < Error; end

    # The question set as the markdown a human edits in nvim, and the parse that
    # reads those edits back into an {AnswerSet}. Tick a checkbox, write indented
    # prose beneath it, `:w`.
    #
    # The round trip is TOTAL: `parse_markdown(to_markdown(a), set)` is `a`, or
    # the emit is refused loudly naming the value it cannot write. Nothing is
    # silently reinterpreted in either direction -- a line the grammar has no
    # slot for is an error naming it. {Plan::Document}'s "drop what you do not
    # recognize" is the wrong posture here: the dropped line would be the
    # human's answer.
    #
    # **This grammar tracks no fence state at all**, where {Epic::Document}
    # REFUSES a fence in a description -- a fenced diff, table, or mermaid block
    # is the whole point of a question body. The parse is handed the set it is
    # parsing, so a question's body is compared against that question's own bytes
    # and skipped WHOLE. A body containing an option line or a heading is
    # therefore unreadable as grammar, and no unbalanced fence -- the one thing a
    # human can produce by typing -- can swallow the document, because no MODE
    # survives a line. State does: {Reader} carries a position and {Draft} the
    # entries and an option counter. What none of it can do is change how the
    # NEXT line is read -- {Draft#line} looks at its own line and nothing else,
    # {Reader#body!} compares a whole region in one shot without classifying
    # anything inside it, and the stop line is a byte comparison against a string
    # this writer produced.
    #
    # Two degrees of freedom are the human's, and they are all the grammar reads:
    # the character inside a checkbox, and the indented prose. Every other byte
    # is compared against what the renderer would have written.
    #
    # One deliberate asymmetry: prose written ABOVE the options comes back
    # rendered below them. The content survives whole and the position was never
    # information -- {Answer} carries a comment, not a place to put it -- so this
    # is relocated rather than refused.
    module Document
      # The heading's arity word. `free_text?` is a third KIND rather than an
      # arity, because "choose one" printed above no options reads as a bug.
      #
      # These strings are a CONTRACT: the `x` keymap (frontend/neovim) recovers a
      # question's boundary and its arity by scanning up to the nearest line
      # matching {HEADING}, with no RPC -- this same map read by the editor
      # rather than by us, and why {Question::DOCUMENT_HEADING} refuses a body
      # line wearing this shape at construction.
      FREE_TEXT = "free_text"
      KIND_LABELS = { SINGLE => "choose one", MULTI => "choose any",
                      FREE_TEXT => "write your answer below" }.freeze
      HEADING = /\A## `(?<id>[^`]+)` \((?<kind>#{Regexp.union(KIND_LABELS.values)})\)\z/

      # One mark map, both directions, `fetch`ed at both ends -- so a mark this
      # grammar writes is a mark it reads, and a third selection state fails
      # loudly here rather than emitting a document that will not parse.
      #
      # `[X]` is NOT a synonym for `[x]`: every other byte of an option line is
      # matched literally against what the renderer wrote, and accepting a second
      # spelling would be the one place this grammar normalized the human's text
      # instead of refusing it.
      SELECTION_MARKS = { true => "x", false => " " }.freeze
      MARK_SELECTIONS = SELECTION_MARKS.invert.freeze
      MARK_LEGEND = MARK_SELECTIONS.map { |mark, ticked| "[#{mark}] #{ticked ? "chosen" : "not chosen"}" }
                                   .join(", ").freeze

      # A GitHub task-list item, so it renders as a checkbox anywhere, carrying
      # the id in a code span (which is why {ID_RESERVED} reserves the backtick).
      # Anchored at column 0: indentation is the one discriminator between the
      # grammar and the human's prose, so an indented option-shaped line is prose.
      OPTION = /\A- \[(?<mark>.)\] `(?<id>[^`]+)` (?<label>.*)\z/

      # The comment slot: indented prose beneath the option. Exactly two spaces,
      # and a line indented some other way is REFUSED rather than re-indented --
      # the editor is set to produce these bytes (`expandtab`, `shiftwidth=2`),
      # and guessing what a tab meant is how a round trip starts editing the
      # human's whitespace.
      INDENT = "  "

      # The ONE statement of "these bytes would not survive the parse". The parse
      # rstrips every line it reads, so anything the rstrip would remove is
      # refused on the way out instead of vanishing on the way back.
      #
      # A finder rather than a predicate: a comment and a body each run to 64KiB,
      # so the message names the offending LINE rather than dumping the value.
      STRIPPED_BYTES = [
        ["cannot hold a line ending in whitespace -- a trailing space or a \\r -- because the parse strips " \
         "every line it reads and those bytes would not survive the round trip",
         ->(text) { text.each_line.find { |line| Document.normalize_line(line) != line.delete_suffix("\n") } }]
      ].freeze

      # What a comment must already be for the grammar to write it back
      # unchanged. Everything ELSE is allowed: the indent is what separates the
      # human's prose from the grammar, so a comment may hold a fence, a heading,
      # or a checkbox line and none of them mean anything.
      COMMENT_RULES = [
        ["cannot begin with a blank line (the parse reads a comment from its first indented line, so those " \
         "bytes would not survive)",
         ->(text) { text.lines.first if Document.normalize_line(text.lines.first.to_s).empty? }],
        ["cannot end in whitespace or a line break (the parse reads a comment to its last indented line)",
         ->(text) { text.lines.last if text != text.rstrip }],
        *STRIPPED_BYTES
      ].freeze

      # The body has NO rule here. The one shape it may not hold -- a line that
      # reads as a heading, which would put the options below it under the wrong
      # question when the editor scans up -- is refused where the body is BUILT,
      # by {Question::DOCUMENT_HEADING}. A rendered question is always a
      # constructed one, so a second check here would fire too late to help.

      module_function

      # The parse's per-line normalization, named once and consulted by the emit
      # rules above rather than restated there -- two lists that had to agree is
      # what let a CR through in {Epic::Document}.
      def normalize_line(line) = line.rstrip

      # The set nobody has answered yet, which is what a buffer opens on.
      def unanswered(set) = to_markdown(AnswerSet.new(questions: set))

      def to_markdown(answers) = Writer.new(answers).to_s

      # The set is always known -- exactly one is open -- and being given it is
      # what lets the body be skipped whole.
      #
      # An {AnswerSet} raises ArgumentError for a pair rule the line walk cannot
      # see; it is re-raised as this unit's error, because an ArgumentError
      # escaping to an editor's `:w` is an unhandled crash.
      def parse_markdown(source, set)
        AnswerSet.new(questions: set, answers: Reader.new(source, set).answers)
      rescue ArgumentError => e
        raise MalformedDocument, "this document does not answer the set it was rendered from -- #{e.message}"
      end

      def heading(question) = "## `#{question.id}` (#{KIND_LABELS.fetch(kind(question))})"

      def kind(question) = question.free_text? ? FREE_TEXT : question.arity

      def option_line(option, ticked) = "- [#{SELECTION_MARKS.fetch(ticked)}] `#{option.id}` #{option.label}"

      # The body as lines the writer emits and the reader compares against,
      # terminators removed and every other byte kept -- a CR included, since a
      # CRLF body is stored as written and the reader's own normalization is what
      # makes the two ends meet.
      def body_lines(question) = question.body.lines.map { |line| line.delete_suffix("\n") }

      # A character named so a human can act on it. `inspect` alone renders
      # U+00A0 as " " and a zero-width character as "", so a refusal naming a
      # mangled checkbox mark showed the offender as visually identical to the
      # legal mark named in the same sentence -- the one error here nobody could
      # act on.
      def named(character) = "#{character.inspect} (#{format("U+%04X", character.ord)})"

      def rule_break(rules, value)
        broken = rules.find { |_message, finder| finder.call(value) }
        "#{broken.first} (at #{broken.last.call(value).inspect})" if broken
      end

      # One question's answer region as the reader walks it: what was on the
      # line, and where. The line number is carried because every refusal below
      # names it, and by the time a rule fails the position has moved on.
      Blank = Data.define(:number)
      Choice = Data.define(:number, :option, :ticked)
      Prose = Data.define(:number, :text)

      # The whole answer set as the document, sections in the order the questions
      # were asked. Refuses -- rather than mangles -- a value the grammar cannot
      # write back: a document that parsed to something other than what it was
      # rendered from is a silent edit of the human's answer.
      class Writer
        def initialize(answers)
          @answers = answers
        end

        def to_s
          refuse_prose!
          "#{sections.join("\n\n")}\n".freeze
        end

        private

        def sections
          @answers.questions.zip(@answers.answers).map { |question, answer| section(question, answer) }
        end

        def section(question, answer)
          [Document.heading(question), *Document.body_lines(question), *reply(question, answer)].join("\n")
        end

        # Two BLOCKS, each preceded by a blank line and each absent when empty --
        # so a free-text question with nothing written under it ends at its body
        # rather than trailing a blank line the parse would have to forgive.
        def reply(question, answer)
          [options(question, answer), comment(answer)].reject(&:empty?).flat_map { |block| ["", *block] }
        end

        def options(question, answer)
          question.options.map { |option| Document.option_line(option, answer.option_ids.include?(option.id)) }
        end

        # An interior blank line is written EMPTY rather than indented: an
        # indented blank line is a line ending in whitespace, which is exactly
        # what the parse strips and what {STRIPPED_BYTES} refuses.
        def comment(answer)
          return [] if answer.comment.nil?

          refuse_comment!(answer)
          answer.comment.split("\n").map { |line| line.empty? ? line : "#{INDENT}#{line}" }
        end

        # The prose arm answers the WHOLE set in one reply, and every slot in
        # this document answers one question. Refused rather than rendered
        # somewhere plausible, because there is no slot it could come back from.
        def refuse_prose!
          return unless @answers.prose?

          raise MalformedDocument, "an answer set answered in prose at the terminal has no slot in this " \
                                   "document -- it answers the whole set at once and every slot here answers " \
                                   "one question (got #{@answers.text.inspect})"
        end

        def refuse_comment!(answer)
          failure = Document.rule_break(COMMENT_RULES, answer.comment)
          raise MalformedDocument, "the comment on question #{answer.question_id.inspect} #{failure}" if failure
        end
      end

      # The line-oriented parse: the one mutable thing in the unit, held apart
      # from the values it builds.
      #
      # It walks the SET, not the document -- one question at a time, taking the
      # heading it must find, the body it must find, and then whatever the human
      # wrote until the next question's heading. That order is why no fence state
      # exists: by the time a line is read as grammar, every byte that could have
      # been quoted has already been consumed by length.
      class Reader
        def initialize(source, set)
          @lines = source.to_s.lines.map { |line| Document.normalize_line(line) }
          @questions = set.questions
          @position = 0
        end

        def answers
          @questions.each_with_index.map { |question, index| answer(question, index) }
        end

        private

        def answer(question, index)
          heading!(question)
          body!(question)
          region(question, following(index))
        end

        # The next question's heading, verbatim -- the stop line the answer
        # region runs up to. Compared as bytes we wrote rather than matched as a
        # pattern, which is the same discipline the body comparison uses.
        def following(index)
          later = @questions[index + 1]
          later && Document.heading(later)
        end

        def region(question, stop)
          draft = Draft.new(question)
          draft.line(@position + 1, take) while more? && @lines[@position] != stop
          draft.to_answer
        end

        def take
          line = @lines[@position]
          @position += 1
          line
        end

        def more? = @position < @lines.size

        # A blank line above the FIRST heading is refused, not skipped: skipping
        # it made it the one line in the unit neither refused nor preserved --
        # silently dropped on re-render. Refusing names line 1.
        def heading!(question)
          expected = Document.heading(question)
          return @position += 1 if @lines[@position] == expected

          raise MalformedDocument, "line #{@position + 1}: expected the heading for question " \
                                   "#{question.id.inspect} (#{expected.inspect}), got #{shown(@lines[@position])}"
        end

        # The whole body region compared in one shot and skipped whole: the
        # entire defence against a body that shows the grammar, since no line in
        # here is ever classified.
        #
        # Two properties, easy to conflate: skipping whole is what makes a body
        # SAFE, and the `normalize_line` on the expected side is what makes it
        # ROUND-TRIP -- the body is the one interpolated field held to
        # rstrip-invariance by normalizing both sides rather than by a
        # construction rule, which is why {Renderable.trimmed!} does not cover it.
        def body!(question)
          expected = Document.body_lines(question).map { |line| Document.normalize_line(line) }
          taken = @lines[@position, expected.size] || []
          refuse_body!(question, expected, taken) unless taken == expected
          @position += expected.size
        end

        def refuse_body!(question, expected, taken)
          offset = expected.zip(taken).index { |want, got| want != got }
          raise MalformedDocument, "line #{@position + offset + 1}: question #{question.id.inspect} renders its " \
                                   "body verbatim and reads only your answer, so this line cannot be edited " \
                                   "(expected #{expected[offset].inspect}, got #{shown(taken[offset])})"
        end

        def shown(line) = line.nil? ? "the end of the document" : line.inspect
      end

      # One question's answer region, accumulating until the next heading.
      # Mutable while parsing, emitting a frozen {Answer} -- {Epic::Document}'s
      # Draft, and here it also carries every refusal that needs a line number.
      class Draft
        def initialize(question)
          @question = question
          @entries = []
        end

        # The whole classification, and it is four cases wide because the human
        # owns exactly two of them. Indentation is tested AFTER the option shape
        # so an option line is never a comment, and before anything else so a
        # comment can hold a fence, a heading, or a checkbox and mean none of
        # them.
        def line(number, text)
          if text.empty? then @entries << Blank.new(number:)
          elsif (option = OPTION.match(text)) then choose(number, option)
          elsif text.start_with?(INDENT) then @entries << Prose.new(number:, text: text.delete_prefix(INDENT))
          else refuse_stray!(number, text)
          end
        end

        # {Answer} and {AnswerSet} own the rules about a legal reply; only the
        # two a line number improves are restated here. What they raise is
        # re-raised as this unit's error against the question.
        def to_answer
          missing!
          single!
          Answer.new(question_id: @question.id, option_ids: marked.map { |entry| entry.option.id }, comment:)
        rescue ArgumentError => e
          raise MalformedDocument, "question #{@question.id.inspect} cannot be answered as written -- #{e.message}"
        end

        private

        def choices = @entries.grep(Choice)
        def marked = choices.select(&:ticked)
        def expected = @question.options[choices.size]

        def choose(number, match)
          option = expected
          refuse_unexpected!(number, match) unless offered?(match, option)
          @entries << Choice.new(number:, option:, ticked: mark(number, match[:mark]))
        end

        def offered?(match, option)
          !option.nil? && match[:id] == option.id && match[:label] == option.label
        end

        def mark(number, mark)
          MARK_SELECTIONS.fetch(mark) do
            raise MalformedDocument, "line #{number}: #{Document.named(mark)} is not a checkbox mark this " \
                                     "grammar writes (the marks are #{MARK_LEGEND})"
          end
        end

        # The comment is the region from the first indented line to the last,
        # blank lines inside it included -- which is what lets a human write two
        # paragraphs. Everything outside is separator.
        def comment
          first = @entries.index { |entry| entry.is_a?(Prose) }
          return nil if first.nil?

          last = @entries.rindex { |entry| entry.is_a?(Prose) }
          block = @entries[first..last]
          split!(block)
          block.map { |entry| entry.is_a?(Prose) ? entry.text : "" }.join("\n")
        end

        # One question has one comment, because {Answer} carries one. Refused
        # rather than joined: prose written under two different options means two
        # different things, and joining them would drop which option each note
        # was about. The message names the two PROSE ends -- what the human has
        # to merge -- rather than a divider between them, which would have meant
        # picking `first` or `last` arbitrarily.
        def split!(block)
          return if block.none?(Choice)

          raise MalformedDocument, "line #{block.first.number}: question #{@question.id.inspect} carries prose " \
                                   "here and again at line #{block.last.number}, with an option line between " \
                                   "them -- one question has one comment, so join them into one indented block"
        end

        def missing!
          absent = expected
          return if absent.nil?

          raise MalformedDocument, "question #{@question.id.inspect} is missing the option line for " \
                                   "#{absent.id.inspect} -- every option a question offers is rendered, and a " \
                                   "deleted line is an answer nobody can read back"
        end

        # {AnswerSet} refuses this too, but without a line number: by then the
        # answer is a value and the human is looking at a buffer.
        def single!
          return unless @question.single? && marked.size > 1

          raise MalformedDocument, "line #{marked[1].number}: question #{@question.id.inspect} takes one option " \
                                   "and #{marked.map { |entry| entry.option.id }.join(", ")} are marked"
        end

        def refuse_unexpected!(number, match)
          expected.nil? ? refuse_extra!(number, match) : refuse_wrong!(number, match)
        end

        def refuse_extra!(number, match)
          raise MalformedDocument, "line #{number}: question #{@question.id.inspect} offers " \
                                   "#{@question.options.size} options and this is another one " \
                                   "(#{match[0].inspect})"
        end

        def refuse_wrong!(number, match)
          raise MalformedDocument, "line #{number}: expected the option line for #{expected.id.inspect} " \
                                   "(#{Document.option_line(expected, false).inspect}), got #{match[0].inspect} " \
                                   "-- every option is rendered, in order, and only the mark is yours to change"
        end

        # The stray line, which is the whole of "nothing is silently
        # reinterpreted": a line here is either the grammar's or the human's, and
        # a line that is neither is an error naming it, not an answer nobody reads.
        def refuse_stray!(number, text)
          if text.match?(/\A[[:space:]]/)
            raise MalformedDocument, "line #{number}: #{text.inspect} begins with whitespace that is not the " \
                                     "two-space indent a comment is written with -- retype the indent (the " \
                                     "buffer is set to expandtab, shiftwidth=2)"
          end

          raise MalformedDocument, "line #{number}: #{text.inspect} is neither an option line nor a comment " \
                                   "(a comment is indented two spaces; an option line reads `- [ ] `id` label`)"
        end
      end
    end
  end
end
