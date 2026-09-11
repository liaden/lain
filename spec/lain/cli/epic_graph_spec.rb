# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# `lain epic add|split|merge` is the only door that EDITS an epic's issue
# graph outside the text an author types into `epic.md` by hand. Everything
# here is assembled from objects that already carry their own specs --
# {Lain::Epic::Graph#add}/`#split`/`#merge` do the structural rewrite and
# refuse what they always refuse, {Lain::Epic::Scribe} is the only writer of a
# `graph_revision`, and {Lain::Epic::Document} is the round trip that puts the
# result back on disk -- so what is pinned here is the WIRING: read a graph,
# apply one edit, write it back, journal the fiber it yielded, and refuse
# before any of that when the edit itself refuses.
RSpec.describe Lain::CLI::EpicGraph do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      FileUtils.mkdir_p(root)
      example.run
    end
  end

  def root = File.join(@tmp, "project")
  def state_home = File.join(@tmp, "state")
  def paths = @paths ||= Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })
  def config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))

  def command = described_class.new(root:, paths:, config:)

  def home(slug = "alpha") = Lain::Epic::Home.resolve(config:, paths:, root:, slug:)

  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)
  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  def write_epic(graph, slug: "alpha") = home(slug).write_epic(graph)
  def epic_bytes(slug: "alpha") = home(slug).epic.read

  # A criteria fence that parses to one scenario -- {Epic::Issue} refuses
  # criteria that parse to none.
  def criteria
    <<~GHERKIN
      ```gherkin
      Scenario: a thing happens
        Given a precondition
        When an action
        Then an outcome
      ```
    GHERKIN
  end

  def sessions_dir = paths.sessions_dir

  # {SessionJournals}' own order (ts, across every file): a fixture stamped
  # early and a live record written during the example must fold in the order
  # they happened, not in filename order.
  def journal_records
    Dir.children(sessions_dir).select { |name| name.end_with?(".ndjson") }.sort
       .flat_map { |name| Lain::Journal.records(File.foreach(File.join(sessions_dir, name))).to_a }
       .sort_by { |record| record["ts"].to_s }
  end

  def graph_revisions = journal_records.select { |record| record["type"] == "graph_revision" }

  before { write_epic(graph_of(issue("a", blocks: %w[b], criteria:), issue("b"))) }

  describe "split" do
    # Scenario: a split is journaled and replayable
    it "lists the parts in place of the original issue in epic.md" do
      command.split("a", "a1,a2", "alpha")

      graph = home.read_epic
      expect(graph.ids).to contain_exactly("a1", "a2", "b")
      expect(epic_bytes).to include("`a1`", "`a2`")
      # `a` itself no longer heads a section -- it survives only as
      # `Discovered from: `a`` provenance on the parts, which is designed
      # state (Graph#split's superseded-id rule), not a leftover heading.
      headings = epic_bytes.lines.grep(/\A### /)
      expect(headings).not_to include(a_string_matching(/`a`/))
    end

    it "carries the original's criteria onto every part" do
      command.split("a", "a1,a2", "alpha")

      graph = home.read_epic
      expect(graph.fetch("a1").criteria).to eq(criteria)
      expect(graph.fetch("a2").criteria).to eq(criteria)
    end

    it "journals exactly one graph_revision that replays through GraphFiber to the same graph" do
      before_graph = home.read_epic

      command.split("a", "a1,a2", "alpha")

      expect(graph_revisions.size).to eq(1)
      fiber = Lain::Epic::GraphFiber.of(graph_revisions.first)
      replayed = fiber.replay(before_graph)

      expect(replayed.digest).to eq(home.read_epic.digest)
      expect(fiber.reproduces?(before_graph)).to be(true)
    end

    it "rewrites a third party's edge onto every part, so whoever waited on the whole still waits on it" do
      write_epic(graph_of(issue("a", blocks: %w[b], criteria:), issue("b"), issue("z", blocks: %w[a])))

      command.split("a", "a1,a2", "alpha")

      expect(home.read_epic.fetch("z").blocks).to contain_exactly("a1", "a2")
    end

    # Scenario: an unknown issue is refused before anything is written
    it "refuses an unknown issue, naming it, before anything is written" do
      before_bytes = epic_bytes

      expect { command.split("z", "z1,z2", "alpha") }.to raise_error(Lain::Epic::UnknownIssue, /z/)
      expect(epic_bytes).to eq(before_bytes)
      expect(graph_revisions).to be_empty
    end

    it "leaves every OTHER issue's rendered bytes untouched" do
      before_section = Lain::Epic::Document::Writer.new(home.read_epic.fetch("b")).to_s

      command.split("a", "a1,a2", "alpha")

      after_section = Lain::Epic::Document::Writer.new(home.read_epic.fetch("b")).to_s
      expect(after_section).to eq(before_section)
    end
  end

  describe "add" do
    it "adds a new issue and journals its arrival" do
      result = command.add("c", "the c issue", "alpha")

      expect(home.read_epic.ids).to contain_exactly("a", "b", "c")
      expect(result).to include("add applied to epic `alpha`")
      expect(graph_revisions.map { |record| record["operation"] }).to eq(["add"])
    end

    it "records the discovered_from provenance it was given" do
      command.add("c", "the c issue", "alpha", discovered_from: "a")

      expect(home.read_epic.fetch("c").discovered_from).to eq("a")
    end

    it "refuses a duplicate id before anything is written" do
      before_bytes = epic_bytes

      expect { command.add("a", "a again", "alpha") }.to raise_error(Lain::Epic::MalformedGraph)
      expect(epic_bytes).to eq(before_bytes)
    end
  end

  describe "merge" do
    it "replaces both sides with the arrival, inheriting their edges" do
      write_epic(graph_of(issue("a", blocks: %w[c]), issue("b", blocks: %w[c]), issue("c")))

      command.merge("a", "b", "alpha", as: "ab", title: "the merged issue")

      graph = home.read_epic
      expect(graph.ids).to contain_exactly("ab", "c")
      expect(graph.fetch("ab").blocks).to eq(["c"])
    end

    it "defaults the title to combining both sides' when none is given" do
      command.merge("a", "b", "alpha", as: "ab")

      expect(home.read_epic.fetch("ab").title).to eq("the a issue / the b issue")
    end

    it "refuses merging an issue with itself before anything is written" do
      before_bytes = epic_bytes

      expect { command.merge("a", "a", "alpha", as: "a2") }.to raise_error(Lain::Epic::MalformedGraph)
      expect(epic_bytes).to eq(before_bytes)
    end
  end

  it "resolves the sole epic when no slug is named, exactly as every other epic verb does" do
    command.add("c", "the c issue")

    expect(home.read_epic.ids).to include("c")
  end
end
