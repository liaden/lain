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

      expect(criteria).to be_deeply_frozen
      criteria.scenarios.each do |scenario|
        expect(scenario).to be_deeply_frozen
        expect(scenario.clauses).to all(be_deeply_frozen)
      end
    end
  end

  # The rendering back OUT to the house format, on the value that holds the
  # clauses. Two consumers quote a scenario -- the approval question and the
  # test-generation prompt -- and each held its own copy of these three lines.
  describe "Scenario#render" do
    it "renders the header unindented and one clause per line, indented two spaces" do
      scenario = described_class.parse(markdown).first

      expect(scenario.render).to eq(<<~GHERKIN.chomp)
        Scenario: mechanical one
          Given a fixture project
          When the suite runs
          Then it passes
          And the digest is stable
      GHERKIN
    end

    it "round-trips through the parser: the rendering is itself house format" do
      scenario = described_class.parse(markdown).first
      reparsed = described_class.parse("```gherkin\n#{scenario.render}\n```")

      expect(reparsed.first).to eq(scenario)
    end
  end

  # The single example above pins the round trip at one fixed shape. These
  # extend it to arbitrary criteria via prop_check (spec/support/prop_check_setup.rb).
  #
  # The generator is deliberately narrower than the grammar: plain alphanumeric
  # words joined by single spaces, so nothing it produces can collide with a
  # token the parser assigns structural meaning to -- there is no `:` for the
  # by-design refusals at gherkin.rb:216 (a colon-suffixed first token), :227
  # (an empty scenario name), or :240 (an empty clause) to ever fire on. The
  # first clause of every scenario draws its keyword from Given/When/Then
  # only, never And, which is what keeps the :242 leading-And refusal out of
  # reach by construction rather than by luck. `#` is absent for a different
  # reason: it is not refused (`ignorable?`, gherkin.rb:205-213, routes a
  # comment line to nil), it is legal input that VANISHES on parse -- a
  # generated comment could never round-trip regardless of what the parser
  # does with it, so there is nothing a comment could usefully assert here.
  describe "the round trip and digest hold for any generated criteria (property-tested)" do
    word = PropCheck::Generators.alphanumeric_string(min: 1, max: 8)
    phrase = PropCheck::Generators.array(word, min: 1, max: 4).map { |words| words.join(" ") }

    keyword_from = lambda do |pool|
      PropCheck::Generators.one_of(*pool.map { |keyword| PropCheck::Generators.constant(keyword) })
    end

    clause_with = lambda do |keyword_pool|
      PropCheck::Generators.tuple(keyword_from.call(keyword_pool), phrase)
                           .map { |keyword, text| Lain::Gherkin::Clause.new(keyword:, text:) }
    end

    opening_clause = clause_with.call(%w[Given When Then])
    later_clause = clause_with.call(%w[Given When Then And])
    clauses = PropCheck::Generators.tuple(opening_clause, PropCheck::Generators.array(later_clause, max: 4))
                                   .map { |first, rest| [first, *rest] }

    # Fixed at mechanical: true (Scenario.new's default) -- Scenario#render has
    # no way to emit the `# rubric` marker, so these two feed only the
    # round-trip and digest-stability properties below, both of which render.
    scenario = PropCheck::Generators.tuple(phrase, clauses)
                                    .map { |name, scenario_clauses| Lain::Gherkin::Scenario.new(name:, clauses: scenario_clauses) }

    criteria = PropCheck::Generators.array(scenario, min: 1, max: 3)
                                    .map { |scenarios| described_class.new(scenarios:) }

    # Criteria itself carries no #render (only Scenario does) -- fencing each
    # scenario's own rendering back into one block is exactly what a plan doc's
    # markdown does between prose paragraphs.
    def fence(criteria)
      "```gherkin\n#{criteria.scenarios.map(&:render).join("\n\n")}\n```\n"
    end

    def reparse(criteria)
      described_class.parse(fence(criteria))
    end

    it "renders and reparses to an equal value for any generated criteria", aggregate_failures: false do
      forall(criteria:) do |criteria:|
        expect(reparse(criteria)).to eq(criteria)
      end
    end

    it "keeps the digest stable across a render and parse cycle", aggregate_failures: false do
      forall(criteria:) do |criteria:|
        expect(reparse(criteria).digest).to eq(criteria.digest)
      end
    end

    # The lossy half of the asymmetry the note above states: rendering a
    # rubric (mechanical: false) scenario and reparsing it silently drops the
    # flag, because #render has no syntax for the marker that set it. Pinned
    # here, next to the properties that route around it by never rendering a
    # mechanical: false scenario in the first place.
    it "renders a rubric scenario as mechanical: true after a parse cycle -- render cannot carry the marker" do
      judged = described_class.parse(markdown).scenarios.last
      expect(judged.mechanical).to be(false)

      reparsed = described_class.parse("```gherkin\n#{judged.render}\n```")

      expect(reparsed.scenarios.first.mechanical).to be(true)
    end

    # This generator, unlike the mechanical: true-only one above, feeds the
    # digest-uniqueness property below -- that property never renders, so
    # (per the pinned example above) it is free to vary mechanical, and doing
    # so is what lets it catch a digest that silently drops the flag.
    scenario_with_mechanical = PropCheck::Generators.tuple(phrase, clauses, PropCheck::Generators.boolean)
                                                    .map do |name, scenario_clauses, mechanical|
                                                      Lain::Gherkin::Scenario.new(name:, clauses: scenario_clauses,
                                                                                  mechanical:)
                                                    end
    mutation_criteria = PropCheck::Generators.array(scenario_with_mechanical, min: 1, max: 3)
                                             .map { |scenarios| described_class.new(scenarios:) }

    # Which single field to mutate, and where. Earlier this test pinned
    # scenario 0 / clause 0 / text -- a real digest defect that drops a field,
    # ignores every scenario but the first, or ignores every clause but the
    # first, walks straight through a mutation that never touches that site.
    # Drawing the scenario index, the clause index and the field from the
    # generator instead means each of prop_check's 100 draws exercises a
    # different site, so a defect confined to one field or one position past
    # the first is what shrinking converges on rather than what hides from it.
    mutation_kind = PropCheck::Generators.one_of(
      *%i[name mechanical keyword text].map { |kind| PropCheck::Generators.constant(kind) }
    )
    scenario_pick = PropCheck::Generators.nonnegative_integer
    clause_pick = PropCheck::Generators.nonnegative_integer

    def replace_at(array, index, value)
      array.each_with_index.map { |item, i| i == index ? value : item }
    end

    def mutate_clause(clause, kind)
      case kind
      when :keyword
        Lain::Gherkin::Clause.new(keyword: (%w[Given When Then And] - [clause.keyword]).first, text: clause.text)
      when :text
        Lain::Gherkin::Clause.new(keyword: clause.keyword, text: "#{clause.text} changed")
      end
    end

    def mutate_scenario_field(scenario, kind)
      case kind
      when :name
        Lain::Gherkin::Scenario.new(name: "#{scenario.name} changed", clauses: scenario.clauses,
                                    mechanical: scenario.mechanical)
      when :mechanical
        Lain::Gherkin::Scenario.new(name: scenario.name, clauses: scenario.clauses, mechanical: !scenario.mechanical)
      end
    end

    def mutate_scenario_clause(scenario, clause_index, kind)
      changed = mutate_clause(scenario.clauses[clause_index], kind)
      Lain::Gherkin::Scenario.new(name: scenario.name, clauses: replace_at(scenario.clauses, clause_index, changed),
                                  mechanical: scenario.mechanical)
    end

    def mutate_scenario(scenario, clause_index, kind)
      return mutate_scenario_field(scenario, kind) if %i[name mechanical].include?(kind)

      mutate_scenario_clause(scenario, clause_index, kind)
    end

    it "changes the digest when exactly one field changes -- a scenario's name or mechanical flag, " \
       "or one clause's keyword or text", aggregate_failures: false do
      forall(criteria: mutation_criteria, scenario_pick:, clause_pick:,
             kind: mutation_kind) do |criteria:, scenario_pick:, clause_pick:, kind:|
        scenario_index = scenario_pick % criteria.scenarios.length
        target = criteria.scenarios[scenario_index]
        clause_index = clause_pick % target.clauses.length

        mutated_scenario = mutate_scenario(target, clause_index, kind)
        mutated = described_class.new(scenarios: replace_at(criteria.scenarios, scenario_index, mutated_scenario))

        expect(mutated.digest).not_to eq(criteria.digest)
      end
    end
  end

  # The house-format smoke check over `planning/specs/*.md` that used to live
  # here is now `bin/lint-gherkin-docs`, run by pre-commit over STAGED docs.
  # It asserted a property of the repository's contents rather than of this
  # subject: prose became part of the test surface, so writing a plan doc could
  # turn the whole suite red and block unrelated commits, and adding one moved
  # the example count this repo reads to detect a truncated parallel run.
  # {Criteria}'s subject is the criteria a USER of lain writes; that lain's own
  # planning documents use the same fenced blocks is a convenience, not the
  # thing under test.
end
