# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Epic::IssueView do
  let(:criteria) do
    <<~GHERKIN
      ```gherkin
      Scenario: the ingest command reads a file
        Given a file of 3 rows
        When it is ingested
        Then the store holds 3 rows

      Scenario: the ingest command refuses an empty file
        Given an empty file
        When it is ingested
        Then it is refused
      ```
    GHERKIN
  end

  let(:added) do
    <<~GHERKIN.chomp
      ```gherkin
      Scenario: the ingest command names the file it refused
        Given an empty file
        When it is ingested
        Then the refusal names the file
      ```
    GHERKIN
  end

  let(:authored) do
    <<~MARKDOWN
      ## What and why

      Ingest reads rows into the store.

      ## Acceptance criteria

      #{added}

      ## References

      - `lib/ingest.rb`, the entry point
    MARKDOWN
  end

  let(:epic) do
    graph(ingest, Lain::Epic::Issue.new(id: "report", title: "Report"),
          Lain::Epic::Issue.new(id: "schema", title: "Schema", blocks: ["ingest"]))
  end

  def graph(*issues) = Lain::Epic::Graph.new(issues:)

  def ingest(**overrides)
    Lain::Epic::Issue.new(id: "ingest", title: "Ingest a file", description: "Signed off at the epic gate.",
                          criteria:, blocks: ["report"], **overrides)
  end

  def view_of(text = authored, within: epic)
    described_class.new(issue: within.fetch("ingest"), graph: within, authored: text)
  end

  describe "#to_markdown" do
    subject(:markdown) { view_of.to_markdown }

    # Scenario: the epic's scenarios are carried verbatim by construction
    it "holds the epic's scenarios byte for byte, then the added one" do
      expect(markdown.index(criteria)).to be < markdown.index(added)
    end

    it "lists Blocks and Blocked by from the graph under its Links" do
      expect(markdown[/^## Links\n\n.*\z/m]).to include("Blocks: `report`", "Blocked by: `schema`")
    end

    it "opens with the issue's id and title, then its epic description, the authored prose, then the references" do
      sections = ["# ingest -- Ingest a file", "Signed off at the epic gate.", "Ingest reads rows into the store.",
                  "## Acceptance criteria",
                  "## References", "## Links"]

      expect(sections.map { |section| markdown.index(section) }).to eq(sections.map { |s| markdown.index(s) }.sort)
    end

    it "renders the issue's Subject and Level in its Links" do
      within = graph(ingest(blocks: [], subject: "lib/ingest.rb", level: "unit"))

      expect(view_of(within:).to_markdown).to end_with("## Links\n\nSubject: `lib/ingest.rb`\nLevel: unit\n")
    end

    it "carries the epic's scenarios when the authored file adds none" do
      expect(view_of("Ingest reads rows.\n").to_markdown).to include("## Acceptance criteria\n\n#{criteria}")
    end
  end

  describe "#criteria" do
    it "parses the epic's scenarios, then the added ones" do
      expect(view_of.criteria.map(&:name))
        .to eq(["the ingest command reads a file", "the ingest command refuses an empty file",
                "the ingest command names the file it refused"])
    end
  end

  describe "#digest" do
    it "is the content address of the rendered bytes" do
      expect(view_of.digest).to eq(Lain::Workspace::Snapshot::Blob.new(bytes: view_of.to_markdown).digest)
    end

    it "moves when the authored file gains a sentence" do
      expect(view_of("#{authored}\nOne more line.\n").digest).not_to eq(view_of.digest)
    end

    it "moves when a new edge blocks the issue, because its Links are part of the plan" do
      blocked = graph(*epic, Lain::Epic::Issue.new(id: "config", title: "Config", blocks: ["ingest"]))

      expect(view_of(within: blocked).digest).not_to eq(view_of.digest)
    end
  end

  describe "#lends" do
    let(:referenced) do
      <<~MARKDOWN
        Ingest reads rows, as /srv/elsewhere/prose.md does.

        ## References

        - `lib/ingest.rb`, the entry point
        - `~/dev/sample/rustfmt.toml`, the formatting rules
        - ~/dev/sample/, the project it follows.
        - [the schema](/srv/data/schema.sql)
        - https://example.com/ingest
      MARKDOWN
    end

    it "names each absolute and home-relative path its References hold, expanded against the home" do
      expect(view_of(referenced).lends(home: "/home/alice"))
        .to eq(%w[/home/alice/dev/sample/rustfmt.toml /home/alice/dev/sample /srv/data/schema.sql])
    end

    it "names nothing for References that name only paths inside the project" do
      expect(view_of.lends(home: "/home/alice")).to eq([])
    end

    it "names no path inside an HTML comment, which a reader of the rendered issue never sees" do
      text = "## References\n\n- /srv/shown.md <!-- /srv/hidden.md -->\n<!--\n- /srv/also-hidden.md\n-->\n"

      expect(view_of(text).lends(home: "/home/alice")).to eq(%w[/srv/shown.md])
    end

    it "keeps a trailing .. as a step up, so home named that way reaches the rule as home" do
      expect(view_of("## References\n\n- ~/dev/..\n").lends(home: "/home/alice")).to eq(%w[/home/alice])
    end

    it "strips the punctuation a sentence leaves after a path" do
      text = "## References\n\n- see /srv/x.md.\n- /srv/y.md; and /srv/z.md: the rest\n"

      expect(view_of(text).lends(home: "/home/alice")).to eq(%w[/srv/x.md /srv/y.md /srv/z.md])
    end

    {
      "the filesystem root" => "- `lib/a.rb` / `spec/a_spec.rb`",
      "home itself" => "- `~/`, the whole home",
      "a prose slash" => "- reads a / b, or c/d",
      "a subnet" => "- a /24 subnet",
      "a scheme-less URL" => "- <//example.com/x>"
    }.each do |what, line|
      it "names nothing for #{what}, which has no segment to lend" do
        expect(view_of("## References\n\n#{line}\n").lends(home: "/home/alice")).to eq([])
      end
    end
  end

  describe "#issue" do
    it "is the issue as epic.md holds it" do
      expect(view_of.issue).to eq(epic.fetch("ingest"))
    end
  end

  describe "#blocked_by" do
    it "names the issues whose Blocks edges point at this one, from the graph" do
      expect(view_of.blocked_by).to eq(["schema"])
    end
  end

  describe ".read" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    let(:home) do
      Lain::Epic::Home.resolve(config: Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo)),
                               paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @dir, "HOME" => @dir }),
                               root: @dir, slug: "nyotes")
    end

    # Scenario: a graph change shows in the view with no rewrite
    it "lists an edge added to the graph after the authored file was written" do
      home.write_epic(epic)
      home.issue("ingest").write(authored)
      described_class.read(home, "ingest").to_markdown
      home.write_epic(graph(ingest(related: ["schema"]), *epic.reject { |issue| issue.id == "ingest" }))

      expect(described_class.read(home, "ingest").to_markdown).to include("Related: `schema`")
    end
  end

  describe "#refuse_derived!" do
    # Scenario: an authored file cannot carry derived lines
    it "refuses a Blocked by line, naming the graph as its source" do
      expect { view_of("#{authored}\nBlocked by: `schema`\n").refuse_derived! }
        .to raise_error(described_class::DerivedLine, /line \d+: `Blocked by:`.*graph/)
    end

    it "refuses a scenario the epic already carries, by its name" do
      restated = "## Acceptance criteria\n\n#{criteria}"

      expect { view_of(restated).refuse_derived! }
        .to raise_error(described_class::DerivedLine, /the ingest command reads a file.*epic\.md/)
    end

    it "accepts prose, added scenarios and references" do
      expect(view_of.refuse_derived!).to be_a(described_class)
    end

    it "leaves a link-shaped line inside a fence to the fence" do
      expect(view_of("#{authored}\n```text\nBlocked by: `schema`\n```\n").refuse_derived!).to be_a(described_class)
    end

    it "leaves a comment line inside the criteria fence to the fence" do
      commented = "## Acceptance criteria\n\n```gherkin\n# a note\nScenario: a new one\n  Then it holds\n```\n"

      expect(view_of(commented).refuse_derived!).to be_a(described_class)
    end

    it "lists every problem of an old-format file in one refusal" do
      old_format = "# ingest -- Ingest a file\n\nBlocked by: `schema`\n\n#{added}\n\n" \
                   "## Acceptance criteria\n\n#{criteria}"

      expect { view_of(old_format).refuse_derived! }
        .to raise_error(described_class::DerivedLine,
                        /`Blocked by:`.*"# ingest -- Ingest a file".*gherkin fence outside.*restates/m)
    end

    it "refuses a gherkin fence outside the Acceptance criteria section" do
      expect { view_of("Prose first.\n\n#{added}\n").refuse_derived! }
        .to raise_error(described_class::DerivedLine, /line 3: .*## Acceptance criteria/)
    end

    it "refuses an authored top-level header, naming the rendered view" do
      expect { view_of("# ingest -- Ingest a file\n\n#{authored}").refuse_derived! }
        .to raise_error(described_class::DerivedLine, /line 1: .*rendered view/)
    end

    it "refuses an authored Links heading, naming the rendered view" do
      expect { view_of("#{authored}\n## Links\n").refuse_derived! }
        .to raise_error(described_class::DerivedLine, /## Links.*rendered view/)
    end
  end
end
