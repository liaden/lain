# frozen_string_literal: true

RSpec.describe Lain::CLI::Wiring do
  # Provider resolution, context, slots, and spawn policies stay the real
  # Backend's; only the network edge swaps for Provider::Mock, so the whole
  # chat assembly is exercised offline exactly as the exe wires it (T1 AC:
  # the extracted Repl is constructible without the exe).
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:)
        super(options)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend) { offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider) }
  let(:channel) { Lain::Channel.new }
  let(:chronicle) { Lain::CLI::Chronicle::Null.new }
  let(:wiring) { described_class.new(options: { grace: 5 }, chronicle:) }

  def wire_agent
    recorder, session = wiring.run_state(nil)
    wiring.wire_agent(channel:, recorder:, session:, backend:)
  end

  describe "#wire_agent" do
    it "builds the Agent over the injected backend's provider, no exe involved" do
      agent = wire_agent
      expect(agent).to be_a(Lain::Agent)
      expect(agent.ask("ping").text).to eq("settled")
      expect(mock_provider.call_count).to eq(1)
    end

    it "exposes the reply seam and fleet supervisor it wired, as its own accessors" do
      wire_agent
      expect(wiring.ask_human).to be_a(Lain::Tools::AskHuman::Notifying)
      expect(wiring.questions).to be_a(Async::Queue)
      expect(wiring.supervisor).to be_a(Lain::Supervisor)
      expect(wiring.approvals).to be_a(Lain::Approval::Queue)
    end
  end

  describe "#run" do
    require "stringio"
    require "tmpdir"

    # The T9 injection seams: a spec assembles and runs the whole conversation
    # through #run's own path -- no send(:build_repl), no instance_variable_set
    # -- by handing in a StringIO-backed TTY factory and a recording conductor
    # opener instead of the real-terminal defaults.
    let(:opened) { [] }
    let(:conductor_opener) { ->(**kwargs) { Lain::CLI::Conductor.open(**kwargs).tap { |c| opened << c } } }

    def tty_factory(input, dir)
      lambda do |channel:|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, input: StringIO.new(input),
                                history_path: File.join(dir, "history"))
      end
    end

    def run_wiring(input: "quit\n", options: { grace: 5 })
      Dir.mktmpdir do |dir|
        wiring = described_class.new(options:, chronicle:,
                                     tty_factory: tty_factory(input, dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        wiring
      end
    end

    it "threads the injected tty/conductor seams -- the conductor the opener built is the one exposed" do
      wiring = run_wiring

      expect(opened).to eq([wiring.conductor])
    end

    it "assembles the frozen Command::Env once, nil-free, from the collaborators it wired" do
      wiring = run_wiring
      env = wiring.command_env

      expect(env).to be_frozen
      expect(env.sessions).to be_a(Lain::CLI::Sessions)
      expect(env.tmux_surface).to be_a(Lain::CLI::TmuxSurface)
      expect(env.approvals).to be(wiring.approvals)
      expect(env.supervisor).to be(wiring.supervisor)
      expect(env.replies).to be_a(Lain::CLI::HumanReplies)
      expect(env.agent).to be_a(Lain::Agent)
      expect(env.status).to be(Lain::CLI::Command::Env::NullStatus)
      expect(env.fork_point).to be(Lain::CLI::Command::Env::NullForkPoint)
    end

    it "wires the queue-shaped NullApprovals under --yolo, so the env reader stays nil-free" do
      wiring = run_wiring(options: { grace: 5, yolo: true })

      expect(wiring.command_env.approvals).to be(Lain::CLI::Command::Env::NullApprovals)
    end
  end
end
