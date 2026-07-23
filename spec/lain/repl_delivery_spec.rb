# frozen_string_literal: true

# Unlike repl_middleware_spec, which mirrors the SHAPE of the
# stack, this drives the REAL Repl#dispatch/#respond/#deliver seam: B0 makes
# `dispatch` OWN delivery so a short-circuiting repl-phase middleware (one that
# sets `env[:response]` without calling downstream) actually renders, and so a
# Lain::Error raised in the middleware chain renders instead of crashing the
# loop. The two async collaborators respond leans on -- the conductor's
# supervise and the ask_human reply surfaces -- are the only doubles: the rest
# is the shipped control flow. (T1 moved Repl out of exe/lain into
# Lain::CLI::Repl, so this no longer `load`s the exe -- `require "lain"`
# already defines the class under test.)

RSpec.describe "the repl phase's short-circuit delivery and dispatch-boundary rescue" do
  # A repl-phase middleware that answers the command itself: it sets
  # env[:response] and RETURNS WITHOUT calling downstream -- the B2/B3 short-
  # circuit shape whose delivery this card exists to give a home. Anonymous,
  # the way repl_middleware_spec builds its probes.
  def short_circuit_with(response)
    Class.new(Lain::Middleware::Base) do
      define_method(:initialize) do
        @response = response
        super()
      end

      define_method(:call) { |env, &_downstream| env.merge(response: @response) }
    end.new
  end

  # A middleware that blows up inside the chain (a malformed skill invocation is
  # the motivating case) before any downstream runs.
  def raising_middleware(message)
    Class.new(Lain::Middleware::Base) do
      define_method(:call) { |_env, &_downstream| raise Lain::Error, message }
    end.new
  end

  # A middleware that short-circuits but FORGETS the out-key: it returns the env
  # without setting `:response` and without calling downstream. `env.response`
  # (fetch(:response)) would then raise KeyError -- NOT a Lain::Error -- and
  # escape dispatch's rescue, killing converse. B0 must survive this loudly.
  def short_circuit_omitting_response
    Class.new(Lain::Middleware::Base) do
      define_method(:call) { |env, &_downstream| env }
    end.new
  end

  let(:response) { Struct.new(:text).new("the answer") }
  let(:tty) { spy("tty") }

  # Counts asks so "no model turn was spent" is an assertion, not a hope.
  let(:agent) do
    spy("agent").tap do |double|
      allow(double).to receive(:ask).and_return(response)
      allow(double).to receive(:timeline).and_return(spy("timeline"))
    end
  end

  # Stands in for the conductor's supervise: run the ask block and wrap its
  # result the way the real Outcome does (`#response`). No reactor, no ticker --
  # the only async we exercise is respond's own `Sync`, whose body then runs to
  # completion synchronously.
  let(:conductor) do
    spy("conductor").tap do |double|
      allow(double).to receive(:supervise) { |*_, &ask| spy("outcome", response: ask.call) }
    end
  end

  # The ask_human reply fibers are out of scope here; respond stops whatever
  # surfaces this hands back, and an empty set keeps the Sync from parking.
  let(:replies) { spy("replies", surfaces: []) }

  # An EMPTY command registry (by default) bound over a doubles-only Env:
  # every line falls through to the middleware phase, which is the seam under
  # test; the T9 panel-fix examples below hand in a registry of their own.
  # T9 made `replies:` injectable, so the old @replies ivar-poke is gone.
  def command_surface(registry)
    env = Lain::CLI::Command::Env.new(
      status: Lain::CLI::Command::Env::NullStatus, sessions: spy("sessions"),
      approvals: Lain::CLI::Command::Env::NullApprovals, supervisor: Lain::Supervisor::Null,
      replies:, fork_point: Lain::CLI::Command::Env::NullForkPoint,
      tmux_surface: spy("tmux_surface"), agent:,
      policy_switch: Lain::CLI::Command::Env::NullPolicySwitch,
      model_switch: Lain::CLI::Command::Env::NullModelSwitch,
      chronicle: Lain::CLI::Chronicle::Null.new, role_spawn: Lain::CLI::Command::Env::NullRoleSpawn
    )
    registry.bind(env)
  end

  def build_repl(middleware:, registry: Lain::CLI::Command::Registry.new)
    Lain::CLI::Repl.new(
      agent:, tty:, replies:, commands: command_surface(registry),
      chronicle: spy("chronicle"), conductor:, middleware:
    )
  end

  # A registered command whose call is the given block -- the probe shape.
  def command(name, &body)
    Struct.new(:name, :body) do
      def usage = "/#{name} -- probe"

      def call(args, env) = body.call(args, env)
    end.new(name, body)
  end

  def dispatch(repl, text = "hi") = repl.__send__(:dispatch, text)

  it "delivers a middleware-supplied response without spending a model turn" do
    repl = build_repl(middleware: Lain::Middleware::Stack.new.use(short_circuit_with(response)))

    dispatch(repl)

    expect(tty).to have_received(:render_response).with(response).once
    expect(agent).not_to have_received(:ask)
  end

  it "delivers the normal downstream response exactly once (no double-deliver)" do
    repl = build_repl(middleware: Lain::Middleware::Stack.new)

    dispatch(repl)

    expect(tty).to have_received(:render_response).with(response).once
    expect(agent).to have_received(:ask).with("hi").once
  end

  it "renders a Lain::Error raised in the middleware chain instead of crashing the loop" do
    repl = build_repl(middleware: Lain::Middleware::Stack.new.use(raising_middleware("malformed skill")))

    expect { dispatch(repl) }.not_to raise_error
    expect { dispatch(repl) }.not_to raise_error # the loop lives to see the next prompt

    expect(tty).to have_received(:render_error).with("malformed skill").twice
    expect(tty).not_to have_received(:render_response)
    expect(agent).not_to have_received(:ask)
  end

  it "recovers a command raising a NON-Lain error: attributed render, loop survives, no action leaks (P7b)" do
    boom = command("boom") { raise "plain RuntimeError" }
    repl = build_repl(middleware: Lain::Middleware::Stack.new,
                      registry: Lain::CLI::Command::Registry.new([boom]))

    expect(dispatch(repl, "/boom")).to be_nil # nil in the action position, never render_error's return
    expect { dispatch(repl, "/boom") }.not_to raise_error # the loop lives to see the next prompt

    expect(tty).to have_received(:render_error).with("command /boom failed: plain RuntimeError").twice
    expect(agent).not_to have_received(:ask)
  end

  it "recovers a command returning garbage: named breach, loop survives, no action leaks (P7b)" do
    garbage = command("garbage") { Object.new }
    repl = build_repl(middleware: Lain::Middleware::Stack.new,
                      registry: Lain::CLI::Command::Registry.new([garbage]))

    expect(dispatch(repl, "/garbage")).to be_nil
    expect { dispatch(repl, "/garbage") }.not_to raise_error

    expect(tty).to have_received(:render_error).with(a_string_including("neither rendered text")).twice
    expect(tty).not_to have_received(:render_response)
    expect(agent).not_to have_received(:ask)
  end

  it "renders a loud named error and survives when a short-circuit omits :response" do
    repl = build_repl(middleware: Lain::Middleware::Stack.new.use(short_circuit_omitting_response))

    expect { dispatch(repl) }.not_to raise_error
    expect { dispatch(repl) }.not_to raise_error # the loop lives to see the next prompt

    expect(tty).to have_received(:render_error).with(a_string_including(":response")).twice
    expect(tty).not_to have_received(:render_response) # never a silent nil deliver
    expect(agent).not_to have_received(:ask)
  end

  # T17: /btw seeds its child chat's FIRST question through --prompt, so the
  # ephemeral popup asks straight away and then behaves like any chat. converse
  # reads the terminal through the conductor; a farewell on the very next read
  # ends the loop, so a seeded run dispatches the seed then quits -- proving the
  # seed replaced exactly ONE read, not every read after it.
  describe "first_prompt seeds only the first converse pass" do
    let(:conductor) do
      spy("conductor").tap do |double|
        allow(double).to receive(:supervise) { |*_, &ask| spy("outcome", response: ask.call) }
        allow(double).to receive(:read_prompt).and_return("quit")
        allow(double).to receive(:closed?).and_return(false)
      end
    end

    it "dispatches the seed as the first ask, then reads the terminal for the next prompt" do
      repl = build_repl(middleware: Lain::Middleware::Stack.new)

      repl.__send__(:converse, first_prompt: "why is the build red?")

      expect(agent).to have_received(:ask).with("why is the build red?").once
      expect(agent).not_to have_received(:ask).with("quit")
      expect(conductor).to have_received(:read_prompt).once # the SECOND prompt, after the seed
    end

    it "reads the first prompt from the terminal when no seed is given" do
      allow(conductor).to receive(:read_prompt).and_return("hi", "quit")
      repl = build_repl(middleware: Lain::Middleware::Stack.new)

      repl.__send__(:converse)

      expect(agent).to have_received(:ask).with("hi").once
    end
  end
end
