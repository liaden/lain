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

  # The session's one library, which every caller now hands over: T40 took
  # `root:` off this module entirely, because it was only ever here to feed the
  # from-disk defaults -- and a from-disk default is the second read the whole
  # threading exists to remove.
  def library_for(root) = Lain::Skill::Library.load(root:)

  describe ".build" do
    it "returns a Middleware::Stack carrying a SkillDispatch" do
      with_project do |root|
        stack = described_class.build(library: library_for(root), role_spawn: ReplMiddlewareStubRoleSpawn.new)

        expect(stack).to be_a(Lain::Middleware::Stack)
        expect(stack.to_a).to include(an_instance_of(Lain::Middleware::SkillDispatch))
      end
    end

    it "expands an in-line invocation through the stack" do
      with_project do |root|
        stack = described_class.build(library: library_for(root), role_spawn: ReplMiddlewareStubRoleSpawn.new)

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
        stack = described_class.build(library: library_for(root), role_spawn: ReplMiddlewareStubRoleSpawn.new)

        ran = false
        result = stack.call({ text: "/nope", agent: :the_agent }) do |env|
          ran = true
          env.merge(response: "ran")
        end

        expect(ran).to be(false)
        expect(result.fetch(:response).text).to include("unknown skill", "nope")
      end
    end

    # T15 injected the catalog and the slots separately; T40 makes them one
    # library, so dispatch, /help, Backend#context and Tools::RunSkill read one
    # object rather than four reads of the same tree.
    it "dispatches and renders through the INJECTED library, reading no disk of its own" do
      with_project do |root|
        library = library_for(root)
        stack = described_class.build(library:, role_spawn: ReplMiddlewareStubRoleSpawn.new)
        dispatch = stack.to_a.first

        expect(dispatch.instance_variable_get(:@catalog)).to be(library.catalog)
        renderer = dispatch.instance_variable_get(:@renderer)
        expect(renderer.instance_variable_get(:@catalog)).to be(library.catalog)
        expect(renderer.instance_variable_get(:@slots)).to be(library.slots)
      end
    end

    # The keyword is required, not defaulted, for the reason Command::Surface's
    # is: a forgotten library must be a loud ArgumentError, never a quiet second
    # read of the tree far from the bug.
    it "refuses to build without one" do
      expect { described_class.build(role_spawn: ReplMiddlewareStubRoleSpawn.new) }
        .to raise_error(ArgumentError, /library/)
    end

    it "threads the role-spawn seam through so a role-bound line reaches it" do
      with_project do |root|
        fake = ReplMiddlewareStubRoleSpawn.new
        stack = described_class.build(library: library_for(root), role_spawn: fake)

        result = stack.call({ text: "@researcher/greet warmly", agent: :the_agent }) do |env|
          env.merge(response: "ran")
        end

        expect(fake.calls).to eq([["researcher", :inherit, "# Greet\nSay hello.\n\n\nwarmly"]])
        expect(result.fetch(:response).text).to eq("child said hi")
      end
    end
  end
end
