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
      yield(root)
    end
  end

  let(:role_spawn) { spy("role_spawn") }
  let(:status_feed) { instance_double(Lain::StatusFeed) }
  let(:policy_switch) { instance_double(Lain::Approval::PolicySwitch) }
  let(:model_switch) { instance_double(Lain::Context::ModelSwitch) }

  # `catalog:`/`slots:` are required (T15): the run loads ONE of each and hands
  # them over, so a surface that read its own would be a second read of the
  # same tree -- the drift this class's one-snapshot promise exists to deny.
  def build_surface(root, approvals: nil)
    described_class.new(agent: spy("agent"), replies: spy("replies"),
                        supervisor: Lain::Supervisor::Null, role_spawn:, approvals:, root:,
                        chronicle: Lain::CLI::Chronicle::Null.new, catalog: Lain::Skill::Catalog.load(root:),
                        slots: Lain::Prompt::Slots.load(root:),
                        status_feed:, policy_switch:, model_switch:)
  end

  it "refuses to construct without the run's catalog and slots, rather than reading its own" do
    with_project do |root|
      snapshotless = lambda do
        described_class.new(agent: spy("agent"), replies: spy("replies"), role_spawn:, root:,
                            supervisor: Lain::Supervisor::Null, chronicle: Lain::CLI::Chronicle::Null.new,
                            status_feed:, policy_switch:, model_switch:)
      end

      expect { snapshotless.call }.to raise_error(ArgumentError, /catalog|slots/)
    end
  end

  it "assembles the frozen nil-free Env from the wired collaborators, YoloApprovals for the empty queue" do
    with_project do |root|
      env = build_surface(root).env

      expect(env).to be_frozen
      expect(env.approvals).to be(Lain::CLI::Command::Env::YoloApprovals)
      expect(env.status).to be(status_feed)
      expect(env.fork_point).to be_a(Lain::CLI::ForkPoint)
    end
  end

  it "binds the shipped commands over that one Env, /help and /quit registered" do
    with_project do |root|
      surface = build_surface(root)

      # T9: /help answers a Renderable now -- the WORDS are what this asserts.
      listing = surface.commands.dispatch("/help") { raise "fallthrough must not run" }
      expect(listing.text).to include("/help", "/quit", "/rewind", "/greet")
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
      expect(surface.commands.dispatch("/help") { raise "fallthrough must not run" }.text).to include("/greet")
    end
  end
end
