# frozen_string_literal: true

# The handoff's question, and the document its answer becomes. Both ends are a
# CONTRACT WITH A NEIGHBOUR: the slots are what the compaction fallback fills,
# and the document is the one message a handoff cut records as the replacement
# for everything it collapsed.
RSpec.describe Lain::Oracle::Handoff do
  let(:definition) { described_class.definition }

  let(:answer) do
    { "goal" => "ship the parser", "progress" => "lexer done", "files_and_decisions" => "lexer.rb, no regexes",
      "open_todos" => "the parser", "next_step" => "write parser.rb" }
  end

  def inputs(document: "", held: "", span: "", pins: "")
    { document:, held:, span:, pins: }
  end

  it "fills the three slots the fallback supplies" do
    rendered = definition.render(inputs(held: "an earlier summary", span: "user: hello", pins: "turn 3"))

    expect(rendered).to include("an earlier summary").and include("user: hello").and include("turn 3")
  end

  it "answers with the five state fields" do
    typed = definition.answer(answer).await

    expect([typed.goal, typed.progress, typed.files_and_decisions, typed.open_todos, typed.next_step])
      .to eq(["ship the parser", "lexer done", "lexer.rb, no regexes", "the parser", "write parser.rb"])
  end

  it "refuses an answer missing a state field rather than writing a partial document" do
    expect { definition.answer(answer.except("next_step")) }.to raise_error(Lain::Oracle::InvalidAnswer, /Next step/)
  end

  # The same reasoning the eager summarizer's template states: a provider that
  # ignores the structured-output constraint gets prose, which no decoder reads.
  it "asks for JSON in words, not only through the format constraint" do
    rendered = definition.render(inputs)

    expect(rendered).to match(/JSON object/i)
    expect(rendered).to include(%({"goal":))
  end

  describe ".document" do
    it "renders the five state headings" do
      document = described_class.document(definition.answer(answer).await)

      expect(document).to include("Goal").and include("Progress").and include("Files and decisions")
        .and include("Open todos").and include("Next step")
    end

    it "carries every answered field's text" do
      document = described_class.document(definition.answer(answer).await)

      expect(document).to include("ship the parser").and include("write parser.rb")
    end

    # A document that does not say it replaced a history reads as a note the
    # model wrote to itself, and the model then asks about turns that are gone.
    it "says the history it replaced is gone" do
      expect(described_class.document(definition.answer(answer).await)).to match(/replaced/i)
    end
  end

  describe ".line" do
    def text_turn(body) = { "role" => "user", "content" => [{ "type" => "text", "text" => body }] }

    it "keeps a short text turn's words" do
      expect(described_class.line(text_turn("find the bug"))).to include("user").and include("find the bug")
    end

    it "reduces a tool result to one line naming its size, not its bytes" do
      result = { "role" => "user",
                 "content" => [{ "type" => "tool_result", "tool_use_id" => "tu_1", "content" => "x" * 4096 }] }

      line = described_class.line(result)

      expect(line).to include("tu_1").and match(/\d+ bytes/)
      expect(line).not_to include("x" * 200)
      expect(line.lines.size).to eq(1)
    end

    it "names a tool call by the tool it called" do
      call = { "role" => "assistant",
               "content" => [{ "type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => {} }] }

      expect(described_class.line(call)).to include("read_file")
    end

    # A large TEXT block was the hole: a handoff fires because the prompt did
    # not fit, and the bulk is as likely to be assistant prose or a pasted blob
    # as a tool result. Every block kind is cut, or the oracle is shown the
    # bytes that were just refused.
    it "cuts a large text block to one line and says what it cost" do
      line = described_class.line(text_turn("z" * 300_000))

      expect(line.bytesize).to be < 400
      expect(line).to include("300000 bytes in full")
    end

    it "flattens a multi-line block, so one message is one line" do
      expect(described_class.line(text_turn("first\nsecond\nthird")).lines.size).to eq(1)
    end

    # A bare String content is a shape the Messages API accepts, and a line
    # that raised on one would raise inside the render path.
    it "reads a bare String content rather than raising on it" do
      expect(described_class.line({ "role" => "user", "content" => "plain" })).to include("plain")
    end
  end

  # The question's own input has to fit the window IT is asked in -- the
  # summarizer tier's, which is not the chat's -- or the handoff fails on the
  # very prompt it exists to answer.
  describe ".question" do
    # The two windows that matter: what a book that cannot identify a local
    # model answers, and what a local runner usually serves.
    def fallback_window = Lain::ContextWindow::CONSERVATIVE_FALLBACK

    def served_window = 32_768

    def text_turn(index, body)
      { "role" => index.odd? ? "user" : "assistant",
        "content" => [{ "type" => "text", "text" => body }] }
    end

    def slots(held: [], span: [], pins: [], document: nil, window: nil)
      described_class.question(held:, span:, pins:, document:,
                               budget: described_class.budget_for(window || fallback_window))
    end

    def total(question) = question.values.sum(&:bytesize)

    def prose(count)
      (1..count).map { |index| text_turn(index, "turn #{index}: #{"the lazy dog slept through it. " * 30}") }
    end

    # What the whole request costs at the WORST density ever measured, which
    # is the number the budget is derived against: the rendered question, the
    # JSON schema that rides beside it, and the answer's own ceiling.
    def request_tokens(question)
      bytes = described_class.definition.render(**question).bytesize +
              described_class::SCHEMA.to_json_schema.to_s.bytesize
      (bytes / described_class::BYTES_PER_TOKEN).ceil + Lain::Oracle::Model::DEFAULT_MAX_TOKENS
    end

    it "fills the four slots the template names" do
      question = slots(held: [text_turn(1, "an earlier summary")], span: [text_turn(1, "hello")],
                       pins: [text_turn(1, "a pinned turn")])

      expect(question.keys).to contain_exactly(:document, :held, :span, :pins)
      expect(question[:held]).to include("an earlier summary")
      expect(question[:span]).to include("hello")
      expect(question[:pins]).to include("a pinned turn")
    end

    it "heads each section it fills" do
      question = slots(span: [text_turn(1, "hello")])

      expect(question[:span]).to start_with(described_class::SECTIONS.fetch(:span))
    end

    # A heading over nothing tells the model there were pins, or summaries,
    # and then shows it none.
    it "prints no heading over a slot it had nothing for" do
      question = slots(span: [text_turn(1, "hello")])

      expect(question[:held]).to eq("")
      expect(question[:pins]).to eq("")
      expect(described_class.definition.render(**question))
        .not_to include(described_class::SECTIONS.fetch(:pins))
    end

    describe "the previous state document" do
      def document(text = "a" * 980)
        Lain::Oracle::Handoff::Document.from_answer(
          "goal" => text, "progress" => "p", "files_and_decisions" => "f", "open_todos" => "o", "next_step" => "n"
        )
      end

      it "is carried byte for byte, under its own heading" do
        previous = document

        question = slots(document: previous, span: prose(400))

        expect(question[:document]).to include(previous.to_s)
        expect(question[:document]).to start_with(described_class::SECTIONS.fetch(:document))
      end

      it "prints no heading when there is no previous document" do
        expect(slots(span: prose(3))[:document]).to eq("")
      end

      it "stays whole however little budget is left for the turns" do
        previous = document("a" * 20_000)

        question = slots(document: previous, span: prose(400))

        expect(question[:document]).to include(previous.to_s)
      end

      it "is spent before the turns are" do
        question = slots(document:, span: prose(400))

        expect(total(question)).to be <= described_class.budget_for(fallback_window)
        expect(question[:span]).to include("turn 400:")
      end
    end

    describe "turns since the last handoff" do
      def turns(count, size) = (1..count).map { |index| text_turn(index, "turn #{index}: #{"w" * size}") }

      it "appear whole while the budget holds" do
        span = turns(3, 900)

        expect(slots(span:, window: served_window)[:span].scan("w" * 900).size).to eq(3)
      end

      it "stub the oldest and keep the newest whole once the budget binds, the document whole throughout" do
        budget = described_class.budget_for(fallback_window)
        span = turns((2 * budget / 900) + 1, 900)
        previous = "previous document #{"d" * 980}"

        question = slots(span:, document: previous)

        expect(question[:document]).to include(previous)
        expect(question[:span]).to include("turn #{span.size}: #{"w" * 900}")
        expect(question[:span].lines.grep(/turn 1: /).first).to include("bytes in full")
        expect(total(question)).to be <= budget + previous.bytesize
      end

      # Exact to the byte: the budget that just buys the newest turn whole
      # does, and one byte less leaves it a stub.
      it "widens the newest turn at exactly the budget that pays for it, and not a byte sooner" do
        span = turns(2, 900)
        heading = described_class::SECTIONS.fetch(:span)
        stubs = span.sum { |turn| described_class.line(turn).bytesize + 1 }
        upgrade = described_class.whole(span.last).bytesize - described_class.line(span.last).bytesize
        exact = heading.bytesize + 2 + stubs + upgrade

        at = described_class.question(held: [], span:, pins: [], budget: exact)
        under = described_class.question(held: [], span:, pins: [], budget: exact - 1)

        expect(at[:span]).to include("turn 2: #{"w" * 900}")
        expect(total(at)).to eq(exact)
        expect(under[:span]).not_to include("turn 2: #{"w" * 900}")
      end

      # Widening spends only what every slot has left after it was afforded at
      # cut length, so it can never take the room the notice was reserved.
      it "never lose turns without saying so, however the leftover falls" do
        rng = Random.new(1)
        silent = Array.new(300) do
          span = Array.new(rng.rand(1..80)) { |index| text_turn(index, "t#{index} #{"x" * rng.rand(1..900)}") }
          rendered = slots(span:)[:span]
          shown = rendered.lines.count { |line| line.start_with?("user: t", "assistant: t") }
          span.size if shown < span.size && !rendered.include?("elided")
        end.compact

        expect(silent).to be_empty
      end

      it "keeps the newest turn when earlier summaries are large" do
        held = [text_turn(1, "s" * 3_400), text_turn(2, "s" * 4_100)]

        question = slots(held:, span: turns(13, 900))

        expect(question[:span]).to include("turn 13: ")
        expect(question[:held]).not_to include("s" * 3_400)
      end
    end

    describe ".budget_for" do
      it "sizes the budget to the window it is handed, not to a fixed assumption" do
        expect(described_class.budget_for(fallback_window)).to eq(7_713)
        expect(described_class.budget_for(served_window)).to eq(39_907)
      end

      # A window smaller than the reserve buys no room at all, which is a
      # budget of zero rather than a negative one.
      it "answers zero for a window the reserve alone exhausts" do
        expect(described_class.budget_for(described_class::RESERVED_TOKENS)).to eq(0)
        expect(described_class.budget_for(64)).to eq(0)
      end
    end

    # The two prose histories the review measured, at each window. "Comes in
    # under" is the whole request measured in tokens at the worst density --
    # the question, the schema and the answer's ceiling -- not merely the
    # slots.
    [120, 400].each do |turns|
      it "keeps a #{turns}-turn prose history inside the conservative window" do
        question = slots(span: prose(turns), window: fallback_window)

        expect(total(question)).to be <= described_class.budget_for(fallback_window)
        expect(request_tokens(question)).to be <= fallback_window
      end

      it "keeps a #{turns}-turn prose history inside a served 32,768 window" do
        question = slots(span: prose(turns), window: served_window)

        expect(total(question)).to be <= described_class.budget_for(served_window)
        expect(request_tokens(question)).to be <= served_window
      end
    end

    it "spends the bigger window on more of the history" do
      span = prose(400)

      expect(slots(span:, window: served_window)[:span].lines.size)
        .to be > slots(span:, window: fallback_window)[:span].lines.size
    end

    # The newest turns are the ones that survive: what a reader needs to carry
    # the work on is what just happened, not the opening of the conversation.
    it "keeps the newest turns and says how many earlier ones went" do
      rendered = slots(span: prose(400))[:span]

      expect(rendered).to include("turn 400:")
      expect(rendered).not_to include("turn 1:")
      expect(rendered.lines[2]).to match(/\A\[\d+ earlier turn\(s\) elided/)
    end

    # The pathological shape: one turn so large that even its single line
    # would be the whole budget. It is cut by {.line} before the budget ever
    # sees it.
    it "stays inside the budget for one huge turn" do
      question = slots(span: [text_turn(1, "z" * 4_000_000)])

      expect(total(question)).to be <= described_class.budget_for(fallback_window)
      expect(question[:span]).to include("4000000 bytes in full")
    end

    it "stays inside the budget when every slot is oversized" do
      bulk = (1..200).map { |index| text_turn(index, "x" * 50_000) }

      expect(total(slots(held: bulk, span: bulk, pins: bulk)))
        .to be <= described_class.budget_for(fallback_window)
    end

    # The held replacements are the only account of a history nothing else
    # carries, so they are asked for first and take the budget first.
    it "spends the budget on the held replacements before the span" do
      held = (1..100).map { |index| text_turn(index, "summary #{index}: #{"y" * 190}") }

      question = slots(held:, span: prose(400), window: served_window)

      expect(question[:held]).to include("summary 1:").and include("summary 100:")
      expect(question[:held]).not_to include("elided")
      expect(question[:span]).to include("elided")
      expect(total(question)).to be <= described_class.budget_for(served_window)
    end

    it "elides nothing, and says nothing, when everything fits" do
      question = slots(span: [text_turn(1, "hello")])

      expect(question[:span]).to end_with("user: hello\n")
      expect(question[:span]).not_to include("elided")
    end
  end
end
