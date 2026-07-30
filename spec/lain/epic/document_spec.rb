# frozen_string_literal: true

# The epic markdown grammar: the artifact a human edits in nvim, and the parse
# that reads those edits back. Two laws carry the weight. The round trip is
# TOTAL -- a graph emitted and parsed again is the same graph by digest, or the
# emit is refused loudly naming the value it cannot write. And nothing is
# silently reinterpreted: a line the grammar has no slot for is an error naming
# it, never prose the author never sees again. Prose INSIDE an issue is
# value-bearing (unlike Plan, where prose is decoration); prose above the first
# heading is the epic preamble and is ignored, exactly as Plan ignores prose
# around its step lines.
RSpec.describe Lain::Epic::Document do
  def issue(id, **overrides)
    Lain::Epic::Issue.new(id:, title: "Issue #{id}", **overrides)
  end

  def graph(*issues)
    Lain::Epic::Graph.new(issues:)
  end

  def parse(source)
    described_class.parse_markdown(source)
  end

  let(:criteria_source) do
    <<~GHERKIN
      ```gherkin
      Scenario: the third thing is done
        Given the third thing
        Then it is done
      ```
    GHERKIN
  end

  let(:original) do
    graph(issue("a", description: "The first thing needs doing.\n\nIt has two paragraphs.",
                     blocks: %w[b c], related: %w[c]),
          issue("b", status: "in_flight", discovered_from: "a"),
          issue("c", status: "done", criteria: criteria_source))
  end

  # AC: the author-review loop round-trips, criteria fence included.
  describe "the author-review loop" do
    it "parses an emitted graph back to the same digest" do
      parsed = parse(described_class.to_markdown(original))

      expect(parsed.digest).to eq(original.digest)
    end

    it "re-emits the criteria fence byte-identically, delimiters included" do
      parsed = parse(described_class.to_markdown(original))

      expect(parsed.fetch("c").criteria).to eq(criteria_source)
    end

    it "keeps every stored status through one mark map" do
      statuses = Lain::Epic::STORED_STATUSES.each_with_index.map { |status, i| issue("i#{i}", status:) }
      marked = graph(*statuses)

      expect(parse(described_class.to_markdown(marked)).map(&:status)).to eq(Lain::Epic::STORED_STATUSES)
    end

    it "never emits a Blocked by line -- it is derived from the blocks edges" do
      expect(described_class.to_markdown(original)).not_to include("Blocked by")
    end

    it "emits an empty graph as an empty document, which parses back empty" do
      expect(described_class.to_markdown(graph)).to eq("")
      expect(parse("").to_a).to eq([])
    end
  end

  # AC: an authored Blocked by line is refused, not absorbed.
  describe "a link line the grammar does not write" do
    let(:with_blocked_by) do
      <<~MARKDOWN
        ### [ ] `a` Issue a

        Blocked by: `b`

        ### [ ] `b` Issue b
      MARKDOWN
    end

    it "refuses an authored Blocked by line naming the line and the derivation" do
      expect { parse(with_blocked_by) }
        .to raise_error(Lain::Epic::MalformedDocument, /line 3.*Blocked by.*derived/m)
    end

    it "lists the writable link kinds in the refusal" do
      expect { parse(with_blocked_by) }
        .to raise_error(Lain::Epic::MalformedDocument, /Blocks:.*Related:.*Discovered from:/m)
    end

    it "refuses any other colon-token line rather than demoting it to prose" do
      expect { parse("### [ ] `a` Issue a\n\nNote: this is not a link kind\n") }
        .to raise_error(Lain::Epic::MalformedDocument, /line 3.*Note/m)
    end
  end

  # AC: issue prose is value-bearing.
  describe "issue prose" do
    def described(text)
      parse("### [ ] `a` Issue a\n\n#{text}\n")
    end

    it "moves the digest, unlike prose in a plan" do
      expect(described("One reading.").digest).not_to eq(described("Another reading.").digest)
    end

    it "survives verbatim, interior blank lines included" do
      expect(described("First paragraph.\n\nSecond paragraph.").fetch("a").description)
        .to eq("First paragraph.\n\nSecond paragraph.")
    end

    # The grammar lifts link lines out of the prose stream and leaves the blank
    # lines that surrounded them behind, rather than squeezing blank runs -- a
    # squeeze would silently edit an author's deliberate paragraph spacing. The
    # result is stable under a second pass, which is what the round trip needs.
    it "keeps prose from both sides of a link line, and the blank lines it left behind" do
      source = "### [ ] `a` Issue a\n\nAbove.\n\nRelated: `b`\n\nBelow.\n\n### [ ] `b` Issue b\n"

      once = parse(source)

      expect(once.fetch("a").description).to eq("Above.\n\n\nBelow.")
      expect(parse(described_class.to_markdown(once)).digest).to eq(once.digest)
    end

    # Stated by the grammar rather than left to chance: a closing note under the
    # last issue is that issue's prose, and prose is meaning.
    it "reads the last issue's body to EOF, so a closing note is knowingly value-bearing" do
      source = "### [ ] `a` Issue a\n\n### [ ] `b` Issue b\n\nA closing note.\n"

      expect(parse(source).fetch("b").description).to eq("A closing note.")
    end
  end

  # AC: a link line naming an unknown id fails loudly at parse.
  describe "link lines" do
    it "surfaces the graph's unknown-id error naming both ids" do
      expect { parse("### [ ] `a` Issue a\n\nBlocks: `ghost`\n") }
        .to raise_error(Lain::Epic::MalformedGraph, /"ghost".*"a"/m)
    end

    it "reads several backticked ids from one line" do
      source = "### [ ] `a` Issue a\n\nBlocks: `b`, `c`\n\n### [ ] `b` Issue b\n\n### [ ] `c` Issue c\n"

      expect(parse(source).fetch("a").blocks).to eq(%w[b c])
    end

    it "refuses a link line naming no backticked id" do
      expect { parse("### [ ] `a` Issue a\n\nBlocks: b\n") }
        .to raise_error(Lain::Epic::MalformedDocument, /line 3.*backtick/m)
    end

    it "refuses a second link line of the same kind rather than silently keeping one" do
      source = "### [ ] `a` Issue a\n\nBlocks: `b`\nBlocks: `b`\n\n### [ ] `b` Issue b\n"

      expect { parse(source) }.to raise_error(Lain::Epic::MalformedDocument, /line 4.*Blocks/m)
    end

    it "refuses two ids on the singular Discovered from line" do
      source = "### [ ] `a` Issue a\n\nDiscovered from: `b`, `c`\n\n### [ ] `b` Issue b\n\n### [ ] `c` Issue c\n"

      expect { parse(source) }.to raise_error(Lain::Epic::MalformedDocument, /line 3.*one issue id/m)
    end
  end

  # AC: epic preamble prose is ignored both directions.
  describe "the epic preamble" do
    let(:issues) { "### [ ] `a` Issue a\n\nSome prose.\n" }

    it "parses to the same digest with and without a preamble" do
      preambled = "# An epic\n\nWhy this epic exists.\n\n#{issues}"

      expect(parse(preambled).digest).to eq(parse(issues).digest)
    end

    it "is not re-emitted, so to_markdown is a function of the graph alone" do
      expect(described_class.to_markdown(parse("# An epic\n\n#{issues}"))).not_to include("An epic")
    end

    # A preamble that shows the template must not be read AS the template.
    it "ignores a heading that sits inside a preamble fence" do
      preambled = "# An epic\n\n```markdown\n### [ ] `example` Not a real issue\n```\n\n#{issues}"

      expect(parse(preambled).ids).to eq(%w[a])
    end
  end

  describe "headings" do
    it "refuses a line that starts like a heading but does not match the grammar" do
      expect { parse("### [ ] a Issue a\n") }
        .to raise_error(Lain::Epic::MalformedDocument, /line 1.*not an issue heading/m)
    end

    # The grammar refuses what it cannot write back, not everything that looks
    # nearby: a deeper heading is unambiguous markdown and survives as prose.
    it "carries a deeper `####` heading as issue prose" do
      parsed = parse("### [ ] `a` Issue a\n\n#### Notes\n\nSomething.\n")

      expect(parsed.fetch("a").description).to eq("#### Notes\n\nSomething.")
      expect(parse(described_class.to_markdown(parsed)).digest).to eq(parsed.digest)
    end

    it "refuses an unknown status mark, naming the marks it knows" do
      expect { parse("### [?] `a` Issue a\n") }
        .to raise_error(Lain::Epic::MalformedDocument, /line 1.*mark/m)
    end

    it "reports a malformed issue against the line that opened it" do
      expect { parse("### [ ] ` ` Issue a\n") }
        .to raise_error(Lain::Epic::MalformedDocument, /line 1.*whitespace/m)
    end
  end

  describe "the criteria fence" do
    it "refuses a second gherkin fence in one issue body" do
      source = "### [ ] `a` Issue a\n\n#{criteria_source}\n#{criteria_source}"

      expect { parse(source) }.to raise_error(Lain::Epic::MalformedDocument, /already carries/m)
    end

    it "refuses a fence in an issue body that is not a gherkin fence" do
      source = "### [ ] `a` Issue a\n\n```ruby\nputs :hi\n```\n"

      expect { parse(source) }.to raise_error(Lain::Epic::MalformedDocument, /line 3.*gherkin/m)
    end

    it "refuses a fence left open at end of document, naming its opener" do
      expect { parse("### [ ] `a` Issue a\n\n```gherkin\nScenario: x\n  Given y\n") }
        .to raise_error(Lain::Epic::MalformedDocument, /line 3.*unclosed/m)
    end

    it "keeps a link-shaped line inside the fence as fence text" do
      parsed = parse("### [ ] `a` Issue a\n\n#{criteria_source}")

      expect(parsed.fetch("a").criteria).to include("Scenario: the third thing is done")
    end
  end

  # "Same digest or a loud rejection naming the offending value" cuts both ways:
  # a value the grammar cannot write back is refused at emit rather than emitted
  # into a document that would parse to a different digest.
  describe "values the grammar cannot write" do
    def emit(**overrides)
      described_class.to_markdown(graph(issue("a", **overrides)))
    end

    it "refuses a description whose line ends in whitespace the grammar would strip" do
      expect { emit(description: "Trailing space here.  \nAnd more.") }
        .to raise_error(Lain::Epic::MalformedDocument, /"a" description.*whitespace/m)
    end

    it "refuses a description that ends in a line break" do
      expect { emit(description: "A closing note.\n") }
        .to raise_error(Lain::Epic::MalformedDocument, /"a" description/m)
    end

    it "refuses a description that begins with a blank line" do
      expect { emit(description: "\nA note.") }
        .to raise_error(Lain::Epic::MalformedDocument, /"a" description/m)
    end

    it "refuses a description holding a line the parse would read as a heading" do
      expect { emit(description: "See below.\n### [ ] `b` Issue b") }
        .to raise_error(Lain::Epic::MalformedDocument, /"a" description.*###/m)
    end

    it "refuses a description holding a line the parse would read as a link line" do
      expect { emit(description: "See below.\nBlocks: `b`") }
        .to raise_error(Lain::Epic::MalformedDocument, /"a" description.*link line/m)
    end

    it "refuses a description holding a fence the parse would read as criteria" do
      expect { emit(description: "See below.\n```gherkin\nScenario: x\n```") }
        .to raise_error(Lain::Epic::MalformedDocument, /"a" description.*fence/m)
    end

    it "refuses prose-wrapped criteria, which would not parse back as criteria" do
      wrapped = "Here are the criteria:\n\n#{criteria_source}"

      expect { emit(criteria: wrapped) }
        .to raise_error(Lain::Epic::MalformedDocument, /"a" criteria.*open/m)
    end

    it "refuses criteria that do not end in the closing fence line's own line break" do
      expect { emit(criteria: criteria_source.chomp) }
        .to raise_error(Lain::Epic::MalformedDocument, /"a" criteria.*line break/m)
    end

    # The parse strips every line it reads, so any byte `rstrip` would take is a
    # byte the round trip would lose. Both fields consult ONE statement of that,
    # because two hand-written lists that must agree is what let a CR through:
    # `String#chomp` removes "\r\n" as a single unit, so a CR was invisible to
    # the rule meant to catch it while the parse deleted it regardless.
    describe "bytes the parse would strip" do
      it "refuses a description holding a CR, which chomp cannot see" do
        expect { emit(description: "Above.\r\nBelow.") }
          .to raise_error(Lain::Epic::MalformedDocument, /"a" description.*whitespace/m)
      end

      it "refuses criteria whose step line ends in whitespace" do
        expect { emit(criteria: "```gherkin\nScenario: x  \n  Given y\n```\n") }
          .to raise_error(Lain::Epic::MalformedDocument, /"a" criteria.*whitespace/m)
      end

      it "refuses criteria written with CRLF line endings" do
        expect { emit(criteria: "```gherkin\r\nScenario: x\r\n  Given y\r\n```\r\n") }
          .to raise_error(Lain::Epic::MalformedDocument, /"a" criteria.*whitespace/m)
      end

      it "refuses criteria holding a blank line made of spaces" do
        expect { emit(criteria: "```gherkin\nScenario: x\n  Given y\n   \n```\n") }
          .to raise_error(Lain::Epic::MalformedDocument, /"a" criteria.*whitespace/m)
      end

      it "refuses criteria with a trailing space after the closing fence" do
        expect { emit(criteria: "```gherkin\nScenario: x\n  Given y\n``` \n") }
          .to raise_error(Lain::Epic::MalformedDocument, /"a" criteria.*whitespace/m)
      end

      # The complement, so the rule is a scalpel and not a blanket: a CR the
      # parse does NOT strip is not the parse's business.
      it "carries a bare CR in the middle of a line, which the parse never touches" do
        parsed = parse(described_class.to_markdown(graph(issue("a", description: "Above.\rBelow."))))

        expect(parsed.fetch("a").description).to eq("Above.\rBelow.")
      end

      it "carries an indented criteria fence verbatim" do
        indented = "  ```gherkin\n  Scenario: x\n    Given y\n  ```\n"
        parsed = parse(described_class.to_markdown(graph(issue("a", criteria: indented))))

        expect(parsed.fetch("a").criteria).to eq(indented)
      end
    end
  end

  # T10 AC: Writer and the predicate agree. Writer only ever raises on the
  # document grammar (DESCRIPTION_RULES/CRITERIA_RULES), so this only needs
  # the forward direction -- an issue the predicate calls emittable never
  # trips Writer -- not its converse: an issue whose id fails Home::NAME (like
  # "日本" in the round-trip law below) is not emittable, yet Writer, which
  # never touches the filesystem grammar, still emits it cleanly.
  describe "Writer and the predicate agree" do
    def sample_issues
      [issue("a", description: "Fine prose.", criteria: criteria_source),
       issue("b"),
       issue("c", status: "done", description: "Two.\n\nParagraphs.")]
    end

    it "emits every issue the predicate calls emittable, without raising" do
      sample_issues.each do |candidate|
        expect(candidate).to be_emittable
        expect { described_class::Writer.new(candidate).to_s }.not_to raise_error
      end
    end

    it "refuses the same issue Writer would refuse, for the same reason" do
      broken = issue("a", description: "Trailing space here.  \nAnd more.")

      expect(broken).not_to be_emittable
      expect(broken.emittable_failures.join).to include("document grammar")
      expect { described_class::Writer.new(broken).to_s }
        .to raise_error(Lain::Epic::MalformedDocument, /"a" description.*whitespace/m)
    end
  end

  # A parsed document hands out one more value than the graph: the markdown
  # itself. Every other value this unit returns is frozen.
  it "hands back a frozen document" do
    expect(described_class.to_markdown(original)).to be_frozen
  end

  # T2 validates `blocks` and `related` against the graph and deliberately does
  # NOT validate `discovered_from`: a split removes the issue its parts grew out
  # of, so provenance pointing outside the current issue set is the designed
  # state. The asymmetry is invisible to an author who typos an id, so it is
  # pinned here rather than left to be rediscovered.
  describe "the provenance asymmetry" do
    it "refuses a Blocks edge naming an id with no heading" do
      expect { parse("### [ ] `a` Issue a\n\nBlocks: `zz`\n") }
        .to raise_error(Lain::Epic::MalformedGraph, /"zz"/)
    end

    it "accepts a Discovered from naming an id with no heading, because provenance outlives the issue" do
      parsed = parse("### [ ] `a` Issue a\n\nDiscovered from: `zz`\n")

      expect(parsed.fetch("a").discovered_from).to eq("zz")
    end
  end

  # The law as a property rather than as a list of remembered cases: for a random
  # graph, parse(emit(g)) is g by digest, or emit refused loudly. Seeded, so a
  # failure is reproducible, and edges only ever point forward through the id
  # order so the generator cannot spend its runs on cycles the Graph refuses.
  describe "the round-trip law, generatively" do
    prose = [
      "", "Plain prose.", "Para one.\n\nPara two.", "#### Notes\n\nUnder it.",
      "Line with `backticks`.", "-", "- a list\n- of items", "héllo — ✨ 日本語 👩‍👩‍👧‍👦",
      "A\tB tabbed", "Above.\n\n\nBelow.", "note: lowercase kind", "A\rB bare CR",
      "Above.\r\nBelow.", "Trailing space.  \nAnd more.", "  leading spaces",
      "See ### below", "Blocked by: `x`", "Warning: careful", "```\nbare fence\n```",
      "### [ ] `x` looks like a heading", "Ends in a period.", "a" * 300
    ].freeze
    criteria = [
      nil,
      "```gherkin\nScenario: x\n  Given y\n  Then z\n```\n",
      "```gherkin\nScenario: ✨\n  Given 日本語\n  Then done\n```\n",
      "  ```gherkin\n  Scenario: indented\n    Given y\n  ```\n",
      "```gherkin\nScenario: trailing ws  \n  Given y\n```\n",
      "```gherkin\r\nScenario: crlf\r\n  Given y\r\n```\r\n",
      "```gherkin\nScenario: x\n  Given y\n```",
      "Prose wrapper:\n\n```gherkin\nScenario: x\n  Given y\n```\n"
    ].freeze

    # :ok, :loud, or :silent -- and :silent is the one this exists to make
    # impossible. A parse failure on a document we ourselves emitted is its own
    # verdict, because "everything that parses, emits" has to hold both ways.
    def verdict(graph)
      markdown = described_class.to_markdown(graph)
      described_class.parse_markdown(markdown).digest == graph.digest ? :ok : :silent
    rescue Lain::Epic::MalformedDocument
      :loud
    rescue Lain::Error
      :unparseable_emission
    end

    # Edges only ever point forward through the id order, so the generator
    # cannot spend its runs on cycles the Graph refuses before Document is
    # reached.
    def random_issue(id, later, rng, corpus)
      issue(id, description: corpus.fetch(:prose).sample(random: rng),
                criteria: corpus.fetch(:criteria).sample(random: rng),
                status: Lain::Epic::STORED_STATUSES.sample(random: rng),
                blocks: later.sample(rng.rand(0..later.size), random: rng),
                related: later.sample(rng.rand(0..later.size), random: rng),
                discovered_from: later.sample(random: rng))
    end

    def random_graph(rng, corpus)
      ids = %w[a b c d-e 日本].first(rng.rand(1..5))
      graph(*ids.each_with_index.map { |id, i| random_issue(id, ids.drop(i + 1), rng, corpus) })
    end

    # Everything above minus the values the grammar refuses on purpose. Kept as
    # its own corpus rather than as a threshold on the adversarial run: "N of 400
    # survived" is a number that drifts with the corpus, while "every value the
    # grammar accepts round-trips" is the property actually worth pinning, and it
    # is what stops a Writer that refuses everything from passing.
    clean_prose = prose - ["Above.\r\nBelow.", "Trailing space.  \nAnd more.", "Blocked by: `x`",
                           "Warning: careful", "```\nbare fence\n```", "### [ ] `x` looks like a heading"]
    clean_criteria = criteria - ["```gherkin\nScenario: trailing ws  \n  Given y\n```\n",
                                 "```gherkin\r\nScenario: crlf\r\n  Given y\r\n```\r\n",
                                 "```gherkin\nScenario: x\n  Given y\n```",
                                 "Prose wrapper:\n\n```gherkin\nScenario: x\n  Given y\n```\n"]

    it "never changes a digest silently, and never emits what it cannot parse" do
      rng = Random.new(20_260_728)
      verdicts = Array.new(400) { verdict(random_graph(rng, { prose:, criteria: })) }.tally

      expect(verdicts).not_to include(:silent, :unparseable_emission)
    end

    it "writes back every value it accepts" do
      rng = Random.new(20_260_728)
      corpus = { prose: clean_prose, criteria: clean_criteria }
      verdicts = Array.new(200) { verdict(random_graph(rng, corpus)) }.tally

      expect(verdicts).to eq(ok: 200)
    end
  end
end
