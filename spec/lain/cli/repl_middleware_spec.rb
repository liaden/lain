# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::CLI::ReplMiddleware do
  # A project tree with one user skill under `.lain/skills`, the convention
  # Catalog.load overlays onto the (empty) shipped tree. No front-matter, so the
  # scaffold needs no hole-default fixtures to render.
  def with_project(&block)
    Dir.mktmpdir do |root|
      write(File.join(root, ".lain", "skills", "greet", "skill.md"), "# Greet\nSay hello.\n")
      block.call(root)
    end
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  describe ".build" do
    it "returns a Middleware::Stack carrying a SkillDispatch" do
      with_project do |root|
        stack = described_class.build(root:)

        expect(stack).to be_a(Lain::Middleware::Stack)
        expect(stack.to_a).to include(an_instance_of(Lain::Middleware::SkillDispatch))
      end
    end

    it "loads the catalog once so an in-line invocation expands through the stack" do
      with_project do |root|
        stack = described_class.build(root:)

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
        stack = described_class.build(root:)

        ran = false
        result = stack.call({ text: "/nope", agent: :the_agent }) do |env|
          ran = true
          env.merge(response: "ran")
        end

        expect(ran).to be(false)
        expect(result.fetch(:response).text).to include("unknown skill", "nope")
      end
    end
  end
end
