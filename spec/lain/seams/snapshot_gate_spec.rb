# frozen_string_literal: true

require "tmpdir"

# A chat built by the production Wiring over a real shadow-git store, its rounds
# scripted by a mock provider, and /undo run as the human types it.
RSpec.describe "the snapshot a round stages", :seam do
  around do |example|
    Dir.mktmpdir("lain-snapshot-gate-project") do |project|
      Dir.mktmpdir("lain-snapshot-gate-state") do |state|
        @project = File.realpath(project)
        @state = state
        # The workspace profile refuses a TMPDIR holding home, as the spec's TMPDIR holds this chat's.
        Dir.mktmpdir("lain-snapshot-gate-tmp") { |tmp| with_env("TMPDIR" => tmp) { example.run } }
      end
    end
  end

  let(:git_adds) { [] }
  let(:channel) { Lain::Channel.new }
  let(:journal) { RecordingChannel.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: File.join(@state, "session.ndjson")) }

  let(:backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root:)
        super(options, root:)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  before do
    allow(Lain::Shell::Out).to receive(:new).and_wrap_original do |original, *argv, **options|
      git_adds << argv if argv.first == "git" && argv.include?("add")
      original.call(*argv, **options)
    end
  end

  def in_project(name) = File.join(@project, name)

  def call(name, input) = ["tu_#{SecureRandom.hex(4)}", name, input]

  def write_file(name, content) = call("write_file", { "path" => in_project(name), "content" => content })

  def read_file(name) = call("read_file", { "path" => in_project(name) })

  def bash(command) = call("bash", { "command" => command })

  def subagent(prompt) = call("subagent", { "prompt" => prompt, "role" => "researcher" })

  def text(words = "done")
    Lain::Response.new(content: [{ "type" => "text", "text" => words }], stop_reason: :end_turn)
  end

  # Each argument is 1 round: the calls its assistant turn makes together, or a reply a child gives.
  def responses(rounds) = [*rounds.map { |calls| calls.is_a?(Lain::Response) ? calls : tool_response(*calls) }, text]

  def wiring(options)
    Lain::CLI::Wiring.new(
      options: { grace: 5, **options }, chronicle:, status_feed: instance_double(Lain::StatusFeed),
      human: Lain::CLI::Human.new(kind: :terminal),
      project: Lain::Project.new(root: @project, cwd: @project, kind: :project, detected_by: :flag),
      paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state })
    )
  end

  def chat(*rounds, options: {})
    wiring = wiring(options)
    recorder, session = wiring.run_state(nil)
    backend = backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                mock: Lain::Provider::Mock.new(responses: responses(rounds)), root: @project)
    @agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
    @board = wiring.role_spawn.seam.tool_middleware.board.call
    @board.mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")
    @agent.ask("go")
  end

  def undo = Lain::CLI::Command::Undo.new.call("", build_command_env(agent: @agent, snapshots: @board.snapshots))

  def contents(name) = File.exist?(in_project(name)) ? File.binread(in_project(name)) : :absent

  def profiles = journal.events.grep(Lain::Telemetry::Sandbox).map(&:profile).uniq

  def results
    @agent.timeline.to_a.select { _1.role == "user" }.flat_map(&:content).grep(Hash)
          .select { _1["type"] == "tool_result" }
  end

  def sandbox!
    fence = Lain::Confine::Bwrap.fence_binary
    skip("bwrap is not installed") unless File.executable?("/usr/bin/bwrap")
    skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
  end

  describe "/undo over the round shapes" do
    it "reaches past a read-only round to the write round before it" do
      chat([write_file("a.txt", "made\n")], [read_file("a.txt")])

      expect(undo).to eq("undid the only undoable file-changing turn: deleted a.txt")
      expect(contents("a.txt")).to eq(:absent)
      expect(undo).to eq(Lain::CLI::Command::Undo::NOTHING)
    end

    it "has nothing to undo after a read-only round alone" do
      File.binwrite(in_project("a.txt"), "kept\n")
      chat([read_file("a.txt")])

      expect(undo).to eq(Lain::CLI::Command::Undo::NOTHING)
      expect(contents("a.txt")).to eq("kept\n")
    end

    it "undoes 2 write rounds one at a time, newest first" do
      chat([write_file("a.txt", "one\n")], [write_file("b.txt", "two\n")])

      expect(undo).to eq("undid the latest of 2 undoable file-changing turns: deleted b.txt")
      expect([contents("a.txt"), contents("b.txt")]).to eq(["one\n", :absent])
      expect(undo).to eq("undid the only undoable file-changing turn: deleted a.txt")
      expect(contents("a.txt")).to eq(:absent)
    end
  end

  # Each primed round stages twice: the baseline before its first write, and the tree it settles on.
  describe "when a round stages" do
    before { sandbox! }

    it "stages nothing for a round whose only bash call runs under the reader profile" do
      File.binwrite(in_project("a.txt"), "kept\n")
      chat([bash("cat a.txt")])

      expect(profiles).to eq([:reader])
      expect(git_adds).to eq([])
      expect(undo).to eq(Lain::CLI::Command::Undo::NOTHING)
    end

    it "undoes a workspace bash round" do
      File.binwrite(in_project("a.txt"), "before\n")
      chat([bash("printf after > a.txt")])

      expect(profiles).to eq([:workspace])
      expect(contents("a.txt")).to eq("after")
      undo
      expect(contents("a.txt")).to eq("before\n")
    end

    it "undoes a bash round run with no sandbox" do
      File.binwrite(in_project("a.txt"), "before\n")
      chat([bash("printf after > a.txt")], options: { confine: "off" })

      expect(contents("a.txt")).to eq("after")
      undo
      expect(contents("a.txt")).to eq("before\n")
    end

    it "stages before a write_file that follows a reader bash call in the round" do
      File.binwrite(in_project("a.txt"), "kept\n")
      chat([bash("cat a.txt"), write_file("b.txt", "made\n")])

      expect(contents("b.txt")).to eq("made\n")
      undo
      expect(contents("b.txt")).to eq(:absent)
    end

    it "stages once for 2 subagent calls made together, which write nothing" do
      chat([subagent("say hi"), subagent("say ho")], text("hi"), text("ho"))

      expect(results.map { _1["content"] }).to contain_exactly("hi", "ho")
      expect(git_adds.size).to eq(2)
    end

    it "does not restage for the round's second call that writes" do
      File.binwrite(in_project("c.txt"), "c before\n")
      chat([write_file("a.txt", "made\n"), bash("printf after > c.txt")])

      expect([contents("a.txt"), contents("c.txt")]).to eq(%W[made\n after])
      expect(git_adds.size).to eq(2)
      undo
      expect([contents("a.txt"), contents("c.txt")]).to eq([:absent, "c before\n"])
    end

    it "stages nothing for a round whose only bash call the approval gate refuses" do
      chat([bash("cat #{Dir.home}/.ssh/id_ed25519")])

      expect(results.sole["content"]).to start_with("refused tool \"bash\"")
      expect(git_adds).to eq([])
    end
  end

  # The reader profile writes /tmp, so a project there is one its calls can change.
  describe "a project under /tmp" do
    around do |example|
      Dir.mktmpdir("lain-snapshot-gate-tmp-project", "/tmp") do |project|
        @project = File.realpath(project)
        example.run
      end
    end

    before { sandbox! }

    it "stages for a reader bash call" do
      File.binwrite(in_project("a.txt"), "kept\n")
      chat([bash("cat a.txt")])

      expect(profiles).to eq([:reader])
      expect(git_adds.size).to eq(2)
    end
  end
end
