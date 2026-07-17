# frozen_string_literal: true

# exe/lain is a script, not a lib file: it ends in `LainCLI.start(ARGV)`,
# guarded by `$PROGRAM_NAME == __FILE__` so this `load` defines the class
# WITHOUT parsing rspec's ARGV or touching the network (the cli_spec.rb
# precedent). Unlike repl_middleware_spec, which mirrors the SHAPE of the
# stack, this drives the REAL Repl#dispatch/#respond/#deliver seam: B0 makes
# `dispatch` OWN delivery so a short-circuiting repl-phase middleware (one that
# sets `env[:response]` without calling downstream) actually renders, and so a
# Lain::Error raised in the middleware chain renders instead of crashing the
# loop. The two async collaborators respond leans on -- the conductor's
# supervise and the ask_human reply surfaces -- are the only doubles: the rest
# is the shipped control flow.
load File.expand_path("../../exe/lain", __dir__)

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

  def build_repl(middleware:)
    repl = LainCLI::Repl.new(
      agent:, tty:, chronicle: spy("chronicle"),
      conductor:, middleware:, ask_human: nil, questions: nil
    )
    repl.instance_variable_set(:@replies, replies)
    repl
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

  it "renders a loud named error and survives when a short-circuit omits :response" do
    repl = build_repl(middleware: Lain::Middleware::Stack.new.use(short_circuit_omitting_response))

    expect { dispatch(repl) }.not_to raise_error
    expect { dispatch(repl) }.not_to raise_error # the loop lives to see the next prompt

    expect(tty).to have_received(:render_error).with(a_string_including(":response")).twice
    expect(tty).not_to have_received(:render_response) # never a silent nil deliver
    expect(agent).not_to have_received(:ask)
  end
end
