# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Middleware::SkillDispatch do
  # A throwaway project tree, the renderer_spec pattern: a "shipped" skill dir
  # the catalog loads over, plus the Slots the renderer fills holes from. The
  # dispatch is a pure function of the frozen catalog + renderer built here.
  def with_dispatch(shipped: {}, &block)
    Dir.mktmpdir do |root|
      shipped_dir = File.join(root, "shipped")
      shipped.each { |path, body| write(File.join(shipped_dir, path), body) }
      catalog = Lain::Skill::Catalog.load(root:, shipped_dir:)
      slots = Lain::Prompt::Slots.load(root:, skill_shipped_dir: shipped_dir)
      renderer = Lain::Skill::Renderer.new(catalog:, slots:)
      block.call(described_class.new(catalog:, renderer:))
    end
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  # A minimal shipped skill: no front-matter, so no holes -- the scaffold is the
  # whole file. Enough to prove expansion without needing hole-default fixtures.
  def create_plan = { "create-plan/skill.md" => "# Create plan\nDo the planning.\n" }

  # exe/lain's dispatch in miniature: `:text`/`:agent` in, downstream records
  # the env it was handed (so we can assert what reached the model turn) and
  # answers with a `:response`.
  def run(dispatch, text, agent: :the_agent)
    seen = nil
    result = dispatch.call({ text:, agent: }) do |env|
      seen = env
      env.merge(response: "ran(#{env.fetch(:text)})")
    end
    [result, seen]
  end

  describe "an in-line skill invocation expands into the turn text" do
    it "hands downstream the rendered scaffold with the args appended, role unchanged" do
      with_dispatch(shipped: create_plan) do |dispatch|
        _result, seen = run(dispatch, "/create-plan add a write_file tool")

        expect(seen.fetch(:text)).to eq("# Create plan\nDo the planning.\n\n\nadd a write_file tool")
        expect(seen.fetch(:agent)).to eq(:the_agent) # one timeline, session role unchanged
      end
    end

    it "hands downstream the bare scaffold when the invocation carries no args" do
      with_dispatch(shipped: create_plan) do |dispatch|
        _result, seen = run(dispatch, "/create-plan")

        expect(seen.fetch(:text)).to eq("# Create plan\nDo the planning.\n")
      end
    end
  end

  describe "a non-skill line passes through untouched" do
    it "reaches downstream with env[:text] unchanged and runs a normal turn" do
      with_dispatch(shipped: create_plan) do |dispatch|
        result, seen = run(dispatch, "please help me plan")

        expect(seen.fetch(:text)).to eq("please help me plan")
        expect(result.fetch(:response)).to eq("ran(please help me plan)")
      end
    end

    it "treats a leading-slash path as prose, not a skill" do
      with_dispatch(shipped: create_plan) do |dispatch|
        _result, seen = run(dispatch, "/etc/passwd was modified")

        expect(seen.fetch(:text)).to eq("/etc/passwd was modified")
      end
    end
  end

  describe "an unknown skill is reported, not sent to the model" do
    it "short-circuits with a loud response naming the known set, no downstream turn" do
      with_dispatch(shipped: create_plan) do |dispatch|
        result, seen = run(dispatch, "/nope do a thing")

        expect(seen).to be_nil # downstream never ran -- no model turn spent
        expect(result.fetch(:response).text).to include("unknown skill", "nope", "create-plan")
      end
    end
  end

  describe "a role-bound invocation is short-circuited, not sent verbatim (B3 seam)" do
    it "reports role-bound dispatch as not yet available, no downstream turn" do
      with_dispatch(shipped: create_plan) do |dispatch|
        result, seen = run(dispatch, "@researcher/create-plan go")

        expect(seen).to be_nil
        expect(result.fetch(:response).text).to include("not yet available")
      end
    end
  end

  describe "a malformed invocation propagates (the dispatch boundary rescues it)" do
    it "raises Skill::Invocation::Malformed rather than passing through" do
      with_dispatch(shipped: create_plan) do |dispatch|
        expect { run(dispatch, "@foo/ broken") }
          .to raise_error(Lain::Skill::Invocation::Malformed)
      end
    end
  end

  describe "SkillDispatch preserves the repl monoid" do
    # A tag middleware over the repl phase's `:trace`, exactly the harness
    # repl_middleware_spec uses -- SkillDispatch is folded into the same pool so
    # the law is checked WITH it present (it is a pass-through for "hi").
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

    around do |example|
      with_dispatch(shipped: create_plan) do |dispatch|
        @pool = { a: tag(:a), b: tag(:b), s: dispatch }
        example.run
      end
    end

    def compose(sequence)
      sequence.map { |symbol| @pool.fetch(symbol) }.reduce(Lain::Middleware::Identity, :>>)
    end

    include_examples "a monoid",
                     operation: ->(a, b) { a >> b },
                     identity: Lain::Middleware::Identity,
                     generator: -> { compose(Array.new(rand(0..3)) { %i[a b s].sample }) },
                     equal: ->(a, b) { observe(a) == observe(b) }
  end
end
