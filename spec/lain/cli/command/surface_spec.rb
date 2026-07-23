# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::CLI::Command::Surface do
  # A project tree with one user skill, so the one catalog snapshot is
  # observable from BOTH halves of the surface: /help's listing and the skill
  # middleware's dispatch.
  def with_project(&block)
    Dir.mktmpdir do |root|
      path = File.join(root, ".lain", "skills", "greet", "skill.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# Greet\nSay hello.\n")
      block.call(root)
    end
  end

  let(:role_spawn) { spy("role_spawn") }

  def build_surface(root, approvals: nil)
    described_class.new(agent: spy("agent"), replies: spy("replies"),
                        supervisor: Lain::Supervisor::Null, role_spawn:, approvals:, root:)
  end

  it "assembles the frozen nil-free Env from the wired collaborators and the Null placeholders" do
    with_project do |root|
      env = build_surface(root).env

      expect(env).to be_frozen
      expect(env.approvals).to be(Lain::CLI::Command::Env::NullApprovals)
      expect(env.status).to be(Lain::CLI::Command::Env::NullStatus)
      expect(env.fork_point).to be(Lain::CLI::Command::Env::NullForkPoint)
    end
  end

  it "binds the shipped commands over that one Env, /help and /quit registered" do
    with_project do |root|
      surface = build_surface(root)

      listing = surface.commands.dispatch("/help") { raise "fallthrough must not run" }
      expect(listing).to include("/help", "/quit", "/greet")
      expect(surface.commands.dispatch("/quit") { raise "fallthrough must not run" }).to eq(:quit)
    end
  end

  it "serves commands and middleware from ONE memoized assembly -- identity, not shared-catalog coincidence" do
    with_project do |root|
      surface = build_surface(root)

      # Two commands calls must yield the SAME bound registry -- disjoint
      # registries would let /help and dispatch drift apart silently.
      expect(surface.commands).to be(surface.commands)
      expect(surface.commands.registry).to be(surface.commands.registry)
      expect(surface.middleware).to be(surface.middleware)

      seen = nil
      surface.middleware.call({ text: "/greet warmly", agent: :the_agent }) do |env|
        seen = env
        env.merge(response: "ran")
      end

      expect(seen.fetch(:text)).to start_with("# Greet")
      expect(surface.commands.dispatch("/help") { raise "fallthrough must not run" }).to include("/greet")
    end
  end
end
