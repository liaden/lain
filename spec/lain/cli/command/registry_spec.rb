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
  let(:env) { build_command_env }

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

    it "answers whether the line serves replies, so the Repl asks the bound registry and not the raw one" do
      expect(registry.bind(env).serves_replies?("/help")).to be(false)
    end
  end

  # T1 review, BLOCKER 1. {Lain::CLI::Repl::LineScope} brackets every dispatched
  # line in the human's reply surfaces, so a command that opens its OWN
  # `human> ` read ({Command::Inbox}) would run with a second reader on the same
  # stdin -- and the human's typed answer would go to whichever fiber won the
  # dequeue. The Repl asks this BEFORE the line runs; the command declares it.
  describe "#serves_replies?" do
    let(:draining) do
      Struct.new(:name) do
        def usage = "/#{name} -- probe"
        def call(_args, _env) = nil
        def serves_replies? = true
      end.new("inbox")
    end

    it "is false for a command that never says otherwise" do
      expect(registry.serves_replies?("/help")).to be(false)
    end

    it "is true for one that declares it" do
      expect(described_class.new([draining]).serves_replies?("/inbox")).to be(true)
    end

    it "is false for a line no command claims, so prose and skills are unaffected" do
      expect(registry.serves_replies?("hello there")).to be(false)
      expect(registry.serves_replies?("@researcher/help go")).to be(false)
    end

    # The declaration and the only command making it are pinned to each other:
    # `/inbox` is the whole reason this message exists, and a rename that lost
    # the declaration would put two readers back on one terminal in silence.
    it "is true for the shipped /inbox" do
      expect(described_class.new([Lain::CLI::Command::Inbox.new]).serves_replies?("/inbox")).to be(true)
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
