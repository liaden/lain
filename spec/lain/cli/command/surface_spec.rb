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
  let(:model_switch) { instance_double(Lain::Context::ModelSwitch) }
  let(:mode_switch) { instance_double(Lain::Mode::Switch) }
  let(:ledger) { Lain::Sensitivity::Ledger.new }
  let(:snapshots) { instance_double(Lain::Agent::SnapshotSlot) }
  # `/introspect` reads the run's own token ledger and occupancy off this, so
  # the spy answers both -- absence for the occupancy, which is what a chat
  # with no turn honestly has.
  let(:agent) { instance_spy(Lain::Agent, usage: Lain::Usage.zero, occupancy: nil) }

  # `library:` is required, and arrives as ONE keyword: the run loads ONE
  # library and hands it over, so a surface that read its own would be a second
  # read of the same tree -- the drift this class's one-snapshot promise exists
  # to deny.
  def build_surface(root, approvals: nil)
    described_class.new(agent:, replies: instance_spy(Lain::CLI::HumanReplies),
                        supervisor: Lain::Supervisor::Null, role_spawn:, approvals:, root:,
                        chronicle: Lain::CLI::Chronicle::Null.new, library: Lain::Skill::Library.load(root:),
                        status_feed:, model_switch:, mode_switch:, ledger:, snapshots:)
  end

  it "refuses to construct without the run's library, rather than reading one of its own" do
    with_project do |root|
      libraryless = lambda do
        described_class.new(agent: instance_spy(Lain::Agent), role_spawn:, root:,
                            replies: instance_spy(Lain::CLI::HumanReplies),
                            supervisor: Lain::Supervisor::Null, chronicle: Lain::CLI::Chronicle::Null.new,
                            status_feed:, model_switch:, mode_switch:, ledger:)
      end

      expect { libraryless.call }.to raise_error(ArgumentError, /library/)
    end
  end

  # The pair travelled as two keywords once, and a caller could pass one
  # and forget the other. One keyword makes that impossible; these pin that the
  # OLD pair is no longer accepted, so no caller is quietly half-wired.
  it "takes the pair as one keyword, not two" do
    with_project do |root|
      paired = lambda do
        described_class.new(agent: instance_spy(Lain::Agent), role_spawn:, root:,
                            replies: instance_spy(Lain::CLI::HumanReplies),
                            supervisor: Lain::Supervisor::Null, chronicle: Lain::CLI::Chronicle::Null.new,
                            catalog: Lain::Skill::Catalog.load(root:), slots: Lain::Prompt::Slots.load(root:),
                            status_feed:, model_switch:, mode_switch:, ledger:)
      end

      expect { paired.call }.to raise_error(ArgumentError, /catalog|slots|library/)
    end
  end

  it "assembles the frozen nil-free Env from the wired collaborators, NoApprovals for the empty queue" do
    with_project do |root|
      env = build_surface(root).env

      expect(env).to be_frozen
      expect(env.approvals).to be(Lain::CLI::Command::Env::NoApprovals)
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
                            status_feed:, model_switch:, ledger:)
      end

      expect { switchless.call }.to raise_error(ArgumentError, /mode_switch/)
    end
  end

  # PINS EXISTING BEHAVIOUR -- this card adds no code for it. The Env is built
  # in #initialize and read through a bare attr_reader, so two reads are already
  # one object. It is asserted because the contract ("assembled ONCE per run")
  # is what makes every reader identity-stable across a session, and a later
  # card that made #env a builder would break /mode and /approve silently.
  it "assembles the Env exactly once per run, so two reads are the same object" do
    with_project do |root|
      surface = build_surface(root)

      expect(surface.env).to be(surface.env)
    end
  end

  it "binds the shipped commands over that one Env, /help and /quit registered" do
    with_project do |root|
      surface = build_surface(root)

      # /help answers a Renderable now -- the WORDS are what this asserts.
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
        "quit", "rewind", "undo", "pin", "unpin", "fork", "btw", "keep", "status", "sessions", "inbox",
        "ruby", "mode", "goal", "meta", "introspect", "review", "review-submit", "survey",
        "help", "approve", "model"
      )
    end
  end

  # `/undo` reads the run's ONE snapshot slot -- the one the Agent's deliveries
  # write through -- so a defaulted slot would answer "nothing to undo" for a
  # session that has changed files.
  it "refuses to construct without the run's snapshot slot, rather than defaulting one" do
    with_project do |root|
      slotless = lambda do
        described_class.new(agent: instance_spy(Lain::Agent), role_spawn:, root:,
                            replies: instance_spy(Lain::CLI::HumanReplies),
                            supervisor: Lain::Supervisor::Null, chronicle: Lain::CLI::Chronicle::Null.new,
                            library: Lain::Skill::Library.load(root:),
                            status_feed:, model_switch:, mode_switch:, ledger:)
      end

      expect { slotless.call }.to raise_error(ArgumentError, /snapshots/)
    end
  end

  it "hands the run's one snapshot slot through, and lists /undo in /help" do
    with_project do |root|
      surface = build_surface(root)

      expect(surface.env.snapshots).to be(snapshots)
      expect(surface.commands.dispatch("/help") { raise "fallthrough must not run" }.text).to include("/undo")
    end
  end

  # The failure the LITERAL set above exists to catch, driven end to end: a
  # command file can load, pass its own spec, and still be untypeable because
  # nothing constructed it here. This dispatches the real thing through
  # the registry this class assembles -- and asserts /help lists it, since a
  # capability a human cannot discover is one step from not shipping at all.
  #
  # It also pins the run's ONE outbox reaching `/introspect`: the review it
  # reports must be the round `/review` and `/survey` opened, not a second
  # holder's idea of one -- the same identity claim the example below makes for
  # `/review-submit`, from the reporting side.
  it "dispatches /introspect over the run's own collaborators, and lists it in /help" do
    with_project do |root|
      surface = build_surface(root)
      allow(model_switch).to receive(:current).and_return("claude-opus-4-8")
      round = instance_double(Lain::Review::Session, source: "github_pr",
                                                     annotations: [instance_double(Lain::Review::AnnotationPlaced)])
      surface.outbox.hold(session: round, number: 7, label: "pull request 7")

      rendered = surface.commands.dispatch("/introspect") { raise "fallthrough must not run" }

      expect(rendered.text).to include("model claude-opus-4-8", "occupancy no turn yet in this run",
                                       "review open over pull request 7 (github_pr)", "annotations 1")
      expect(surface.commands.dispatch("/help") { raise "fallthrough must not run" }.text)
        .to include("/introspect")
    end
  end

  # `/yolo` is gone (round 10): the identical PolicySwitch flip it wrapped is
  # already reachable through `/mode auto` and `/mode accept_edits`, so the
  # command was a redundant alias rather than a capability of its own. A typed
  # `/yolo on` must not be silently swallowed -- with no command claiming the
  # name, dispatch falls through to the skill middleware, which reports it the
  # same loud way it reports any other unrecognised word.
  it "registers no command named yolo, and a typed /yolo falls through to an unknown-skill report" do
    with_project do |root|
      surface = build_surface(root)

      expect(surface.commands.registry.map(&:name)).not_to include("yolo")

      env = surface.commands.dispatch("/yolo on") do
        surface.middleware.call({ text: "/yolo on", agent: :the_agent }) { |e| e }
      end

      expect(env.fetch(:response).text).to include("unknown skill", "yolo")
    end
  end

  # The same failure one layer in. `/review` and `/review-submit` share
  # ONE outbox: the first puts a round in and the second takes it out, so two
  # outboxes would be a review that is open in one command and absent from the
  # other -- every object present, nothing to see, and the human told there is
  # no review open while they are looking at one.
  #
  # Driven through the REGISTRY rather than by comparing readers, so what is
  # asserted is the wiring a typed line actually goes through. A branch round is
  # what the example holds, because its refusal is reached before any executor
  # is built and therefore spawns nothing.
  it "shares ONE outbox between /review and /review-submit, so a held round is the one that posts" do
    with_project do |root|
      surface = build_surface(root)
      surface.outbox.hold(session: :the_round, number: nil, label: "branch feature/widget")

      expect { surface.commands.dispatch("/review-submit") { raise "fallthrough must not run" } }
        .to raise_error(Lain::Error, %r{branch feature/widget})
      expect(surface.outbox).to be(surface.outbox)
    end
  end

  it "refuses /review-submit with nothing open, so the verb is reachable before any review exists" do
    with_project do |root|
      surface = build_surface(root)

      expect { surface.commands.dispatch("/review-submit") { raise "fallthrough must not run" } }
        .to raise_error(Lain::Error, /no changeset review is open/)
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
