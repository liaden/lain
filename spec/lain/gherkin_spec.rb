# frozen_string_literal: true

RSpec.describe Lain::Gherkin::Criteria do
  # Two fenced ```gherkin blocks in one markdown doc, as a plan doc carries them.
  # The second scenario is rubric-flagged by a `# rubric` line sitting on its own
  # line immediately before its `Scenario:` line.
  let(:markdown) do
    <<~MD
      Some prose introducing the plan.

      ```gherkin
      Scenario: mechanical one
        Given a fixture project
        When the suite runs
        Then it passes
        And the digest is stable
      ```

      More prose between the blocks.

      ```gherkin
      # rubric
      Scenario: judged one
        Given a transcript
        Then a human agrees it reads well
      ```
    MD
  end

  describe ".parse" do
    it "materializes one scenario per block in document order with ordered clauses" do
      criteria = described_class.parse(markdown)

      expect(criteria.scenarios.map(&:name)).to eq(["mechanical one", "judged one"])
      first = criteria.scenarios.first
      expect(first.clauses.map(&:keyword)).to eq(%w[Given When Then And])
      expect(first.clauses.map(&:text)).to eq(["a fixture project", "the suite runs", "it passes",
                                               "the digest is stable"])
    end

    it "produces a content-addressed digest" do
      expect(described_class.parse(markdown).digest).to start_with("blake3:")
    end

    it "flags the rubric-marked scenario as mechanical: false and leaves the other true" do
      by_name = described_class.parse(markdown).to_h { |scenario| [scenario.name, scenario.mechanical] }

      expect(by_name).to eq("mechanical one" => true, "judged one" => false)
    end

    it "yields the same digest when the same text is parsed twice" do
      expect(described_class.parse(markdown).digest).to eq(described_class.parse(markdown).digest)
    end

    it "changes the digest when a single clause changes" do
      edited = described_class.parse(markdown.sub("it passes", "it fails"))

      expect(edited.digest).not_to eq(described_class.parse(markdown).digest)
    end

    it "joins a wrapped continuation line into its preceding clause (the house format)" do
      wrapped = <<~MD
        ```gherkin
        Scenario: a wrapped clause
          Then the request is a POST to
          https://example.com/anthropic/v1/messages
          (the path suffix survives the URL join)
        ```
      MD

      clause = described_class.parse(wrapped).scenarios.first.clauses.first
      expect(clause.text).to eq(
        "the request is a POST to https://example.com/anthropic/v1/messages (the path suffix survives the URL join)"
      )
    end

    it "ignores non-rubric comment lines" do
      annotated = <<~MD
        ```gherkin
        Scenario: annotated
          Given a fixture
          # this comment is an annotation, not a clause
          Then it holds
        ```
      MD

      scenario = described_class.parse(annotated).scenarios.first
      expect(scenario.clauses.map(&:keyword)).to eq(%w[Given Then])
    end

    it "collects nothing from prose with no fenced gherkin block" do
      criteria = described_class.parse("no blocks here at all")

      expect(criteria.scenarios).to be_empty
    end
  end

  describe "malformed blocks raise naming the line" do
    it "rejects a clause before any Scenario:" do
      source = "```gherkin\n  Given a stray clause\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 2/)
    end

    it "rejects a continuation line with no clause to attach it to" do
      source = "```gherkin\nScenario: empty then text\n  loose prose with no clause\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 3/)
    end

    it "rejects an And with no preceding Given/When/Then" do
      source = "```gherkin\nScenario: bad and\n  And nothing came before\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 3/)
    end

    it "rejects a Scenario: with no name" do
      source = "```gherkin\nScenario:\n  Given x\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 2/)
    end

    it "rejects a # rubric line not immediately preceding a Scenario:, naming the marker line" do
      source = "```gherkin\n# rubric\n\nScenario: too far\n  Given x\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 2/)
    end

    it "rejects a # rubric sitting in the middle of a scenario's clauses, naming the marker line" do
      source = "```gherkin\nScenario: misplaced\n  Given x\n# rubric\n  Then y\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 4/)
    end

    it "rejects a # rubric marker that ends the block, naming the marker line" do
      source = "```gherkin\nScenario: x\n  Given a\n# rubric\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 4/)
    end
  end

  describe "unclosed and empty fences (loud-failure doctrine)" do
    it "raises naming the opener line when a ```gherkin fence never closes" do
      source = "intro line\n\n```gherkin\nScenario: dropped\n  Given a\n  Then b\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 3/)
    end

    it "raises naming the first opener when a second fence opens before the first closes" do
      source = "```gherkin\nScenario: a\n  Given x\n```gherkin\nScenario: b\n  Given y\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 1/)
    end

    it "raises naming the opener line for an empty block" do
      expect { described_class.parse("```gherkin\n```\n") }.to raise_error(Lain::Gherkin::MalformedBlock, /line 1/)
    end

    it "raises naming the opener line for a whitespace-only block" do
      expect do
        described_class.parse("prose\n\n```gherkin\n   \n\n```\n")
      end.to raise_error(Lain::Gherkin::MalformedBlock, /line 3/)
    end

    it "recognizes a bare ```gherkin opener" do
      source = "```gherkin\nScenario: x\n  Given a\n```\n"

      expect(described_class.parse(source).scenarios.map(&:name)).to eq(["x"])
    end

    # A gherkin fence carrying an info-string (```gherkin title=demo) is recognized
    # as gherkin -- so its block is never silently dropped -- but the house grammar
    # is bare-only, so a decorated opener fails loud rather than being parsed.
    it "raises naming the line for a decorated ```gherkin opener rather than dropping the block" do
      source = "prose\n\n```gherkin title=demo\nScenario: x\n  Given a\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 3/)
    end
  end

  describe "unknown-keyword lines" do
    it "raises naming the line for a capitalized colon-token that is not Scenario:" do
      source = "```gherkin\nScenario: x\n  Given a\n  Also: something weird\n  Then b\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 4/)
    end

    it "raises naming the line for a colon-suffixed keyword typo" do
      source = "```gherkin\nScenario: x\n  Given a\n  Given: colon typo\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 4/)
    end

    # ACCEPTED RISK (orchestrator decision 2b): a colonless keyword typo like
    # `Wehn typo` is indistinguishable from a wrapped continuation line, and the
    # continuation fold is load-bearing for the house format's wrapped clauses --
    # indentation cannot disambiguate, because wrapped `And`/`Given` lines are
    # indented too. So a colonless typo is deliberately folded into the preceding
    # clause rather than raising. This pins that behaviour so any future change is
    # a conscious one; the colon-token rule above catches the disambiguable case.
    it "folds a colonless keyword typo into the preceding clause (deliberate)" do
      source = "```gherkin\nScenario: x\n  Given a\n  Wehn typo\n  Then b\n```\n"

      clauses = described_class.parse(source).scenarios.first.clauses
      expect(clauses.map { |clause| [clause.keyword, clause.text] }).to eq([["Given", "a Wehn typo"], %w[Then b]])
    end
  end

  describe "scenarios and clauses must carry content" do
    it "raises naming the line for a Scenario: with zero clauses" do
      expect do
        described_class.parse("```gherkin\nScenario: hollow\n```\n")
      end.to raise_error(Lain::Gherkin::MalformedBlock, /line 2/)
    end

    it "raises naming the line for a keyword with empty text" do
      source = "```gherkin\nScenario: x\n  Given a\n  Then\n```\n"

      expect { described_class.parse(source) }.to raise_error(Lain::Gherkin::MalformedBlock, /line 4/)
    end
  end

  describe "a # rubric line outside the fence" do
    # WHY: above the ```gherkin opener, `# rubric` is ordinary markdown (an H1
    # heading), not the in-block marker. Scanning prose for it would misfire on
    # any doc that uses an H1; the marker means "rubric" ONLY on its own line
    # INSIDE the fence, immediately before a Scenario:. So here it is ignored.
    it "is ignored -- the scenario stays mechanical" do
      source = "# rubric\n```gherkin\nScenario: x\n  Given a\n```\n"

      expect(described_class.parse(source).scenarios.first.mechanical).to be(true)
    end
  end

  describe "deep freezing" do
    it "is Ractor.shareable? for the Criteria and every scenario and clause" do
      criteria = described_class.parse(markdown)

      expect(criteria).to be_ractor_shareable
      criteria.scenarios.each do |scenario|
        expect(scenario).to be_ractor_shareable
        scenario.clauses.each { |clause| expect(clause).to be_ractor_shareable }
      end
    end
  end

  describe "the real plan-doc corpus (house-format smoke check)" do
    corpus = Dir.glob(File.expand_path("../../planning/specs/*.md", __dir__))

    it "has a corpus to check" do
      expect(corpus).not_to be_empty
    end

    corpus.each do |doc|
      it "parses every gherkin block in #{File.basename(doc)} without rejection" do
        expect { described_class.parse(File.read(doc)) }.not_to raise_error
      end
    end
  end
end
