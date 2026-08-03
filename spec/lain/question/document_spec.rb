# frozen_string_literal: true

# The answer document: the markdown a human edits in nvim, and the parse that
# reads those edits back into an {Lain::Question::AnswerSet}.
#
# Two laws carry the weight, and they are Epic::Document's. The round trip is
# TOTAL -- an answer set rendered and parsed again is the same answer set, or
# the emit is refused loudly naming the value it cannot write. And nothing is
# silently reinterpreted: a line the grammar has no slot for is an error naming
# it, never prose the human never sees again.
#
# The parse is GIVEN the set it is parsing, which is what makes both possible:
# the question body is compared against the set's own bytes and skipped whole,
# so a fenced `- [x]` or `##` inside a body is never read as grammar and no
# fence state is tracked anywhere.
RSpec.describe Lain::Question::Document do
  def option(id, label) = Lain::Question::Option.new(id:, label:)

  def question(id, body:, options: [], arity: Lain::Question::SINGLE)
    Lain::Question.new(id:, body:, options:, arity:)
  end

  def set(*questions) = Lain::Question::Set.new(questions:)

  def answer(id, option_ids: [], comment: nil)
    Lain::Question::Answer.new(question_id: id, option_ids:, comment:)
  end

  def answer_set(questions, *answers, text: nil)
    Lain::Question::AnswerSet.new(questions:, answers:, text:)
  end

  def render(answers) = described_class.to_markdown(answers)
  def parse(markdown, questions = asked) = described_class.parse_markdown(markdown, questions)

  let(:storage) do
    question("storage", body: "Which storage engine?",
                        options: [option("postgres", "PostgreSQL"), option("sqlite", "SQLite")])
  end

  let(:checks) do
    question("checks", body: "Which checks should run?", arity: Lain::Question::MULTI,
                       options: [option("lint", "RuboCop"), option("test", "RSpec")])
  end

  let(:notes) { question("notes", body: "Anything else?") }
  let(:asked) { set(storage, checks, notes) }
  let(:document) { described_class.unanswered(asked) }

  describe "the document a human is handed" do
    it "renders one section per question, in the order they were asked" do
      expect(document).to eq(<<~MARKDOWN)
        ## `storage` (choose one)
        Which storage engine?

        - [ ] `postgres` PostgreSQL
        - [ ] `sqlite` SQLite

        ## `checks` (choose any)
        Which checks should run?

        - [ ] `lint` RuboCop
        - [ ] `test` RSpec

        ## `notes` (write your answer below)
        Anything else?
      MARKDOWN
    end

    it "renders a selection as a ticked box and a comment as indented prose beneath the options" do
      answered = answer_set(asked, answer("storage", option_ids: %w[sqlite], comment: "no server to run"),
                            answer("checks", option_ids: %w[lint test]), answer("notes", comment: "nothing else"))

      expect(render(answered)).to eq(<<~MARKDOWN)
        ## `storage` (choose one)
        Which storage engine?

        - [ ] `postgres` PostgreSQL
        - [x] `sqlite` SQLite

          no server to run

        ## `checks` (choose any)
        Which checks should run?

        - [x] `lint` RuboCop
        - [x] `test` RSpec

        ## `notes` (write your answer below)
        Anything else?

          nothing else
      MARKDOWN
    end

    it "renders the question body verbatim, fences and all" do
      fenced = question("fenced", body: "Which one?\n\n```diff\n- [x] no\n## no\n```")

      expect(described_class.unanswered(set(fenced))).to include("```diff\n- [x] no\n## no\n```")
    end
  end

  # AC: parsing takes the set it is parsing.
  describe "parsing against the set that was rendered" do
    it "answers exactly the questions the set asked" do
      parsed = parse(document)

      expect(parsed).to be_a(Lain::Question::AnswerSet)
      expect(parsed.questions).to eq(asked)
      expect(parsed.ids).to eq(%w[storage checks notes])
    end

    it "reads an untouched document as every question unanswered" do
      expect(parse(document).none?(&:answered?)).to be(true)
    end
  end

  # AC: a ticked checkbox becomes a selection.
  describe "a ticked checkbox" do
    it "selects exactly the option whose line was ticked" do
      ticked = document.sub("- [ ] `sqlite` SQLite", "- [x] `sqlite` SQLite")

      expect(parse(ticked).fetch("storage").option_ids).to eq(%w[sqlite])
      expect(parse(ticked).fetch("checks").option_ids).to be_empty
    end

    it "accumulates ticks on a multi-select question" do
      ticked = document.sub("- [ ] `lint`", "- [x] `lint`").sub("- [ ] `test`", "- [x] `test`")

      expect(parse(ticked).fetch("checks").option_ids).to eq(%w[lint test])
    end
  end

  # AC: indented prose beneath an option becomes that option's comment.
  describe "indented prose" do
    it "carries every line of the block as the question's comment" do
      ticked = document.sub("- [ ] `sqlite` SQLite\n", "- [x] `sqlite` SQLite\n  it is embedded\n  and cheap\n")

      expect(parse(ticked).fetch("storage").option_ids).to eq(%w[sqlite])
      expect(parse(ticked).fetch("storage").comment).to eq("it is embedded\nand cheap")
    end

    it "answers a free-text question with prose alone" do
      written = document.sub("Anything else?\n", "Anything else?\n\n  ship it on friday\n")

      expect(parse(written).fetch("notes").comment).to eq("ship it on friday")
    end

    it "keeps a blank line inside the block and drops the blanks around it" do
      written = document.sub("Anything else?\n", "Anything else?\n\n\n  one\n\n  two\n\n")

      expect(parse(written).fetch("notes").comment).to eq("one\n\ntwo")
    end

    it "keeps indentation deeper than the grammar's own" do
      written = document.sub("Anything else?\n", "Anything else?\n\n  list:\n    - a\n")

      expect(parse(written).fetch("notes").comment).to eq("list:\n  - a")
    end
  end

  # AC: a question body containing grammar-shaped text is never read as grammar.
  describe "a body that shows the grammar" do
    let(:fenced) do
      question("fenced", body: "Is this diff right?\n\n```\n- [x] no\n## no\n```",
                         options: [option("yes", "Yes"), option("no", "No")])
    end
    let(:asked) { set(fenced, checks) }

    it "takes no selection from the fence and parses" do
      parsed = parse(described_class.unanswered(asked))

      expect(parsed.fetch("fenced").option_ids).to be_empty
      expect(parsed.fetch("fenced")).not_to be_answered
    end

    it "still reads the answer written below the fence" do
      ticked = described_class.unanswered(asked).sub("- [ ] `no` No", "- [x] `no` No")

      expect(parse(ticked).fetch("fenced").option_ids).to eq(%w[no])
    end
  end

  # AC: an unbalanced fence typed by the human cannot swallow the document.
  describe "an unbalanced fence in the human's comment" do
    it "recovers the selections of every later question" do
      typed = document.sub("- [ ] `sqlite` SQLite\n", "- [ ] `sqlite` SQLite\n  ```\n  half a fence\n")
                      .sub("- [ ] `test` RSpec", "- [x] `test` RSpec")

      expect(parse(typed).fetch("storage").comment).to eq("```\nhalf a fence")
      expect(parse(typed).fetch("checks").option_ids).to eq(%w[test])
    end
  end

  # AC: the round trip is identity for an arbitrary answer set.
  # A deterministic population rather than a random generator, which is how
  # this repo property-tests elsewhere (spec/support/algebra_generators.rb):
  # every selection shape crossed with every comment shape that a human can
  # type, so a failure names the same case on every run.
  describe "the round trip" do
    comments = [nil, "one line", "two\nlines", "a\n\nb", "  already indented", "- [x] not an option",
                "```", "## `x` (choose one)", "\ttabbed", "über"]

    def candidates(id, selections, comments)
      selections.product(comments).map { |option_ids, comment| answer(id, option_ids:, comment:) }
    end

    let(:population) do
      lists = [candidates("storage", [[], %w[postgres], %w[sqlite]], comments),
               candidates("checks", [[], %w[lint], %w[lint test]], comments),
               candidates("notes", [[]], comments)]
      Array.new(lists.map(&:size).max) do |index|
        answer_set(asked, *lists.map { |list| list[index % list.size] })
      end
    end

    it "parses back to the answer set it was rendered from" do
      expect(population.map { |answers| parse(render(answers)) }).to eq(population)
    end

    # AC: re-rendering a parsed document is byte-identical.
    it "re-renders byte-identically" do
      rendered = population.map { |answers| render(answers) }

      expect(rendered.map { |markdown| render(parse(markdown)) }).to eq(rendered)
    end
  end

  # The review panel's fuzzer, ported in as a bounded deterministic case: it is
  # what found B1 (a label ending in a space, emitted at end-of-line, refused by
  # the parse that strips it), and an emit-then-parse identity property is the
  # guard that keeps that whole class out. The 30-case population above varies
  # comments only; this varies labels, bodies, arities, option counts and
  # selections too.
  #
  # Seeded per iteration rather than per run, so a failure names one reproducible
  # case. The trailing-whitespace fragments are kept in the alphabet ON PURPOSE:
  # they are now refused at construction, so the generator skips them -- delete
  # that rule and they build, emit, and fail the parse right here.
  describe "the emitted document, over a generated population" do
    let(:fragments) do
      ["plain", "über ünïcödé", "日本語", "a `backtick` span", "- [x] not an option", "## `x` (choose one)",
       "```", "```ruby", "~~~", "> quote", "# hash", "  deeper", "\tTABBED", "|table|cell|", "-", "* star",
       "1. num", "[]", "[ ]", "- [ ] `x` y", "###", "## no", "\\", "\"quotes\"", "e" * 120, "\r", "mid\rcr",
       "nbsp_tail\u00A0", "zw_tail\u200B", " leading", "trailing ", "tab_tail\t", "\u00A0"]
    end
    let(:documents) do
      [7, 99, 424_242].flat_map { |seed| (1..120).filter_map { |run| emitted(generated(seed + run)) } }
    end

    # nil is the generator finding a LEGAL refusal -- an unbalanced fence, a
    # forged heading, a label the document could not read back. Those are the
    # value objects working, not a defect, so the case is dropped.
    def generated_question(rng, index)
      options = Array.new(rng.rand(0..4)) { |i| option("o#{index}-#{i}", fragments.sample(random: rng)) }
      question("q#{index}", options:, body: Array.new(rng.rand(1..8)) { fragments.sample(random: rng) }.join("\n"),
                            arity: rng.rand < 0.5 ? Lain::Question::SINGLE : Lain::Question::MULTI)
    rescue ArgumentError
      nil
    end

    def generated_comment(rng)
      return nil if rng.rand < 0.15

      Array.new(rng.rand(1..6)) { rng.rand < 0.2 ? "" : fragments.sample(random: rng) }.join("\n")
    end

    def generated_answer(rng, asked_question)
      chosen = asked_question.options.map(&:id).select { rng.rand < 0.4 }
      answer(asked_question.id, comment: generated_comment(rng),
                                option_ids: asked_question.single? ? chosen.first(1) : chosen)
    rescue ArgumentError
      nil
    end

    def generated(seed)
      rng = Random.new(seed)
      questions = Array.new(rng.rand(1..4)) { |index| generated_question(rng, index) }.compact
      return nil if questions.empty?

      built(set(*questions), rng)
    end

    def built(asked_set, rng)
      answers = asked_set.map { |asked_question| generated_answer(rng, asked_question) }
      return nil if answers.any?(&:nil?)

      answer_set(asked_set, *answers)
    rescue ArgumentError
      nil
    end

    # A comment the writer refuses is the emit rules working (bytes the parse
    # would strip), so it is dropped here too. What is left is every document
    # the writer actually produces.
    def emitted(answers)
      return nil if answers.nil?

      [answers, render(answers)]
    rescue Lain::Question::MalformedDocument
      nil
    end

    it "parses every document it emits back to identity, and re-renders each byte-identically" do
      parsed = documents.map { |answers, markdown| parse(markdown, answers.questions) }

      expect(documents.size).to be > 100 # a population that generated nothing would pass the rest vacuously
      expect(parsed).to eq(documents.map(&:first))
      expect(parsed.map { |answers| render(answers) }).to eq(documents.map(&:last))
    end
  end

  # AC: arity is recoverable from the text alone.
  #
  # This is T13's keymap in the small: `x` must know an option's siblings and
  # its question's arity with no RPC, so everything below reads the buffer text
  # and nothing else.
  describe "what the editor can recover from the buffer alone" do
    # The question the line at +index+ belongs to: from the nearest heading at
    # or above it, to the one below it.
    def bounds(lines, index)
      headings = lines.each_index.select { |line| described_class::HEADING.match?(lines[line]) }
      (headings.reverse.find { |line| line <= index })...(headings.find { |line| line > index } || lines.size)
    end

    def scan(markdown, index)
      lines = markdown.lines.map(&:chomp)
      within = bounds(lines, index)
      heading = described_class::HEADING.match(lines[within.first])
      { id: heading[:id], kind: heading[:kind],
        siblings: within.select { |line| described_class::OPTION.match?(lines[line]) } }
    end

    def line_of(markdown, text) = markdown.lines.map(&:chomp).index(text)

    it "distinguishes a single-select option from a multi-select one" do
      single = scan(document, line_of(document, "- [ ] `sqlite` SQLite"))
      multi = scan(document, line_of(document, "- [ ] `test` RSpec"))

      expect(single[:kind]).to eq("choose one")
      expect(multi[:kind]).to eq("choose any")
    end

    it "recovers the question a line belongs to and its sibling options" do
      scanned = scan(document, line_of(document, "- [ ] `sqlite` SQLite"))

      expect(scanned[:id]).to eq("storage")
      expect(scanned[:siblings]).to eq([line_of(document, "- [ ] `postgres` PostgreSQL"),
                                        line_of(document, "- [ ] `sqlite` SQLite")])
    end

    it "recovers a question's boundary with a comment block inside it" do
      typed = document.sub("- [ ] `sqlite` SQLite\n", "- [x] `sqlite` SQLite\n  because\n")
      scanned = scan(typed, line_of(typed, "- [ ] `test` RSpec"))

      expect(scanned[:id]).to eq("checks")
      expect(scanned[:siblings].size).to eq(2)
    end
  end

  # AC: an unknown line is refused, never reinterpreted.
  describe "a line the grammar has no slot for" do
    it "refuses a stray unindented line, naming the line number" do
      stray = document.sub("- [ ] `postgres` PostgreSQL\n", "- [ ] `postgres` PostgreSQL\nstray\n")

      expect { parse(stray) }
        .to raise_error(Lain::Question::MalformedDocument, /line 5.*"stray".*neither an option line nor a comment/m)
    end

    # Both halves of `refuse_stray!` are pinned on a phrase only that half says.
    # They were not: both messages carried "two spaces", so collapsing the tab
    # branch into the generic one survived the whole suite. An assertion both
    # branches satisfy tests neither.
    it "refuses a line indented with a tab, naming the indent it wanted" do
      tabbed = document.sub("Anything else?\n", "Anything else?\n\n\tprose\n")

      expect { parse(tabbed) }.to raise_error(Lain::Question::MalformedDocument, /begins with whitespace/)
    end

    it "refuses a blank line above the first question rather than quietly dropping it" do
      expect { parse("\n#{document}") }
        .to raise_error(Lain::Question::MalformedDocument, /line 1.*storage/m)
    end

    it "refuses an edited question body, naming the line" do
      edited = document.sub("Which storage engine?", "Which storage engine, really?")

      expect { parse(edited) }.to raise_error(Lain::Question::MalformedDocument, /line 2.*verbatim/m)
    end

    it "refuses a document whose questions were reordered" do
      reordered = document.lines.rotate(6).join

      expect { parse(reordered) }.to raise_error(Lain::Question::MalformedDocument, /line 1.*storage/m)
    end

    it "refuses an empty document, naming the question it wanted" do
      expect { parse("") }.to raise_error(Lain::Question::MalformedDocument, /end of the document/)
    end
  end

  # AC: a mangled checkbox mark is refused by name.
  describe "a mangled checkbox" do
    it "refuses the mark, naming it and the legal marks" do
      mangled = document.sub("- [ ] `sqlite`", "- [?] `sqlite`")

      expect { parse(mangled) }.to raise_error(Lain::Question::MalformedDocument, /"\?".*\[x\].*\[ \]/m)
    end

    it "refuses an uppercase X rather than reading it as a tick" do
      mangled = document.sub("- [ ] `sqlite`", "- [X] `sqlite`")

      expect { parse(mangled) }.to raise_error(Lain::Question::MalformedDocument, /"X"/)
    end

    # `inspect` renders U+00A0 as a space, so the human was shown an offending
    # mark visually identical to the legal one named in the same sentence -- the
    # one error here nobody could act on. The codepoint is what makes it
    # actionable; an editor or an autocorrect puts this character in far more
    # easily than a human does.
    it "names an invisible mark by codepoint, since it looks exactly like the legal one" do
      mangled = document.sub("- [ ] `sqlite`", "- [\u00A0] `sqlite`")

      expect { parse(mangled) }.to raise_error(Lain::Question::MalformedDocument, /U\+00A0/)
    end

    it "names a zero-width mark by codepoint too, which inspect renders as nothing at all" do
      mangled = document.sub("- [ ] `sqlite`", "- [\u200B] `sqlite`")

      expect { parse(mangled) }.to raise_error(Lain::Question::MalformedDocument, /U\+200B/)
    end
  end

  describe "an option line that is not the one the set offers" do
    it "refuses an edited option label" do
      edited = document.sub("`sqlite` SQLite", "`sqlite` SQLite (fast)")

      expect { parse(edited) }.to raise_error(Lain::Question::MalformedDocument, /line 5.*sqlite/m)
    end

    it "refuses a deleted option line, naming the option" do
      deleted = document.sub("- [ ] `sqlite` SQLite\n", "")

      expect { parse(deleted) }.to raise_error(Lain::Question::MalformedDocument, /"sqlite"/)
    end

    it "refuses an option line the question does not offer" do
      extra = document.sub("- [ ] `sqlite` SQLite\n", "- [ ] `sqlite` SQLite\n- [ ] `duckdb` DuckDB\n")

      expect { parse(extra) }.to raise_error(Lain::Question::MalformedDocument, /line 6/)
    end
  end

  describe "an answer the value objects refuse" do
    it "refuses two ticks on a single-select question, naming the second line" do
      both = document.sub("- [ ] `postgres`", "- [x] `postgres`").sub("- [ ] `sqlite`", "- [x] `sqlite`")

      expect { parse(both) }.to raise_error(Lain::Question::MalformedDocument, /line 5.*one option/m)
    end

    # Two option lines between the two blocks, deliberately: with one, naming
    # the first divider and naming the last are the same answer, and the choice
    # between them is unobservable. The message names the two PROSE lines, which
    # are what the human has to merge.
    it "refuses prose written above and below the options, naming both blocks" do
      split = document.sub("- [ ] `lint` RuboCop\n", "  above\n- [ ] `lint` RuboCop\n")
                      .sub("- [ ] `test` RSpec\n", "- [ ] `test` RSpec\n  below\n")

      expect { parse(split) }
        .to raise_error(Lain::Question::MalformedDocument, /line 10.*line 13.*one comment/m)
    end
  end

  describe "a value this grammar cannot write back" do
    it "refuses an answer set answered in prose at the terminal" do
      spoken = answer_set(asked, text: "just use sqlite")

      expect { render(spoken) }.to raise_error(Lain::Question::MalformedDocument, /prose/)
    end

    it "refuses a comment whose line ends in whitespace" do
      trailing = answer_set(asked, answer("notes", comment: "one \ntwo"))

      expect { render(trailing) }.to raise_error(Lain::Question::MalformedDocument, /line ending in whitespace/)
    end

    it "refuses a comment that ends in a line break" do
      terminated = answer_set(asked, answer("notes", comment: "one\n"))

      expect { render(terminated) }.to raise_error(Lain::Question::MalformedDocument, /cannot end in whitespace/)
    end

    it "refuses a comment that begins with a blank line" do
      leading = answer_set(asked, answer("notes", comment: "\none"))

      expect { render(leading) }.to raise_error(Lain::Question::MalformedDocument, /cannot begin with a blank line/)
    end
  end

  # The one rule this grammar puts on a body is enforced where the body is
  # BUILT, by {Lain::Question::DOCUMENT_HEADING} -- a refusal at render would
  # fire after the question was already pending, and leave a human an inbox item
  # that cannot be opened.
  #
  # Question loads before this file and cannot reach forward to it, so it holds
  # its own copy of the heading shape. This is where the two copies are held to
  # each other: change a label in KIND_LABELS and these fail, rather than the
  # construction rule silently widening what a body may hold.
  describe "the copy of this heading that Question enforces" do
    it "matches every heading this grammar writes, under both patterns" do
      headings = [storage, checks, notes].map { |asked| described_class.heading(asked) }

      expect(headings.grep(Lain::Question::DOCUMENT_HEADING)).to eq(headings)
      expect(headings.grep(described_class::HEADING)).to eq(headings)
    end

    it "refuses a body holding a heading for every kind this grammar can write" do
      described_class::KIND_LABELS.each_value do |label|
        expect { question("q", body: "Pick one:\n\n## `other` (#{label})") }
          .to raise_error(ArgumentError, /question heading/)
      end
    end

    it "refuses a body holding the heading of a question that was already built" do
      expect { question("q", body: described_class.heading(storage)) }
        .to raise_error(ArgumentError, /question heading/)
    end
  end
end
