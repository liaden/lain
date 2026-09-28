# frozen_string_literal: true

RSpec.describe Lain::QA::PlanCards do
  let(:plan) do
    <<~MD
      # A plan

      ## Tasks

      ### T1 — Add the order total          [wave 1] [risk: low]

      **Files:** `lib/app/order.rb` (create),
      `spec/app/order_spec.rb` (create)

      **Reuse:** `lib/app/money.rb`

      ```gherkin
      Scenario: the total sums the lines
        Given an order of two lines
        Then its total is their sum
      ```

      ### T2 — Wire the CLI          [wave 2] [risk: high]

      **Files:** `exe/app` (modify), `spec/app/cli_spec.rb` (modify)

      ```gherkin
      Scenario: the prompt shows the total
        Then the prompt reads "total: 3"
      ```

      ### T3 — A card that states no files and no risk

      ```gherkin
      Scenario: something is still asked of it
        Then it is asked
      ```
    MD
  end

  let(:cards) { described_class.read(plan) }

  it "reads each card's criteria, risk and claimed files as three separate answers" do
    expect(cards.map { |card| [card.id, card.risk, card.files, card.criteria.map(&:name)] }).to eq(
      [["T1", "low", %w[lib/app/order.rb spec/app/order_spec.rb], ["the total sums the lines"]],
       ["T2", "high", %w[exe/app spec/app/cli_spec.rb], ["the prompt shows the total"]],
       ["T3", "medium", [], ["something is still asked of it"]]]
    )
  end

  it "reads the backticked Files paragraph and nothing past it" do
    expect(cards.claims).to eq(
      "T1" => %w[lib/app/order.rb spec/app/order_spec.rb], "T2" => %w[exe/app spec/app/cli_spec.rb], "T3" => []
    )
  end

  # The grammar is a writing convention, not a schema, so a hand-written card
  # that states its files some other way must claim nothing rather than take
  # the whole pass down with it.
  it "reads a card with no Files paragraph as claiming nothing" do
    expect(described_class.read("### T9 — no files here\n").claims).to eq("T9" => [])
  end

  it "reads a card whose heading names no risk as medium" do
    expect(cards.find { |card| card.id == "T3" }.risk).to eq("medium")
  end

  it "reads a heading that names a risk outside the closed set as medium" do
    expect(described_class.read("### T9 — a card [risk: catastrophic]\n").first.risk).to eq("medium")
  end

  it "names the same path once however many times a card backticks it" do
    card = described_class.read("### T9 — a card\n\n**Files:** `a.rb` (new), `a.rb` again\n").first

    expect(card.files).to eq(["a.rb"])
  end

  it "refuses a card whose gherkin block never closes, rather than reading it as no criteria" do
    expect { described_class.read("### T9 — a card\n\n```gherkin\nScenario: unclosed\n") }
      .to raise_error(Lain::Gherkin::MalformedBlock)
  end

  # Silence about one PART of a card is a card with nothing to hold it to, and
  # is reported. Silence about the whole DOCUMENT is zero cards, zero claims
  # and zero findings, which reads exactly like a clean pass.
  describe "a document it recognises nothing in is refused, never read as a pass" do
    it "refuses prose that declares no cards at all" do
      expect { described_class.read("# just prose\n\n## a section\n") }
        .to raise_error(Lain::QA::PlanCards::MalformedPlan, /no cards/)
    end

    it "refuses a document whose headings are all prose rather than cards" do
      expect { described_class.read("### Notes on the wave\n\n**Files:** `a.rb`\n") }
        .to raise_error(Lain::QA::PlanCards::MalformedPlan, /no cards/)
    end

    it "refuses two cards sharing an id, which would collapse into one claim" do
      expect { described_class.read("### T9 — first\n\n**Files:** `a.rb`\n\n### T9 — second\n") }
        .to raise_error(Lain::QA::PlanCards::MalformedPlan, /T9/)
    end
  end

  # Plans are written in English and head their sections with English. A
  # recogniser that reads "The bench" as a card id invents claimants, and two
  # such headings in one document invent a duplicate id as well.
  describe "an English heading is prose, however it begins" do
    it "reads headings that merely start with T as prose" do
      prose = <<~MD
        ### The bench

        ### Three shapes considered, and why this one

        ### Two things that must never be confused

        ### T1 — the only card here [risk: low]

        **Files:** `a.rb`
      MD

      expect(described_class.read(prose).map(&:id)).to eq(["T1"])
    end

    # A plan discussing a card in prose has not reused its id, and an operator
    # sent hunting a duplicate that does not exist is worse than the phantom.
    it "reads a prose heading ABOUT a card as prose, not as a second card with that id" do
      plan = <<~MD
        ### T1's panel review restructured the plan (2026-09-20)

        ### T1 — Stand the loader up [risk: high]

        **Files:** `lib/lain.rb`
      MD

      expect(described_class.read(plan).map { |card| [card.id, card.files] }).to eq([["T1", ["lib/lain.rb"]]])
    end
  end

  # A plan quotes its own grammar, and a heading inside a fence that forked a
  # card would take the real card's criteria with it: the silent scenario loss
  # Gherkin exists to refuse, one layer up.
  it "reads a heading quoted inside a fence as prose, leaving the real card its criteria" do
    quoted = <<~MD
      ### T1 — the real card [risk: low]

      **Files:** `a.rb`

      The grammar looks like this:

      ```text
      ### T2 — a quoted heading
      **Files:** `stolen.rb`
      ```

      ```gherkin
      Scenario: belongs to the card above
        Then it does
      ```
    MD

    expect(described_class.read(quoted).map { |card| [card.id, card.files, card.criteria.map(&:name)] })
      .to eq([["T1", ["a.rb"], ["belongs to the card above"]]])
  end

  # A fence closes only on a run of its own character at least as long as the
  # opener, so a wrapping fence is how a document quotes a fence.
  it "reads a heading inside a four-backtick fence wrapping a three-backtick one as prose" do
    quoted = <<~MD
      ### T1 — the real card [risk: low]

      **Files:** `a.rb`

      ````markdown
      ```
      ### T2 — a quoted heading
      ```
      ````

      ```gherkin
      Scenario: belongs to the card above
        Then it does
      ```
    MD

    expect(described_class.read(quoted).map { |card| [card.id, card.criteria.map(&:name)] })
      .to eq([["T1", ["belongs to the card above"]]])
  end

  it "reads a heading inside a tilde fence as prose" do
    quoted = <<~MD
      ### T1 — the real card [risk: low]

      **Files:** `a.rb`

      ~~~text
      ### T2 — a quoted heading
      ~~~
    MD

    expect(described_class.read(quoted).map(&:id)).to eq(["T1"])
  end

  describe "a card is a value nobody downstream can edit" do
    subject(:card) do
      Lain::QA::PlanCards::Card.new(id: "T9", risk: "low", files: ["a.rb"],
                                    criteria: Lain::Gherkin::Criteria.parse(""))
    end

    it "is deeply frozen when built directly, not only through the reader" do
      expect(Ractor.shareable?(card)).to be(true)
    end

    it "refuses an edit to the files it claims" do
      expect { card.files << "sneaked.rb" }.to raise_error(FrozenError)
    end
  end

  it "reads a plan document as deeply frozen cards, so a reader cannot edit what QA is held to" do
    expect(cards.map { |card| Ractor.shareable?(card) }).to all(be(true))
  end

  it "is itself a frozen reading of the plan, claims included" do
    expect([cards.frozen?, cards.claims.frozen?]).to eq([true, true])
  end
end
