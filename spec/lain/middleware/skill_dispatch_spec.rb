# frozen_string_literal: true

require "tmpdir"

# A fake role-spawn seam: it records the (role, context, prompt) tuple the
# dispatch hands it and returns a canned Tool::Result, so a role-bound line's
# ROUTING is asserted without a real subagent. `raises:` drives the unknown-role
# path -- the real seam raises Role::Catalog::Unknown BEFORE any spawn, and the
# dispatch lets that Lain::Error propagate exactly as Malformed.
class SkillDispatchFakeRoleSpawn
  attr_reader :calls

  def initialize(answer: "the child's final answer", raises: nil)
    @answer = answer
    @raises = raises
    @calls = []
  end

  def call(role, context, prompt)
    @calls << [role, context, prompt]
    raise @raises if @raises

    Lain::Tool::Result.ok(@answer)
  end
end

RSpec.describe Lain::Middleware::SkillDispatch do
  # A throwaway project tree, the renderer_spec pattern: a "shipped" skill dir
  # the catalog loads over, plus the Slots the renderer fills holes from. The
  # dispatch is a pure function of the frozen catalog + renderer built here, plus
  # the injected role-spawn seam (a fake by default; the real seam is exercised
  # in its own block below).
  def with_dispatch(shipped: {}, role_spawn: SkillDispatchFakeRoleSpawn.new, &block)
    Dir.mktmpdir do |root|
      shipped_dir = File.join(root, "shipped")
      shipped.each { |path, body| write(File.join(shipped_dir, path), body) }
      catalog = Lain::Skill::Catalog.load(root:, shipped_dir:)
      slots = Lain::Prompt::Slots.load(root:, skill_shipped_dir: shipped_dir)
      renderer = Lain::Skill::Renderer.new(catalog:, slots:)
      block.call(described_class.new(catalog:, renderer:, role_spawn:), role_spawn)
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

  describe "a role-bound invocation spawns through the RoleSpawn seam (B3)" do
    it "routes @role/skill to the seam with an :inherit context and the scaffold+args prompt, no downstream turn" do
      fake = SkillDispatchFakeRoleSpawn.new
      with_dispatch(shipped: create_plan, role_spawn: fake) do |dispatch|
        result, seen = run(dispatch, "@researcher/create-plan go build it")

        expect(seen).to be_nil # short-circuit -- no model turn spent on the parent
        expect(fake.calls).to eq([["researcher", :inherit,
                                   "# Create plan\nDo the planning.\n\n\ngo build it"]])
        expect(result.fetch(:response).text).to eq("the child's final answer")
      end
    end

    it "routes @role[/skill] to the seam with a :fresh context, otherwise identical" do
      fake = SkillDispatchFakeRoleSpawn.new
      with_dispatch(shipped: create_plan, role_spawn: fake) do |dispatch|
        run(dispatch, "@researcher[/create-plan] go")

        expect(fake.calls).to eq([["researcher", :fresh, "# Create plan\nDo the planning.\n\n\ngo"]])
      end
    end

    it "folds the seam's final result into env[:response] as a real Response" do
      fake = SkillDispatchFakeRoleSpawn.new(answer: "PLAN: step one, step two")
      with_dispatch(shipped: create_plan, role_spawn: fake) do |dispatch|
        result, _seen = run(dispatch, "@researcher/create-plan go")

        expect(result.fetch(:response)).to be_a(Lain::Response)
        expect(result.fetch(:response).text).to eq("PLAN: step one, step two")
      end
    end

    it "lets an unknown role's Role::Catalog::Unknown propagate, before any spawn, with no downstream turn" do
      fake = SkillDispatchFakeRoleSpawn.new(raises: Lain::Role::Catalog::Unknown.new("unknown role :nope"))
      with_dispatch(shipped: create_plan, role_spawn: fake) do |dispatch|
        expect { run(dispatch, "@nope/create-plan go") }
          .to raise_error(Lain::Role::Catalog::Unknown)
      end
    end
  end

  # The real seam, wired end-to-end against a Provider::Mock: proves the OM-2
  # out-of-band invariant -- the folded child answer renders, but the PARENT
  # session Timeline head does NOT move (the subagent's turns live in the shared
  # Store, never in the parent's rendered conversation).
  describe "OM-2: the fold renders but never moves the parent head (real seam)" do
    def with_real_seam(&block)
      Dir.mktmpdir do |root|
        catalog, renderer = real_catalog_and_renderer(root)
        parent = two_turn_parent
        seam = real_seam(parent:, slots: Lain::Prompt::Slots.load(root:))
        block.call(described_class.new(catalog:, renderer:, role_spawn: seam), parent)
      end
    end

    def real_catalog_and_renderer(root)
      shipped_dir = File.join(root, "shipped")
      write(File.join(shipped_dir, "create-plan", "skill.md"), "# Create plan\nDo the planning.\n")
      catalog = Lain::Skill::Catalog.load(root:, shipped_dir:)
      [catalog,
       Lain::Skill::Renderer.new(catalog:, slots: Lain::Prompt::Slots.load(root:, skill_shipped_dir: shipped_dir))]
    end

    def two_turn_parent
      Lain::Timeline.empty(store: Lain::Store.new)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                    .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
    end

    # The researcher role attenuates to read_file/list_files/web_fetch/web_search;
    # the union must hold every one of those or Toolset#only fails loudly.
    def real_seam(parent:, slots:)
      union = Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new,
                                 Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])
      child_context = Lain::Context.new(model: "child-model", max_tokens: 256)
      Lain::Skill::RoleSpawn.new(provider: Lain::Provider::Mock.new(responses: [text_response("the plan")]),
                                 context_factory: -> { child_context }, toolset: union, parent:, slots:)
    end

    it "folds the child's final answer into env[:response] without moving the parent head" do
      with_real_seam do |dispatch, parent|
        head_before = parent.head_digest

        result, seen = run(dispatch, "@researcher/create-plan draft it")

        expect(seen).to be_nil # short-circuit: no parent model turn
        expect(result.fetch(:response).text).to eq("the plan")
        expect(parent.head_digest).to eq(head_before) # OM-2: parent head unchanged
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
