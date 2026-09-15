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

# The role spawn a held-round critique reaches, recorded: the checkout each child
# was lent and the prompt it was handed. `seam` answers the child's context,
# which is where a critique reads the model it sizes against.
class SkillDispatchCritiqueSpawn
  Seam = Struct.new(:context_factory)

  def initialize = @calls = []

  attr_reader :calls

  def seam = Seam.new(-> { Lain::Context.new(model: "critic-model", max_tokens: 256) })

  def within(worker_env)
    lambda_spawn = self
    Class.new do
      define_method(:call) do |role, mode, prompt|
        lambda_spawn.calls << { cwd: worker_env.cwd, role:, mode:, prompt: }
        Lain::Tool::Result.ok("critic findings")
      end
    end.new
  end

  # The line-level role-bound seam, which a critique never reaches.
  def call(*) = raise("a held-round critique spawned through the role-bound seam")
end

# A checkout that is only a directory name, recording the revision it was cut at.
class SkillDispatchCheckouts
  def initialize = @held = []

  attr_reader :held

  def hold(revision)
    @held << revision
    yield Lain::WorkerEnv.new(cwd: "/checkout/#{revision}", env: {})
  end
end

# The chat's held review, as the two messages the dispatch sends it. A duck and
# not the real outbox: which round a chat holds is `/review`'s business, and
# the real one is driven in `spec/lain/seams/critique_over_held_review_spec.rb`.
SkillDispatchRound = Struct.new(:held_changeset) do
  def open? = !held_changeset.nil?
end

RSpec.describe Lain::Middleware::SkillDispatch do
  # A throwaway project tree, the renderer_spec pattern: a "shipped" skill dir
  # the catalog loads over, plus the Slots the renderer fills holes from. The
  # dispatch is a pure function of the frozen catalog + renderer built here, plus
  # the injected role-spawn seam (a fake by default; the real seam is exercised
  # in its own block below).
  def with_dispatch(shipped: {}, role_spawn: SkillDispatchFakeRoleSpawn.new, outbox: SkillDispatchRound.new(nil),
                    &block)
    Dir.mktmpdir do |root|
      shipped_dir = File.join(root, "shipped")
      shipped.each { |path, body| write(File.join(shipped_dir, path), body) }
      catalog = Lain::Skill::Catalog.load(root:, shipped_dir:)
      slots = Lain::Prompt::Slots.load(root:, skill_shipped_dir: shipped_dir)
      renderer = Lain::Skill::Renderer.new(catalog:, slots:)
      yield(described_class.new(catalog:, renderer:, role_spawn:, outbox:, window: served_window,
                                checkouts:, journal:, slots:), role_spawn)
    end
  end

  let(:checkouts) { SkillDispatchCheckouts.new }
  let(:journal) { [] }

  def served_window = Lain::CLI::Backend::WindowBook::Served.new(model: "critic-model", window_tokens: 32_768)

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

  describe "a role-bound invocation spawns through the RoleSpawn seam" do
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

  # The real seam, wired end-to-end against a Provider::Mock: proves the
  # out-of-band invariant -- the folded child answer renders, but the PARENT
  # session Timeline head does NOT move (the subagent's turns live in the shared
  # Store, never in the parent's rendered conversation).
  describe "the fold renders but never moves the parent head (real seam)" do
    def with_real_seam(&block)
      Dir.mktmpdir do |root|
        catalog, renderer = real_catalog_and_renderer(root)
        parent = two_turn_parent
        seam = real_seam(parent:, slots: Lain::Prompt::Slots.load(root:))
        yield(described_class.new(catalog:, renderer:, role_spawn: seam, outbox: SkillDispatchRound.new(nil),
                                  window: served_window, checkouts:, journal:,
                                  slots: Lain::Prompt::Slots.load(root:)), parent)
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
                                 context_factory: -> { child_context }, toolset: union, parent:, slots:,
                                 tool_middleware: ToolRegistry::UNGUARDED)
    end

    it "folds the child's final answer into env[:response] without moving the parent head" do
      with_real_seam do |dispatch, parent|
        head_before = parent.head_digest

        result, seen = run(dispatch, "@researcher/create-plan draft it")

        expect(seen).to be_nil # short-circuit: no parent model turn
        expect(result.fetch(:response).text).to eq("the plan")
        expect(parent.head_digest).to eq(head_before) # parent head unchanged
      end
    end
  end

  describe "/critique with a review round held" do
    def critique_skill = { "critique/skill.md" => "# critique\nReview what is in front of you.\n" }

    def reviewed_diff
      <<~DIFF
        diff --git a/app.rb b/app.rb
        index 1111111..2222222 100644
        --- a/app.rb
        +++ b/app.rb
        @@ -1,1 +1,1 @@
        -old line
        +reviewed line
      DIFF
    end

    def held_outbox
      source = DiffSource.over(instance_double(Lain::Review::Source::LocalBranch,
                                               diff: reviewed_diff.b, base_ref: "b" * 40, head_ref: "h" * 40,
                                               commits: [Lain::Review::Source::Commit.new(
                                                 sha: "h" * 40, subject: "the change", body: "",
                                                 numstat: [Lain::Review::Source::FileStat.new(path: "app.rb", added: 1,
                                                                                              deleted: 1)].freeze
                                               )].freeze))
      SkillDispatchRound.new(Lain::Review::Changeset.new(source:))
    end

    it "critiques the held changeset in a checkout of its head rather than expanding a turn" do
      spawn = SkillDispatchCritiqueSpawn.new
      with_dispatch(shipped: critique_skill, role_spawn: spawn, outbox: held_outbox) do |dispatch|
        result, seen = run(dispatch, "/critique")

        expect(seen).to be_nil
        expect(checkouts.held).to eq(["h" * 40])
        expect(spawn.calls.map { |call| [call[:role], call[:mode], call[:cwd]] })
          .to eq([[:diff_critic, :fresh, "/checkout/#{"h" * 40}"]])
        expect(result.fetch(:response).text).to include("chunk 1 of 1", "app.rb", "critic findings")
      end
    end

    it "hands the child the skill's instructions, the focus typed after it, and the held hunks" do
      spawn = SkillDispatchCritiqueSpawn.new
      with_dispatch(shipped: critique_skill, role_spawn: spawn, outbox: held_outbox) do |dispatch|
        run(dispatch, "/critique the error paths")

        expect(spawn.calls.first[:prompt])
          .to include("# critique\nReview what is in front of you.", "the error paths", "+reviewed line")
      end
    end

    it "journals the chunk to the journal it was wired with" do
      with_dispatch(shipped: critique_skill, role_spawn: SkillDispatchCritiqueSpawn.new,
                    outbox: held_outbox) do |dispatch|
        run(dispatch, "/critique")

        expect(journal.map { |record| record.to_journal["type"] }).to eq(["critique_chunk"])
      end
    end

    it "leaves every other skill in-line" do
      with_dispatch(shipped: create_plan.merge(critique_skill), outbox: held_outbox) do |dispatch|
        _result, seen = run(dispatch, "/create-plan go")

        expect(seen.fetch(:text)).to eq("# Create plan\nDo the planning.\n\n\ngo")
        expect(checkouts.held).to be_empty
      end
    end

    it "leaves a role-bound critique on the role-bound seam" do
      fake = SkillDispatchFakeRoleSpawn.new
      with_dispatch(shipped: critique_skill, role_spawn: fake, outbox: held_outbox) do |dispatch|
        run(dispatch, "@reviewer_code/critique")

        expect(fake.calls.map(&:first)).to eq(["reviewer_code"])
        expect(checkouts.held).to be_empty
      end
    end
  end

  describe "/critique with no review round held" do
    it "runs the critique skill in-line as before" do
      with_dispatch(shipped: { "critique/skill.md" => "# critique\nReview it.\n" }) do |dispatch|
        _result, seen = run(dispatch, "/critique some/path")

        expect(seen.fetch(:text)).to eq("# critique\nReview it.\n\n\nsome/path")
        expect(checkouts.held).to be_empty
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
end
