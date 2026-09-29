# frozen_string_literal: true

require "async"
require "fileutils"
require "mixlib/shellout"
require "tmpdir"

# The run's display Channel is not a journal. The TTY renders the few record
# types {Lain::Frontend::Decorators.for} knows and silently skips the rest, so a
# collaborator handed the Channel as its journal writes records nothing keeps.
# This drives a real chat assembly -- only the provider is doubled -- through the
# three things that journal off the Agent's own path (a shell call, a spawn and a
# supervisor's drain) and holds the Channel to one rule: whatever journalable
# record reaches it is either something the terminal shows, or something the
# session record also holds.
#
# The companion rule, stated on {Lain::CLI::Chronicle}: a record a live view folds
# goes to `record_journal`; a record nothing live folds goes to `durable_journal`.
RSpec.describe Lain::CLI::Wiring, "the journal routing discipline" do
  # Parks its settle until the drain's bound expires, so the drain has a timeout
  # to record. It answers the actor duck the supervisor's registry reads.
  let(:parked_worker_class) do
    Class.new do
      attr_reader :session

      def initialize(worker_env)
        @session = Lain::Session.new(worker_env:)
        @stopped = false
      end

      def settle = Async::Task.current.sleep(60)

      def stop
        @stopped = true
        self
      end

      def stopped? = @stopped

      def dead? = @stopped
    end
  end

  let(:provider) do
    Lain::Provider::Mock.new(responses: [
                               tool_response(["tu_bash", "bash", { "command" => "printf hello" }]),
                               tool_response(["tu_spawn", "subagent", { "prompt" => "look around" }]),
                               text_response("child done"),
                               text_response("parent done")
                             ])
  end
  let(:backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root: Dir.pwd)
        super(options, root:)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end
  let(:backend) { backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: provider) }
  let(:record) { RecordingChannel.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal: record, journal_path: "routing-discipline-session.ndjson") }
  let(:display) { RecordingChannel.new }
  let(:status_feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:options) { { grace: 5 } }

  around do |example|
    Dir.mktmpdir("lain-routing-state") do |state|
      @state = state
      example.run
    end
  end

  def wiring
    @wiring ||= described_class.new(options:, chronicle:, status_feed:,
                                    paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }))
  end

  # Tier-3 bash and the spawn would park on the approval gate; this spec is
  # about where records go, not who lets a call run.
  def approve_everything
    wiring.instance_variable_get(:@switchboard).mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "spec")
  end

  def converse
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: display, recorder:, session:, backend:)
    approve_everything
    agent.ask("run it, then look around")
  end

  def drain_a_parked_fleet
    Sync do |task|
      wiring.supervisor.run(task)
      wiring.supervisor.adopt(role: "researcher") { |worker_env| parked_worker_class.new(worker_env) }
      wiring.supervisor.drain(within: 0.01).each(&:settle)
    ensure
      wiring.supervisor.stop
    end
  end

  def journalable?(event) = event.class.include?(Lain::Telemetry::Journalable)

  def lost
    display.events.select { |event| journalable?(event) }
           .reject { |event| Lain::Frontend::Decorators.for(event) || record.events.include?(event) }
  end

  it "leaves no journalable record on the display channel that the terminal skips and the record lacks" do
    converse
    drain_a_parked_fleet

    expect(lost.map(&:journal_type).uniq).to eq([])
  end

  it "reaches the record with each of the three kinds this spec exercises" do
    converse
    drain_a_parked_fleet

    expect(record.events.map(&:class)).to include(Lain::Telemetry::ShellArm, Lain::Telemetry::IsolationLease,
                                                  Lain::Supervisor::DrainTimedOut)
  end

  # The fleet leasing real checkouts off a named branch is what makes the
  # handback run: the spawned child's lease ends in the run's one handoff, which
  # records how the child's work came home.
  context "when the fleet leases worktrees", :seam do
    let(:options) { { grace: 5, isolation: "worktree" } }

    around do |example|
      Dir.mktmpdir("lain-routing-repo") do |repo|
        repo = File.realpath(repo)
        FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", repo)
        Mixlib::ShellOut.new("git", "-C", repo, "switch", "-q", "-c", "feat",
                             environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.error!
        with_env("XDG_STATE_HOME" => @state) { Dir.chdir(repo) { example.run } }
      end
    end

    it "loses no handback or lease record to the display channel" do
      converse
      drain_a_parked_fleet

      expect(lost.map(&:journal_type).uniq).to eq([])
      expect(record.events.map(&:class)).to include(Lain::Telemetry::Handback, Lain::Telemetry::IsolationLease)
    end
  end
end
