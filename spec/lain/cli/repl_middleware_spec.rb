# frozen_string_literal: true

require "tmpdir"

# A stand-in role-spawn seam: the exe hands `.build` a real Skill::RoleSpawn
# wired from the session's provider/toolset/parent; a spec injects this fake so
# `.build` is exercised without the exe. It records the tuple and answers with a
# canned Tool::Result.
class ReplMiddlewareStubRoleSpawn
  attr_reader :calls

  def initialize
    @calls = []
  end

  def call(role, context, prompt)
    @calls << [role, context, prompt]
    Lain::Tool::Result.ok("child said hi")
  end
end

RSpec.describe Lain::CLI::ReplMiddleware do
  # A project tree with one user skill under `.lain/skills`, the convention
  # Catalog.load overlays onto the (empty) shipped tree. No front-matter, so the
  # scaffold needs no hole-default fixtures to render.
  def with_project(&block)
    Dir.mktmpdir do |root|
      write(File.join(root, ".lain", "skills", "greet", "skill.md"), "# Greet\nSay hello.\n")
      yield(root)
    end
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  describe ".renderer" do
    it "composes the injected catalog and slots, loading neither of its own" do
      with_project do |root|
        catalog = Lain::Skill::Catalog.load(root:)
        slots = Lain::Prompt::Slots.load(root:)
        renderer = described_class.renderer(root:, catalog:, slots:)

        expect(renderer.instance_variable_get(:@catalog)).to be(catalog)
        expect(renderer.instance_variable_get(:@slots)).to be(slots)
      end
    end
  end

  describe ".build" do
    it "returns a Middleware::Stack carrying a SkillDispatch" do
      with_project do |root|
        stack = described_class.build(root:, role_spawn: ReplMiddlewareStubRoleSpawn.new)

        expect(stack).to be_a(Lain::Middleware::Stack)
        expect(stack.to_a).to include(an_instance_of(Lain::Middleware::SkillDispatch))
      end
    end

    it "loads the catalog once so an in-line invocation expands through the stack" do
      with_project do |root|
        stack = described_class.build(root:, role_spawn: ReplMiddlewareStubRoleSpawn.new)

        seen = nil
        stack.call({ text: "/greet warmly", agent: :the_agent }) do |env|
          seen = env
          env.merge(response: "ran")
        end

        expect(seen.fetch(:text)).to eq("# Greet\nSay hello.\n\n\nwarmly")
      end
    end

    it "reports an unknown skill without spending a downstream turn" do
      with_project do |root|
        stack = described_class.build(root:, role_spawn: ReplMiddlewareStubRoleSpawn.new)

        ran = false
        result = stack.call({ text: "/nope", agent: :the_agent }) do |env|
          ran = true
          env.merge(response: "ran")
        end

        expect(ran).to be(false)
        expect(result.fetch(:response).text).to include("unknown skill", "nope")
      end
    end

    it "dispatches over an injected catalog -- the same snapshot Wiring hands /help (T9)" do
      with_project do |root|
        catalog = Lain::Skill::Catalog.load(root:)
        stack = described_class.build(root:, catalog:, role_spawn: ReplMiddlewareStubRoleSpawn.new)

        seen = nil
        stack.call({ text: "/greet warmly", agent: :the_agent }) do |env|
          seen = env
          env.merge(response: "ran")
        end

        expect(seen.fetch(:text)).to start_with("# Greet")
      end
    end

    # T15: `slots:` is the `catalog:` precedent, one level down. Without it
    # `.build` loaded a SECOND Prompt::Slots off disk (and `.renderer`, called
    # from ToolsetBuild, a third), so the repl stack, Backend#context and
    # Tools::RunSkill each framed against their own snapshot of the same tree.
    it "renders through an injected slots -- the session's one snapshot, not a second disk read" do
      with_project do |root|
        slots = Lain::Prompt::Slots.load(root:)
        stack = described_class.build(root:, slots:, role_spawn: ReplMiddlewareStubRoleSpawn.new)

        dispatch = stack.to_a.first
        renderer = dispatch.instance_variable_get(:@renderer)

        expect(renderer.instance_variable_get(:@slots)).to be(slots)
      end
    end

    it "threads the role-spawn seam through so a role-bound line reaches it" do
      with_project do |root|
        fake = ReplMiddlewareStubRoleSpawn.new
        stack = described_class.build(root:, role_spawn: fake)

        result = stack.call({ text: "@researcher/greet warmly", agent: :the_agent }) do |env|
          env.merge(response: "ran")
        end

        expect(fake.calls).to eq([["researcher", :inherit, "# Greet\nSay hello.\n\n\nwarmly"]])
        expect(result.fetch(:response).text).to eq("child said hi")
      end
    end
  end
end
