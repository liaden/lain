# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# `auto` approval on the path a real chat takes: {Lain::CLI::Wiring} builds the
# board, the board builds the judge-first ladder, and the judge asks the
# `auto_approver` role through the run's own role-spawn seam. Only the provider
# is canned, so the judge's answer is a child's reply rather than a stub.
RSpec.describe "auto approval asks the judge before a human", :seam do
  around do |example|
    Dir.mktmpdir("lain-judged-approval") do |dir|
      @state = File.realpath(dir)
      @cwd = File.join(@state, "services")
      FileUtils.mkdir_p(@cwd)
      example.run
    end
  end

  let(:journal_io) { StringIO.new }
  let(:chronicle) do
    Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "judged-approval.ndjson")
  end
  let(:provider) do
    Lain::Provider::Mock.new(responses: [
                               tool_response(["tu_1", "bash", { "command" => "rm -rf build" }]),
                               text_response("DEFER"),
                               text_response("settled")
                             ])
  end
  let(:backend) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, **)
        super(options, **)
        @mock = mock
      end

      def provider(**) = @mock
    end.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: provider, root: @state)
  end
  let(:wiring) do
    Lain::CLI::Wiring.new(options: { grace: 5, approval: "auto" }, chronicle:,
                          status_feed: instance_double(Lain::StatusFeed, bind_store: nil),
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }),
                          project: Lain::Project.new(root: @state, cwd: @cwd, kind: :project, detected_by: :flag))
  end

  def escalations = journal_records(journal_io, "escalation")

  def denied_after_judging
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)

    Sync do |task|
      asked = task.async { agent.ask("clean the build") }
      parked = task.with_timeout(5) { wiring.approvals.dequeue }
      parked.deny(surface: "tty")
      task.with_timeout(5) { asked.wait }
      parked
    end
  end

  it "parks a gated command the judge defers, for the human to decide" do
    pending = denied_after_judging

    expect(pending).not_to be_humans_only
    expect(provider.requests[1].messages.to_s).to include("A tool call is requesting approval")
    expect(escalations).to include(a_hash_including("rung" => "auto", "verdict" => "abstain",
                                                    "reason" => Lain::Approval::Judged::DEFERRED))
  end

  context "when the judge approves the call" do
    let(:channel) { Lain::Channel.new }
    let(:provider) do
      Lain::Provider::Mock.new(responses: [
                                 tool_response(["tu_1", "bash", { "command" => "git log --oneline -5" }]),
                                 text_response("APPROVE"),
                                 text_response("settled")
                               ])
    end

    it "puts one judge-approved line on the run's display channel, rendered as a stamped transcript line" do
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
      Sync { agent.ask("show the log") }
      channel.close
      theme = Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false))
      lines = channel.drain.grep(Lain::Telemetry::JudgeApproved).map { Lain::Frontend::Decorators.for(_1).render(theme) }

      expect(lines).to eq(['the judge approved bash({"command" => "git log --oneline -5"})'])
    end
  end

  # The project is not where the process stands, so a judge told the process's
  # directory would be told a place the call does not run in.
  it "tells the judge the project's working directory" do
    denied_after_judging

    expect(Dir.pwd).not_to eq(@cwd)
    expect(provider.requests[1].system.last["text"]).to end_with("Working directory: #{@cwd}")
  end

  context "when the command reads a credential" do
    let(:command) { "cat .env" }
    let(:provider) do
      Lain::Provider::Mock.new(responses: [
                                 tool_response(["tu_1", "bash", { "command" => command }]),
                                 text_response("APPROVE"),
                                 text_response("settled")
                               ])
    end

    def denied_park
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)

      Sync do |task|
        asked = task.async { agent.ask("show me the env file") }
        parked = task.with_timeout(5) { wiring.approvals.dequeue }
        parked.deny(surface: "tty")
        task.with_timeout(5) { asked.wait }
        parked
      end
    end

    def parked_unjudged
      [denied_park.tool.to_s, provider.requests.none? { _1.messages.to_s.include?("requesting approval") }]
    end

    it "parks it for the human without spawning the judge" do
      expect(parked_unjudged).to eq(["bash", true])
      expect(escalations).to include(a_hash_including("rung" => "auto", "verdict" => "abstain",
                                                      "reason" => Lain::Approval::Judged::UNJUDGEABLE))
    end

    context "when it names the credential through ~" do
      let(:command) { "cat ~/notes" }

      it "reads ~ as the chat's own home, not the process's" do
        File.write(File.join(@state, ".env"), "TOKEN=1\n")
        File.symlink(File.join(@state, ".env"), File.join(@state, "notes"))

        expect(parked_unjudged).to eq(["bash", true])
      end
    end
  end

  # A human's no under `ask` is held by the paths the call named, whatever tool
  # named them, so the same file is not asked about twice.
  context "when a human denied an earlier call under ask" do
    let(:calls) { [] }
    let(:provider) do
      asked = calls.each_with_index.map { |(name, input), i| tool_response(["tu_#{i}", name, input]) }
      Lain::Provider::Mock.new(responses: [*asked, text_response("settled")])
    end
    let(:wiring) do
      Lain::CLI::Wiring.new(options: { grace: 5, approval: "ask" }, chronicle:,
                            status_feed: instance_double(Lain::StatusFeed, bind_store: nil),
                            paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }),
                            project: Lain::Project.new(root: @state, cwd: @cwd, kind: :project, detected_by: :flag))
    end

    def bash(command, **input) = ["bash", { "command" => command, **input }]
    def read(path) = ["read_file", { "path" => path }]

    def chat_agent
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
    end

    def parks = Lain::Journal.records(journal_io.string.lines, type: "approval_pending").count

    def parks_denying(reason)
      agent = chat_agent
      Sync do |task|
        asked = task.async { agent.ask("look around") }
        task.with_timeout(5) { wiring.approvals.dequeue }.deny(surface: "tty", reason:)
        later = task.async { loop { wiring.approvals.dequeue.deny(surface: "tty") } }
        task.with_timeout(5) { asked.wait }
        later.stop
      end
      parks
    end

    def remembered = escalations.select { _1["rung"] == Lain::Middleware::RememberedDenials::RUNG }

    context "when the denied call was a bash read" do
      let(:calls) { [bash("cat .env"), read(".env")] }

      it "refuses a later read of the same file from memory, with the human's reason" do
        expect(parks_denying("keep out")).to eq(1)
        expect(remembered).to contain_exactly(a_hash_including("tool" => "read_file", "verdict" => "deny"))
        expect(provider.requests.last.messages.to_s).to include("keep out")
      end
    end

    context "when the denied call was a read_file" do
      let(:calls) { [read(".env"), bash("cat .env")] }

      it "refuses a later bash read of the same file from memory" do
        expect(parks_denying("keep out")).to eq(1)
        expect(remembered).to contain_exactly(a_hash_including("tool" => "bash", "verdict" => "deny"))
      end
    end

    # The chat's home is the project root here, and `.cargo/credentials.toml`
    # is gated rather than refused outright, so its read would park.
    context "when the denied bash read named its file through ~" do
      let(:calls) { [bash("cat ~/.cargo/credentials.toml"), read("~/.cargo/credentials.toml")] }

      it "refuses a later read of the same file from memory" do
        expect(parks_denying("keep out")).to eq(1)
        expect(remembered).to contain_exactly(a_hash_including("tool" => "read_file", "verdict" => "deny"))
      end
    end

    context "when the denied command named no secret" do
      let(:calls) { [bash("rm -rf build", "cwd" => "."), read(".env")] }

      it "parks a later read in the same directory for the human" do
        expect(parks_denying("no deletes")).to eq(2)
        expect(remembered).to be_empty
      end
    end

    context "when the denied command named only the directory it ran in" do
      let(:calls) { [bash("git add ."), read(".env")] }

      it "parks a later read in that directory for the human" do
        expect(parks_denying("no staging")).to eq(2)
        expect(remembered).to be_empty
      end
    end

    context "when the denied command named the directory above" do
      let(:calls) { [bash("ls .."), read(".env")] }

      it "parks a later read below it for the human" do
        expect(parks_denying("not there")).to eq(2)
        expect(remembered).to be_empty
      end
    end

    # `.netrc` is refused outright, so a file that parks stands in for it.
    context "when the denied command's paths could not be named" do
      let(:calls) { [bash('cat "$HOME/.env"'), read("~/.env")] }

      it "parks a later read of the file it may have meant for the human" do
        expect(parks_denying("keep out")).to eq(2)
        expect(remembered).to be_empty
      end
    end
  end
end
