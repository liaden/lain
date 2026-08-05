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

  let(:role_spawn) { instance_spy(Lain::Skill::RoleSpawn) }
  let(:status_feed) { instance_double(Lain::StatusFeed) }
  let(:policy_switch) { instance_double(Lain::Approval::PolicySwitch) }
  let(:model_switch) { instance_double(Lain::Context::ModelSwitch) }
  let(:mode_switch) { instance_double(Lain::Mode::Switch) }

  # `library:` is required (T15's posture, T40's one keyword): the run loads ONE
  # library and hands it over, so a surface that read its own would be a second
  # read of the same tree -- the drift this class's one-snapshot promise exists
  # to deny.
  def build_surface(root, approvals: nil)
    described_class.new(agent: instance_spy(Lain::Agent), replies: instance_spy(Lain::CLI::HumanReplies),
                        supervisor: Lain::Supervisor::Null, role_spawn:, approvals:, root:,
                        chronicle: Lain::CLI::Chronicle::Null.new, library: Lain::Skill::Library.load(root:),
                        status_feed:, policy_switch:, model_switch:, mode_switch:)
  end

  it "refuses to construct without the run's library, rather than reading one of its own" do
    with_project do |root|
      libraryless = lambda do
        described_class.new(agent: instance_spy(Lain::Agent), role_spawn:, root:,
                            replies: instance_spy(Lain::CLI::HumanReplies),
                            supervisor: Lain::Supervisor::Null, chronicle: Lain::CLI::Chronicle::Null.new,
                            status_feed:, policy_switch:, model_switch:, mode_switch:)
      end

      expect { libraryless.call }.to raise_error(ArgumentError, /library/)
    end
  end

  # The pair travelled as two keywords until T40, and a caller could pass one
  # and forget the other. One keyword makes that impossible; these pin that the
  # OLD pair is no longer accepted, so no caller is quietly half-wired.
  it "takes the pair as one keyword, not two" do
    with_project do |root|
      paired = lambda do
        described_class.new(agent: instance_spy(Lain::Agent), role_spawn:, root:,
                            replies: instance_spy(Lain::CLI::HumanReplies),
                            supervisor: Lain::Supervisor::Null, chronicle: Lain::CLI::Chronicle::Null.new,
                            catalog: Lain::Skill::Catalog.load(root:), slots: Lain::Prompt::Slots.load(root:),
                            status_feed:, policy_switch:, model_switch:, mode_switch:)
      end

      expect { paired.call }.to raise_error(ArgumentError, /catalog|slots|library/)
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

  # The run's ONE mode switch reaches a command through the Env and nowhere
  # else: `identity`, not merely a switch that answers the same posture, because
  # `/mode` mutates the slot and a second instance would leave the Gate reading
  # a posture no command can move.
  it "hands the run's one mode switch through, so /mode writes the slot the gate reads" do
    with_project do |root|
      expect(build_surface(root).env.mode_switch).to be(mode_switch)
    end
  end

  # A forgotten mode_switch must be a loud ArgumentError at construction, for
  # the reason this class's own comment gives about its siblings: a defaulted
  # switch would fail OPEN -- a posture nothing can change, reported as working.
  it "refuses to construct without the run's mode switch, rather than defaulting one" do
    with_project do |root|
      switchless = lambda do
        described_class.new(agent: instance_spy(Lain::Agent), role_spawn:, root:,
                            replies: instance_spy(Lain::CLI::HumanReplies),
                            supervisor: Lain::Supervisor::Null, chronicle: Lain::CLI::Chronicle::Null.new,
                            library: Lain::Skill::Library.load(root:),
                            status_feed:, policy_switch:, model_switch:)
      end

      expect { switchless.call }.to raise_error(ArgumentError, /mode_switch/)
    end
  end

  # PINS EXISTING BEHAVIOUR -- this card adds no code for it. The Env is built
  # in #initialize and read through a bare attr_reader, so two reads are already
  # one object. It is asserted because the contract ("assembled ONCE per run")
  # is what makes every reader identity-stable across a session, and a later
  # card that made #env a builder would break /mode and /yolo silently.
  it "assembles the Env exactly once per run, so two reads are the same object" do
    with_project do |root|
      surface = build_surface(root)

      expect(surface.env).to be(surface.env)
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

  # THE FREE FOLLOW-UP THIS CHUNK KEPT PAYING FOR. `lain review` was written,
  # specced with 28 examples and mounted in NO exe for the whole chunk, because
  # nothing anywhere asserted the command SET -- only that individual commands
  # behaved. A repl command is one require and one line in #builtins away from
  # exactly the same fate: the file loads, its own spec is green, and no human
  # can type it. Pinned as a LITERAL rather than derived, so a command wired to
  # nothing is a red example and registering one is a deliberate edit here.
  it "registers the whole shipped command set, so a command wired to nothing is a red example" do
    with_project do |root|
      surface = build_surface(root)

      expect(surface.commands.registry.map(&:name)).to contain_exactly(
        "quit", "rewind", "pin", "unpin", "fork", "btw", "keep", "status", "sessions", "inbox",
        "ruby", "mode", "goal", "meta", "review", "help", "approve", "yolo", "model"
      )
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
