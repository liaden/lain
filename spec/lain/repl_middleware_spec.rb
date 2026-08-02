# frozen_string_literal: true

require "tmpdir"

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
    stack.call({ text:, agent: :the_agent }) { |env| env.merge(response: "ran(#{env.fetch(:text)})") }
  end

  it "passes the env through an empty stack unchanged, plus the app's :response" do
    # Stack wraps at its boundary, so its return is an Env; to_h recovers the hash.
    result = run_command(Lain::Middleware::Stack.new, "hi")
    expect(result.to_h).to eq(text: "hi", agent: :the_agent, response: "ran(hi)")
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

  # T23: the factory used to hardcode a single-element Stack. These pin the
  # door it now has -- extras layer around the one fixed member, in the order
  # given, and the two keywords that feed that member stay required.
  describe "Lain::CLI::ReplMiddleware.build" do
    # role_spawn is only ever invoked for a `@role/skill` line; none of these
    # turns use that grammar, so a bare stub that is never called satisfies it.
    let(:role_spawn) { Object.new }

    def with_library
      Dir.mktmpdir { |root| yield Lain::Skill::Library.load(root:) }
    end

    def around(name, trace)
      Class.new(Lain::Middleware::Base) do
        define_method(:call) do |env, &downstream|
          trace << [name, :in]
          result = downstream.call(env)
          trace << [name, :out]
          result
        end
      end.new
    end

    it "holds exactly the skill dispatch middleware when built with no extras" do
      with_library do |library|
        stack = Lain::CLI::ReplMiddleware.build(library:, role_spawn:)

        expect(stack.to_a).to match([an_instance_of(Lain::Middleware::SkillDispatch)])
      end
    end

    it "runs extras in the order given, outside the skill dispatch" do
      with_library do |library|
        trace = []
        extras = [around(:a, trace), around(:b, trace)]

        stack = Lain::CLI::ReplMiddleware.build(library:, role_spawn:, extras:)

        expect(stack.to_a[0, 2]).to eq(extras)
        expect(stack.to_a.last).to be_an_instance_of(Lain::Middleware::SkillDispatch)

        stack.call({ text: "hi", agent: :the_agent }) { |env| env.merge(response: "ran") }

        expect(trace).to eq([%i[a in], %i[b in], %i[b out], %i[a out]])
      end
    end

    it "renders a recoverable error naming the fault when an extra short-circuits without :response" do
      with_library do |library|
        silent = Class.new(Lain::Middleware::Base) do
          # Deliberately never calls downstream, and never sets :response --
          # the fault repl.rb's dispatch boundary renders loudly rather than
          # rendering nothing or resuming the model turn.
          def call(env, &_app) = env
        end.new

        stack = Lain::CLI::ReplMiddleware.build(library:, role_spawn:, extras: [silent])
        result = stack.call({ text: "hi", agent: :the_agent }) { |env| env.merge(response: "ran") }

        expect(result.to_h).not_to have_key(:response)
      end
    end

    it "raises when built without a library, so a defaulted one cannot read the skill tree twice" do
      expect { Lain::CLI::ReplMiddleware.build(role_spawn:) }
        .to raise_error(ArgumentError, /library/)
    end

    it "raises when built without a role_spawn" do
      with_library do |library|
        expect { Lain::CLI::ReplMiddleware.build(library:) }
          .to raise_error(ArgumentError, /role_spawn/)
      end
    end
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
      env = Lain::Middleware::Env.wrap({ text: "hi", agent: :the_agent, trace: [] })
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
end
