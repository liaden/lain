# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# lain://status: the mounted epic's progress, its issue graph as a mermaid
# fence, and the fleet, re-folded from disk because the records it shows are
# written by OTHER processes. Driven over a real epic home and real session
# journals in a throwaway state home, because "another process wrote it" can
# only be staged on disk.
RSpec.describe Lain::Frontend::Neovim::StatusView do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      FileUtils.mkdir_p(root)
      example.run
    end
  end

  def root = File.join(@tmp, "project")
  def paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"), "HOME" => @tmp })
  def config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))
  def status = Lain::CLI::Epic.new(root:, paths:, config:)

  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)

  # a blocks b: one issue free to start and one waiting on it.
  def write_demo
    graph = Lain::Epic::Graph.new(issues: [issue("a", blocks: ["b"]), issue("b")])
    Lain::Epic::Home.resolve(config:, paths:, root:, slug: "demo").write_epic(graph)
  end

  # What `lain epic submit` leaves behind when it runs in ANOTHER process: a
  # session file of its own in the directory this chat's fold walks.
  def another_process_writes(name, *records)
    File.open(File.join(paths.sessions_dir, name), "w") do |io|
      journal = Lain::Journal.new(io:, clock: -> { "2026-01-01T00:00:00Z" })
      records.each { |record| journal.record(record) }
    end
  end

  def started(issue_id)
    Lain::Epic::IssueTransition.new(epic_slug: "demo", issue_id:, from_status: "pending", to_status: "in_flight")
  end

  def mounted = described_class::Mounted.new(slug: "demo", status:)

  def turn = Lain::Telemetry::TurnUsage.new(digest: "blake3:t", model: "m", stop_reason: :end_turn, usage: {})
  def tool_output = Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi")

  def spawn_event(id) = Lain::Event.new(kind: :spawn, payload_digest: "blake3:spawn-#{id}", from: "parent", to: nil)

  def completion(spawn)
    Lain::Event.new(kind: :message, payload_digest: "blake3:msg-done", from: "child", to: "parent",
                    body: { "result" => "ok", "lifecycle" => Lain::StatusFeed::SpawnLifecycle::STOPPED },
                    causal_parents: [spawn.digest, "blake3:final"])
  end

  describe "the buffer shows the epic's graph and fleet" do
    it "contains demo's progress, a mermaid fence of its issues, and the fleet" do
      write_demo
      view = described_class.new(epic: mounted)
      view.update(spawn_event("one"))

      lines = view.update(turn) || view.initial

      expect(lines).to include(a_string_including("demo"), a_string_including("0/2 done"))
      expect(lines).to include(a_string_matching(/`a`.*pending/), a_string_matching(/`b`.*blocked by `a`/))
      fence = lines.drop_while { |line| line != "```mermaid" }
      expect(fence[1]).to eq("flowchart TD")
      expect(fence).to include("    n_a --> n_b", "```")
      expect(lines).to include(a_string_including("- subagent  running"))
    end

    it "splits the mermaid source per line, so no rendered line carries a newline" do
      write_demo

      expect(described_class.new(epic: mounted).initial.grep(/\n/)).to be_empty
    end
  end

  describe "a transition written by another process" do
    it "appears once a turn completes" do
      write_demo
      view = described_class.new(epic: mounted)
      expect(view.initial).to include(a_string_matching(/`a`.*pending/))

      another_process_writes("other.ndjson", started("a"))

      expect(view.update(turn)).to include(a_string_matching(/`a`.*in_flight/), "    class n_a in_flight")
    end

    # A tool's stdout chunk arrives many times a second; folding every session
    # journal on each one is the cost the triggers exist to avoid.
    it "is not folded for an event that is neither a turn nor an epic record" do
      write_demo
      folds = 0
      counting = Class.new do
        define_method(:initialize) { |inner| @inner = inner }
        define_method(:progress) do |slug|
          folds += 1
          @inner.progress(slug)
        end
      end.new(status)
      view = described_class.new(epic: described_class::Mounted.new(slug: "demo", status: counting))
      view.initial

      3.times { view.update(tool_output) }

      expect(folds).to eq(1)
    end

    it "re-folds on an epic record this process journaled, without waiting for the turn" do
      write_demo
      view = described_class.new(epic: mounted)
      view.initial
      another_process_writes("mine.ndjson", started("a"))

      expect(view.update(started("a"))).to include(a_string_matching(/`a`.*in_flight/))
    end

    it "skips the redraw when a refold changed nothing" do
      write_demo
      view = described_class.new(epic: mounted)
      view.initial

      expect(view.update(turn)).to be_nil
    end
  end

  describe "a fold that fails, and a chat with no epic" do
    it "draws the fold's error into the buffer instead of raising" do
      write_demo
      another_process_writes("torn.ndjson", started("ghost"))
      view = described_class.new(epic: mounted)

      lines = nil
      expect { lines = view.initial }.not_to raise_error
      expect(lines).to include(a_string_including("status unavailable"), a_string_including("ghost"))
    end

    it "draws any error, not just the epic tier's, and keeps a multi-line message off one line" do
      broken = Class.new { def progress(_slug) = raise(IOError, "first line\nsecond line") }.new
      view = described_class.new(epic: described_class::Mounted.new(slug: "demo", status: broken))

      lines = view.initial

      expect(lines).to include(a_string_including("first line"), a_string_including("second line"))
      expect(lines.grep(/\n/)).to be_empty
    end

    it "recovers on the next turn once the journal folds again" do
      write_demo
      another_process_writes("torn.ndjson", started("ghost"))
      view = described_class.new(epic: mounted)
      view.initial
      another_process_writes("torn.ndjson", started("a"))

      expect(view.update(turn)).to include(a_string_matching(/`a`.*in_flight/))
    end

    it "says no epic is mounted when the chat has none" do
      expect(described_class.new.initial).to include(a_string_including("no epic is mounted"))
    end
  end

  describe "the fleet" do
    def progress(spawn, **) = Lain::Telemetry::ChildProgress.new(spawn: spawn.digest, **)

    def ended(spawn, lifecycle)
      Lain::Event.new(kind: :message, payload_digest: "blake3:msg-#{lifecycle}", from: "child", to: "parent",
                      body: { "lifecycle" => lifecycle }, causal_parents: [spawn.digest])
    end

    it "carries a spawn running, and says so when the record that ends it arrives" do
      view = described_class.new
      view.initial
      spawn = spawn_event("one")

      expect(view.update(spawn)).to include(a_string_including("running"))
      expect(view.update(completion(spawn))).to include(a_string_including("done"))
    end

    # The whole point of the tree: a human reads which child is doing what,
    # and which child spawned which, rather than a column of addresses.
    it "draws a grandchild indented under the child whose head it was spawned from" do
      view = described_class.new(clock: -> { Time.utc(2026, 9, 20, 12, 0, 0) })
      view.initial
      child = spawn_event("dev")
      view.update(child)
      view.update(progress(child, role: "dev", task_line: "port the parser", turns: 1, head: "blake3:dev-t1"))
      grandchild = Lain::Event.new(kind: :spawn, payload_digest: "blake3:spawn-test", from: "parent", to: nil,
                                   body: { "spawned_from" => "blake3:dev-t1" })
      view.update(grandchild)

      lines = view.update(progress(grandchild, role: "test_engineer", task_line: "write the specs", turns: 0))

      expect(lines).to include("- dev  running  1t  0s  port the parser",
                               "  - test_engineer  running  0t  0s  write the specs")
    end

    it "reads failed for a child that hit its ceiling" do
      view = described_class.new
      view.initial
      spawn = spawn_event("one")
      view.update(spawn)

      lines = view.update(ended(spawn, Lain::StatusFeed::SpawnLifecycle::FAILED))

      expect(lines).to include(a_string_including("failed"))
    end

    # The task line reaches this buffer as a row of its own, so a lone
    # carriage return in it would overwrite the columns drawn before it.
    it "keeps a forged task line to one line of the buffer" do
      view = described_class.new
      view.initial
      spawn = spawn_event("one")
      view.update(spawn)

      lines = view.update(progress(spawn, role: "dev", task_line: "look\raround", turns: 0))

      expect(lines.grep(/look/)).to contain_exactly(a_string_including("look around"))
    end

    # The same forgery the pane's header refuses. nvim draws an escape as a
    # glyph rather than obeying it, so the cost here is a row of mojibake
    # rather than a rewritten HUD -- but the rule is one rule, and this is the
    # surface that would otherwise carry the raw bytes into a buffer.
    it "draws a task line's terminal escape inert rather than passing the bytes through" do
      view = described_class.new
      view.initial
      spawn = spawn_event("one")
      view.update(spawn)

      lines = view.update(progress(spawn, role: "dev", task_line: "clean\e[1A\e[2KPWNED", turns: 0))

      expect(lines.grep(/PWNED/)).to contain_exactly(a_string_including("cleanPWNED"))
      expect(lines.join).not_to include("\e")
    end

    it "draws a fleet that raises into the buffer instead of raising" do
      fleet = Class.new do
        def launched(_event) = raise(NoMethodError, "undefined method 'digest'")
        def tree = []
      end.new
      view = described_class.new(fleet:)
      view.initial

      lines = nil
      expect { lines = view.update(spawn_event("one")) }.not_to raise_error
      expect(lines).to include(a_string_including("fleet unavailable"), a_string_including("digest"))
    end

    it "renders nothing new for an event that moves neither the fleet nor the epic" do
      view = described_class.new
      view.initial

      expect(view.update(tool_output)).to be_nil
    end
  end
end
