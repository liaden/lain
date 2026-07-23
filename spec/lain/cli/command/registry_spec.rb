# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Registry do
  # A command is one message -- call(args, env) -- so a bare Struct satisfies
  # the whole duck. It records its call so dispatch's parse -> call handoff is
  # observable.
  let(:probe_class) do
    Struct.new(:name, :log) do
      def usage = "/#{name} -- probe"

      def call(args, env)
        log << [args, env]
        "probe ran"
      end
    end
  end
  let(:log) { [] }
  let(:probe) { probe_class.new("help", log) }
  let(:registry) { described_class.new([probe]) }
  let(:env) do
    Lain::CLI::Command::Env.new(
      status: Lain::CLI::Command::Env::NullStatus,
      sessions: instance_double(Lain::CLI::Sessions),
      approvals: Lain::CLI::Command::Env::NullApprovals,
      supervisor: Lain::Supervisor::Null,
      replies: double("replies"),
      fork_point: instance_double(Lain::CLI::ForkPoint),
      tmux_surface: instance_double(Lain::CLI::TmuxSurface),
      agent: double("agent"),
      policy_switch: Lain::CLI::Command::Env::NullPolicySwitch,
      model_switch: Lain::CLI::Command::Env::NullModelSwitch,
      chronicle: Lain::CLI::Chronicle::Null.new,
      role_spawn: Lain::CLI::Command::Env::NullRoleSpawn
    )
  end

  describe "#dispatch" do
    it "runs a registered command with the parsed args and the shared env" do
      outcome = registry.dispatch("/help --all", env) { raise "fallthrough must not run" }

      expect(outcome).to eq("probe ran")
      expect(log).to eq([["--all", env]])
    end

    it "hands an argless invocation empty args, never nil" do
      registry.dispatch("/help", env) { raise "fallthrough must not run" }

      expect(log).to eq([["", env]])
    end

    it "falls through to the block for an unregistered /word -- SkillDispatch's turf" do
      expect(registry.dispatch("/nope", env) { :skill_dispatch }).to eq(:skill_dispatch)
      expect(log).to be_empty
    end

    it "falls through for plain prose" do
      expect(registry.dispatch("hello there", env) { :downstream }).to eq(:downstream)
    end

    it "falls through for a role-bound line even when the skill name is registered" do
      expect(registry.dispatch("@researcher/help go", env) { :downstream }).to eq(:downstream)
      expect(log).to be_empty
    end

    it "falls through for a path-shaped line, which is prose, not a typo" do
      expect(registry.dispatch("/etc/passwd was modified", env) { :downstream }).to eq(:downstream)
    end
  end

  describe "a command failing mid-call (panel fix 2)" do
    let(:failing_class) do
      Struct.new(:name, :error) do
        def usage = "/#{name} -- probe"

        def call(_args, _env) = raise(error)
      end
    end

    it "wraps a non-Lain raise into a loud ATTRIBUTED Lain::Error for the dispatch boundary to render" do
      registry.register(failing_class.new("boom", RuntimeError.new("kaboom")))

      expect { registry.dispatch("/boom", env) { raise "fallthrough must not run" } }
        .to raise_error(Lain::Error, "command /boom failed: kaboom")
    end

    it "lets a Lain::Error raise through unwrapped -- already loud, already renderable" do
      registry.register(failing_class.new("boom", Lain::Error.new("already loud")))

      expect { registry.dispatch("/boom", env) { raise "fallthrough must not run" } }
        .to raise_error(Lain::Error, "already loud")
    end

    it "never rescues the fallthrough path -- a middleware raise is the boundary's, untouched" do
      expect { registry.dispatch("not a command", env) { raise "downstream boom" } }
        .to raise_error(RuntimeError, "downstream boom")
    end
  end

  describe "#register" do
    it "returns self and lists commands in registration order" do
      quit = Lain::CLI::Command::Quit.new

      expect(registry.register(quit)).to be(registry)
      expect(registry.map(&:name)).to eq(%w[help quit])
    end

    it "refuses a second command claiming a registered name, loudly" do
      expect { registry.register(probe_class.new("help", [])) }
        .to raise_error(described_class::Collision, /help/)
    end
  end

  describe "#bind" do
    it "curries the one Wiring-assembled env, so the Repl dispatches with text alone" do
      bound = registry.bind(env)

      expect(bound).to be_frozen
      expect(bound.dispatch("/help now") { raise "fallthrough must not run" }).to eq("probe ran")
      expect(log).to eq([["now", env]])
    end

    it "still falls through for an unregistered word" do
      expect(registry.bind(env).dispatch("/nope") { :skill_dispatch }).to eq(:skill_dispatch)
    end
  end

  describe "the command interface" do
    it "is one message -- call(args, env) -- plus a name and a one-line usage" do
      help = Lain::CLI::Command::Help.new(registry:, catalog: Lain::Skill::Catalog.new({}))

      [help, Lain::CLI::Command::Quit.new].each do |command|
        expect(command.name).to be_a(String)
        expect(command.usage).to start_with("/#{command.name}")
        expect(command.method(:call).arity).to eq(2)
      end
    end

    it "/quit returns the Repl's wind-down action" do
      expect(Lain::CLI::Command::Quit.new.call("", env)).to eq(:quit)
    end
  end
end

RSpec.describe Lain::CLI::Command::Env do
  def readers
    { status: described_class::NullStatus, sessions: double("sessions"),
      approvals: described_class::NullApprovals, supervisor: Lain::Supervisor::Null,
      replies: double("replies"), fork_point: described_class::NullForkPoint,
      tmux_surface: double("tmux_surface"), agent: double("agent"),
      policy_switch: described_class::NullPolicySwitch, model_switch: described_class::NullModelSwitch,
      chronicle: Lain::CLI::Chronicle::Null.new, role_spawn: described_class::NullRoleSpawn }
  end

  it "is a frozen value over the twelve readers" do
    env = described_class.new(**readers)

    expect(env).to be_frozen
    expect(env.to_h.keys)
      .to eq(%i[status sessions approvals supervisor replies fork_point tmux_surface agent
                policy_switch model_switch chronicle role_spawn])
  end

  it "refuses a nil reader loudly, naming it -- Null collaborators, never nil" do
    expect { described_class.new(**readers, fork_point: nil) }
      .to raise_error(ArgumentError, /fork_point/)
  end

  it "answers the approval queue's read duck with nothing parked under --yolo" do
    expect(described_class::NullApprovals.each.to_a).to eq([])
  end
end
