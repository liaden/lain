# frozen_string_literal: true

# The turn phase: a Middleware::Stack wrapping EACH iteration of #run's loop
# (budget check, iteration count, model call, commit, transition), wired the
# same way model_middleware/tool_middleware already are. See Agent#turn_env
# for the env shape and why it is kept minimal.
RSpec.describe "Agent turn_middleware" do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
  let(:toolset) { Lain::Toolset.new([]) }

  def agent(responses, **overrides)
    Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: Array(responses)),
      toolset:,
      context:,
      **overrides
    )
  end

  # Records the :iteration seen on each pass, proving the stack wraps every
  # turn of the loop rather than the run as a whole.
  def counting_middleware(calls)
    Class.new(Lain::Middleware::Base) do
      define_method(:call) do |env, &downstream|
        calls << env.fetch(:iteration)
        downstream.call(env)
      end
    end.new
  end

  it "threads each turn iteration through the stack (N calls for N turns)" do
    calls = []
    stack = Lain::Middleware::Stack.new.use(counting_middleware(calls))
    responses = [
      text_response("", stop_reason: :pause_turn),
      text_response("", stop_reason: :pause_turn),
      text_response("done")
    ]

    agent(responses, turn_middleware: stack).ask("hi")

    expect(calls).to eq([0, 1, 2])
  end

  it "gives a middleware :iteration and :timeline going in, :response and :settled coming out" do
    # Stays local rather than moving to spec/support: it closes over `seen`, an
    # example-local variable it assigns as its side effect. A shared probe class
    # can't capture per-example state without an injected accumulator (as
    # ContextProbe in spec/support/probes.rb does with @sightings) -- for a
    # single assertion like this, the closure is the simpler shape.
    seen = nil
    probe = Class.new(Lain::Middleware::Base) do
      define_method(:call) do |env, &downstream|
        seen = downstream.call(env)
      end
    end.new

    agent(text_response, turn_middleware: Lain::Middleware::Stack.new.use(probe)).ask("hi")

    expect(seen[:iteration]).to eq(0)
    expect(seen[:timeline]).to be_a(Lain::Timeline)
    expect(seen[:response]).to be_a(Lain::Response)
    expect(seen[:settled]).to be(true)
  end

  describe "the monoid law (property-tested)" do
    def tag(symbol)
      Class.new(Lain::Middleware::Base) do
        define_method(:call) do |env, &downstream|
          entered = env.merge(trace: env.fetch(:trace, []) + [[symbol, :in]])
          exited = downstream.call(entered)
          exited.merge(trace: exited.fetch(:trace) + [[symbol, :out]])
        end
      end.new
    end

    def observe(middleware)
      env = Lain::Middleware::Env.wrap({ iteration: 0, timeline: nil, trace: [] })
      middleware.call(env) { |inner| inner }.fetch(:trace)
    end

    let(:pool) { { a: tag(:a), b: tag(:b), c: tag(:c), d: tag(:d) } }

    def compose(sequence)
      sequence.map { |symbol| pool.fetch(symbol) }.reduce(Lain::Middleware::Identity, :>>)
    end

    include_examples "a monoid",
                     operation: ->(a, b) { a >> b },
                     identity: Lain::Middleware::Identity,
                     generator: -> { compose(Array.new(rand(0..3)) { %i[a b c d].sample }) },
                     equal: ->(a, b) { observe(a) == observe(b) }
  end

  describe "gate 7 through the turn phase" do
    it "still raises once max_iterations is reached, with a real turn phase wired" do
      calls = []
      stack = Lain::Middleware::Stack.new.use(counting_middleware(calls))
      responses = Array.new(5) { text_response("", stop_reason: :pause_turn) }

      a = agent(responses, budget: Lain::Agent::Budget.new(max_iterations: 3), turn_middleware: stack)

      expect { a.ask("hi") }.to raise_error(Lain::Agent::BudgetExceeded, /3 iterations/)
      # The budget check itself lives inside the wrapped body (#step), so the
      # phase's outer middleware still observes the 4th, over-the-ceiling
      # attempt before Budget::Exceeded unwinds out of the downstream call --
      # the ceiling is enforced BEHIND the seam, not around it.
      expect(calls).to eq([0, 1, 2, 3])
    end

    it "does not conflate a budget stop with a refusal, through the turn phase" do
      stack = Lain::Middleware::Stack.new.use(Lain::Middleware::Identity)
      a = agent(text_response("", stop_reason: :refusal), turn_middleware: stack)

      expect { a.ask("hi") }.not_to raise_error
      expect(a).to be_failed
    end

    # The trust boundary, pinned as an OBSERVED fact rather than an implicit
    # assumption. gate 7 (the budget/iteration ceiling) is enforced INSIDE the
    # block the turn phase runs as its downstream -- so a well-behaved
    # middleware cannot suppress it, and a middleware that drops :settled or
    # :response fails loudly on env.fetch's KeyError. But a middleware that
    # fabricates its own {settled:, response:} and NEVER calls downstream skips
    # #step entirely: @iterations never advances, the provider is never asked,
    # the budget is never checked. This is the SAME trust model the model and
    # tool phases already carry (a downstream-skipping middleware there also
    # bypasses the work) and is consistent with deferring the interrupt /
    # concurrency machinery -- the seam is PLACED, not yet hardened. It is
    # accepted behavior, not a bug; this spec makes that reality explicit so a
    # future change to it is a conscious decision, not a silent regression.
    it "lets a short-circuiting middleware bypass step, budget, and the provider (accepted trust model)" do
      short_circuit = Class.new(Lain::Middleware::Base) do
        define_method(:call) do |env, &_downstream|
          # Never calls the downstream: settles immediately with a fabricated
          # response, so #step (and thus the budget check and the model call)
          # never runs.
          env.merge(response: :fabricated, settled: true)
        end
      end.new
      provider = Lain::Provider::Mock.new(responses: [text_response])
      a = Lain::Agent.new(
        provider:, toolset:, context:,
        budget: Lain::Agent::Budget.new(max_iterations: 0),
        turn_middleware: Lain::Middleware::Stack.new.use(short_circuit)
      )

      # A max_iterations of 0 would raise on the very first #step if it ran;
      # it does not, because the short-circuit skips #step entirely.
      result = a.run

      expect(result).to eq(:fabricated)
      expect(a.iterations).to eq(0)
      expect(provider.call_count).to eq(0)
    end
  end
end
