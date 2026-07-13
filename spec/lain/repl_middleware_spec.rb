# frozen_string_literal: true

# The repl phase: exe/lain wraps each command typed at the prompt in a
# Middleware::Stack, wired the same way Agent's model_/tool_/turn_middleware
# already are (see lib/lain/agent.rb and exe/lain's `dispatch`). `exe/lain` is
# a Thor executable that calls `LainCLI.start(ARGV)` at load time -- per its
# own header comment, nothing there is unit-tested the way lib/ is, so this
# spec pins down the SHAPE the repl phase is built from instead: the env
# contract (`:text`/`:agent` going in, `:response` added on the way out) and
# that a Stack over that env satisfies the same monoid law every other phase
# does.
RSpec.describe "the repl phase's Middleware::Stack" do
  # exe/lain's `dispatch` in miniature: `:text`/`:agent` go in, downstream
  # runs the real command and the result comes back as `:response`.
  def run_command(stack, text)
    stack.call({ text: text, agent: :the_agent }) { |env| env.merge(response: "ran(#{env.fetch(:text)})") }
  end

  it "passes the env through an empty stack unchanged, plus the app's :response" do
    result = run_command(Lain::Middleware::Stack.new, "hi")
    expect(result).to eq(text: "hi", agent: :the_agent, response: "ran(hi)")
  end

  it "threads each command through every middleware in the stack, outermost first" do
    trace = []
    around = Class.new(Lain::Middleware::Base) do
      define_method(:call) do |env, &downstream|
        trace << [env.fetch(:text), :in]
        result = downstream.call(env)
        trace << [env.fetch(:text), :out]
        result
      end
    end.new
    stack = Lain::Middleware::Stack.new.use(around)

    run_command(stack, "one")
    run_command(stack, "two")

    expect(trace).to eq([["one", :in], ["one", :out], ["two", :in], ["two", :out]])
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
      middleware.call({ text: "hi", agent: :the_agent, trace: [] }) { |env| env }.fetch(:trace)
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
end
