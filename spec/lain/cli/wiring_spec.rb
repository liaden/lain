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

    # T12 AC1: no --auto-approve, no third surface -- unchanged wiring.
    it "wires no auto surface without --auto-approve" do
      wire_agent
      expect(wiring.auto_surface).to be_nil
    end

    # T12 AC1: --auto-approve constructs the surface over the SAME role_spawn
    # seam a `@role/skill` line folds through.
    it "wires an AutoSurface over its own role_spawn seam under --auto-approve" do
      wiring = described_class.new(options: { grace: 5, auto_approve: true }, chronicle:)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)

      expect(wiring.auto_surface).to be_a(Lain::Approval::AutoSurface)
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
      expect(env.fork_point).to be_a(Lain::CLI::ForkPoint)
      expect(env.chronicle).to be(chronicle)
    end

    # The load-bearing identity AC1/AC3 stand on (T14 panel probe 7): a dropped
    # surface_kwargs would leave these readers on their Nulls and silently
    # disconnect /yolo from the Gate and /model from the Agent's Context.
    it "hands the Env the SAME switches the Gate and the Agent's context hold" do
      wiring = run_wiring
      env = wiring.command_env

      expect(env.policy_switch).to be_a(Lain::Approval::PolicySwitch)
      expect(env.policy_switch.current).to be(wiring.approvals)

      expect(env.model_switch).to be_a(Lain::Context::ModelSwitch)
      expect(env.agent.context.model).to eq(env.model_switch.current)
      env.model_switch.switch("probe-model-x", surface: "probe")
      expect(env.agent.context.model).to eq("probe-model-x")
    end

    it "wires the queue-shaped NullApprovals under --yolo, so the env reader stays nil-free" do
      wiring = run_wiring(options: { grace: 5, yolo: true })

      expect(wiring.command_env.approvals).to be(Lain::CLI::Command::Env::NullApprovals)
    end
  end
end
