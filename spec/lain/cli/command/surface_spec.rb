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
  # The run's path boundary, the object {Lain::CLI::Wiring::BoardBuild} builds
  # once and the board's gate holds. It reaches this surface through
  # {Lain::CLI::Switchboard#surface_kwargs} on the live path, and `/survey`
  # walks a tree through THIS one -- so the listing and the gate read one table.
  let(:sensitivity) do
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: Dir.tmpdir, cwd: Dir.tmpdir))
  end
  let(:snapshots) { instance_double(Lain::Agent::SnapshotSlot) }
  # `/introspect` reads the run's own token ledger and occupancy off this, so
  # the spy answers both -- absence for the occupancy, which is what a chat
  # with no turn honestly has.
  let(:agent) { instance_spy(Lain::Agent, usage: Lain::Usage.zero, occupancy: nil) }
  # The run's window book, which `/critique` over a held round sizes its chunks
  # against. Required, so a surface cannot quietly size to a guessed window.
  let(:window) { Lain::CLI::Backend::WindowBook::Served.new(model: "critic-model", window_tokens: 32_768) }

  # `library:` is required, and arrives as ONE keyword: the run loads ONE
  # library and hands it over, so a surface that read its own would be a second
  # read of the same tree -- the drift this class's one-snapshot promise exists
  # to deny.
  def build_surface(root, approvals: nil, **epic)
    described_class.new(agent:, replies: instance_spy(Lain::CLI::HumanReplies),
                        supervisor: Lain::Supervisor::Null, role_spawn:, approvals:, root:,
                        chronicle: Lain::CLI::Chronicle::Null.new, library: Lain::Skill::Library.load(root:),
                        status_feed:, model_switch:, mode_switch:, ledger:, sensitivity:, snapshots:, window:, **epic)
  end

  it "refuses to construct without the run's library, rather than reading one of its own" do
    with_project do |root|
      libraryless = lambda do
        described_class.new(agent: instance_spy(Lain::Agent), role_spawn:, root:,
                            replies: instance_spy(Lain::CLI::HumanReplies),
                            supervisor: Lain::Supervisor::Null, chronicle: Lain::CLI::Chronicle::Null.new,
                            status_feed:, model_switch:, mode_switch:, ledger:, sensitivity:)
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
                            status_feed:, model_switch:, mode_switch:, ledger:, sensitivity:)
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
  # else: `identity` of the slot, not merely a switch that answers the same
  # mode, because `/mode` mutates the slot and a second instance would leave
  # the Gate reading a policy no command can move. A command reaches it through
  # the standing-goal driver's guard, since the `goal` layer is that driver's to
  # raise, so reads and writes are asserted to land on the one slot.
  context "with the board's mode switch" do
    let(:mode_switch) do
      instance_double(Lain::CLI::Switchboard::BoundSwitch, current: Lain::Mode.new(approval: :auto), switch: :switched)
    end

    it "hands the run's one mode switch through, so /mode writes the slot the gate reads" do
      with_project do |root|
        env_switch = build_surface(root).env.mode_switch

        expect([env_switch.current, env_switch.switch(Lain::Mode.new, surface: "tty")])
          .to eq([Lain::Mode.new(approval: :auto), :switched])
        expect(mode_switch).to have_received(:switch).with(Lain::Mode.new, surface: "tty")
      end
    end

    it "guards the goal layer: /mode +goal with no standing goal reaches no slot" do
      with_project do |root|
        raising = Lain::Mode.new(approval: :auto, layers: [:goal])

        expect { build_surface(root).env.mode_switch.switch(raising, surface: "tty") }
          .to raise_error(Lain::Error, %r{/goal <objective>})
        expect(mode_switch).not_to have_received(:switch)
      end
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
                            status_feed:, model_switch:, ledger:, sensitivity:)
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

  # /help's listing is read off the LIVE registry rather than from anything
  # keyed to a file, so a command's usage line is what breaks first if moving
  # its class between files ever loses a `register` call.
  it "still shows a command's usage line through /help, wherever its class lives" do
    with_project do |root|
      surface = build_surface(root)

      listing = surface.commands.dispatch("/help") { raise "fallthrough must not run" }
      expect(listing.text).to include(Lain::CLI::Command::Model.new.usage)
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
        "implement-epic", "qa", "stop", "help", "approve", "model"
      )
    end
  end

  # The epic driver is the one reader a chat outside an epic still holds: the
  # refusing Null, so `/implement-epic` is typeable everywhere and refuses by
  # name where there is nothing to drive, rather than being absent in some
  # chats and present in others.
  describe "the epic driver" do
    it "defaults to the refusing Null, so a chat in no epic still registers the command" do
      with_project do |root|
        surface = build_surface(root)

        expect(surface.env.epic_driver).to be(Lain::CLI::EpicDriver::Factory::Unmounted)
        expect(surface.commands.dispatch("/help") { raise "fallthrough must not run" }.text)
          .to include("/implement-epic")
      end
    end

    # Built from the mount the SEAT resolved and handed in, never from a second
    # {EpicMount.for}: two mounts over one journal would be two
    # {Epic::Review}s, and the second one stops guarding in silence.
    it "builds a driver for the epic the seat mounted, from that one mount" do
      with_project do |root|
        seams = Lain::CLI::EpicDriver::Seams.new(
          mount: instance_double(Lain::CLI::EpicMount, slug: "alpha"), paths: Lain::Paths.new,
          journal: Lain::Channel::Null.instance, conductor: instance_double(Lain::CLI::Conductor),
          toolset_build: instance_double(Lain::CLI::Wiring::ToolsetBuild), asker: nil
        )

        expect(build_surface(root, epic: seams).env.epic_driver).to be_mounted.and(have_attributes(slug: "alpha"))
      end
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
                            status_feed:, model_switch:, mode_switch:, ledger:, sensitivity:)
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

      expect(rendered.text).to include("model claude-opus-4-8", "occupancy no turn measured on this chain in this run",
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

  # The same failure the outbox example above is about, one boundary over, and
  # this one narrows a security boundary rather than a report: `/survey` built
  # its own classifier from its own re-read of `.lain/config.rb`, so a config
  # rewritten mid-session left the listing walking one table while the gate
  # beside it held another. IDENTITY, because two classifiers agreeing at the
  # moment a spec looks is exactly what the defect looked like.
  it "hands /survey the run's own path boundary, so the listing and the gate read one table" do
    with_project do |root|
      surveying = build_surface(root).commands.registry.find { |command| command.name == "survey" }

      expect(surveying.sensitivity).to be(sensitivity)
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

  it "refuses to construct without the run's window book, rather than sizing a critique to a guess" do
    with_project do |root|
      windowless = lambda do
        described_class.new(agent:, replies: instance_spy(Lain::CLI::HumanReplies),
                            supervisor: Lain::Supervisor::Null, role_spawn:, root:,
                            chronicle: Lain::CLI::Chronicle::Null.new, library: Lain::Skill::Library.load(root:),
                            status_feed:, model_switch:, mode_switch:, ledger:, sensitivity:, snapshots:)
      end

      expect { windowless.call }.to raise_error(ArgumentError, /window/)
    end
  end

  # IDENTITY again: a `/critique` that read an outbox of its own would find no
  # round open while `/review` holds one, and fall through to the skill over the
  # working tree -- the exact read the held-round critique exists to replace.
  it "hands the skill middleware the ONE outbox /review holds a round in, and the run's window" do
    with_project do |root|
      surface = build_surface(root)
      dispatch = surface.middleware.to_a.last

      expect(dispatch.instance_variable_get(:@outbox)).to be(surface.outbox)
      expect(dispatch.instance_variable_get(:@critique)).to include(window:, spawn: role_spawn)
    end
  end

  # Where a critique's children read: checkouts of THIS project's repository,
  # under the same per-project container every other lain checkout lives in,
  # so `lain worktrees gc` finds one a killed process left behind.
  it "cuts a critique's checkouts from the project root, under lain's worktree container" do
    with_project do |root|
      checkouts = build_surface(root).middleware.to_a.last.instance_variable_get(:@critique).fetch(:checkouts)

      expect(checkouts.instance_variable_get(:@repo_root)).to eq(root)
      expect(checkouts.instance_variable_get(:@root))
        .to eq(Lain::CLI::IsolationBackend.worktree_root(root, paths: Lain::Paths.new))
    end
  end
end
