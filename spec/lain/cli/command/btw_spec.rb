# frozen_string_literal: true

require "shellwords"
require "tmpdir"

# /btw (ephemeral side-question in a tmux popup) and /keep (promote the
# ephemeral session from inside). Keep's quiescence rule is pinned here too:
# RelocatableSpool#relocate is unsynchronized with the ResponseWal monitor, so
# promote! runs only from the Repl's quiescent point -- command dispatch is
# between the MAIN agent's asks by construction (Repl#converse dispatches
# synchronously), and the one cross-ask exception, an adopted fleet actor
# possibly mid-round-trip, is refused conservatively.
RSpec.describe Lain::CLI::Command::Btw do
  let(:head) { "blake3:abc123def456" }
  let(:head_turn) { instance_double(Lain::Event, role: "user", content: [{ "type" => "text", "text" => "hi" }]) }
  let(:timeline) { instance_double(Lain::Timeline, head_digest: head, head: head_turn) }
  # Dispatching defaults to false -- the mid-tool describe block below flips
  # it on to exercise the shared dispatch-lock door.
  let(:agent) { instance_double(Lain::Agent, timeline:, dispatching?: false) }
  let(:journal_path) { "/state/lain/sessions/p/20260723T120000Z-1234.ndjson" }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, journal_path:, catch_up: nil)
  end
  let(:tmux_surface) { instance_double(Lain::CLI::TmuxSurface) }
  let(:command) { described_class.new }
  let(:env) { env_with(chronicle:, agent:) }

  def placement(kind: :popup, degraded: false, reason: nil)
    Lain::CLI::TmuxSurface::Placement.new(kind:, target: "btw", degraded:, reason:)
  end

  def env_with(chronicle:, agent:, supervisor: Lain::Supervisor::Null)
    build_command_env(chronicle:, agent:, supervisor:, tmux_surface:)
  end

  describe "the ephemeral popup" do
    it "runs the child through Up's pane recipe (never a bare `lain chat`), rooted at this project's cwd" do
      selector = "#{File.basename(journal_path)}@#{head}"
      expect(tmux_surface).to receive(:popup) do |command:, cwd:, **|
        expect(command).to eq(Lain::CLI::PaneCommand.call("chat", "--btw", "--fork", selector,
                                                          "--prompt", "why is the build red?"))
        expect(cwd).to eq(Dir.pwd)
        placement
      end

      text = command.call("why is the build red?", env)

      expect(text).to include("popup")
    end

    it "durably journals the head BEFORE the popup opens -- the child forks a recorded turn" do
      expect(chronicle).to receive(:catch_up).with(timeline).ordered
      expect(tmux_surface).to receive(:popup).ordered.and_return(placement)

      command.call("why?", env)
    end

    it "shell-escapes the question -- the popup command goes to tmux's own $SHELL -c" do
      question = %(why `rm -rf` "here" $HOME; echo?)
      expect(tmux_surface).to receive(:popup) do |command:, **|
        expect(command.shellsplit).to include("--prompt", question)
        placement
      end

      command.call(question, env)
    end
  end

  describe "the control-mode degrade" do
    it "reports the window and WHY when the popup degraded under tmux -CC" do
      allow(tmux_surface).to receive(:popup)
        .and_return(placement(kind: :window, degraded: true, reason: "control_mode"))

      text = command.call("why?", env)

      expect(text).to include("window")
      expect(text).to include("control mode")
    end

    it "names the old-tmux reason the same way" do
      allow(tmux_surface).to receive(:popup)
        .and_return(placement(kind: :window, degraded: true, reason: "old_tmux"))

      expect(command.call("why?", env)).to include("display-popup")
    end
  end

  describe "refusals" do
    it "refuses an empty question with its usage line" do
      expect { command.call("   ", env) }
        .to raise_error(Lain::Error, /usage.*btw/i)
    end

    it "refuses with no committed turn -- there is no head to fork" do
      bare = instance_double(Lain::Agent, timeline: instance_double(Lain::Timeline, head_digest: nil))

      expect { command.call("why?", env_with(chronicle:, agent: bare)) }
        .to raise_error(Lain::Error, /no turn|nothing to fork/i)
    end

    it "refuses under --no-journal -- the Null chronicle has no record to fork" do
      expect { command.call("why?", env_with(chronicle: Lain::CLI::Chronicle::Null.new, agent:)) }
        .to raise_error(Lain::Error, /no session record/i)
    end

    # Probed (probe_nested_popup.sh): display-popup from INSIDE a popup does
    # not nest -- tmux modifies the existing popup instead, with the running
    # child's fate undefined. And even were the surface willing, an ephemeral
    # forking an ephemeral builds a lineage whose parent record is doomed to
    # reap. Refuse with the way out.
    it "refuses a nested /btw from inside an ephemeral session -- /keep first" do
      ephemeral = instance_double(Lain::CLI::Chronicle,
                                  journal_path: "/state/lain/sessions/p/20260723T120000Z-9.btw.ndjson")

      expect { command.call("why?", env_with(chronicle: ephemeral, agent:)) }
        .to raise_error(Lain::Error, %r{/keep this side-question first})
    end
  end

  # The same dispatch-lock door `/fork` gates on: `/btw` composes a fork of
  # THIS head, so a call still being made under it is the same shape, refused
  # in the same words.
  describe "a mid-tool head" do
    let(:head_turn) do
      instance_double(Lain::Event, role: "assistant",
                                   content: [{ "type" => "tool_use", "id" => "toolu_01", "name" => "echo",
                                               "input" => { "text" => "hi" } }])
    end

    context "with the agent dispatching -- the call may still be in flight" do
      let(:agent) { instance_double(Lain::Agent, timeline:, dispatching?: true) }

      it "refuses with the MID_TOOL hedge, before the popup opens" do
        expect(tmux_surface).not_to receive(:popup)

        expect { command.call("a side question", env) }
          .to raise_error(Lain::Error, /awaiting tool results/)
      end

      it "still journals the head durably -- the refusal reads the now-durable record" do
        expect(chronicle).to receive(:catch_up).with(timeline)

        expect { command.call("a side question", env) }.to raise_error(Lain::Error)
      end
    end

    context "with the agent not dispatching -- the tear is stranded, as on disk" do
      it "opens the popup normally" do
        allow(tmux_surface).to receive(:popup).and_return(placement)

        expect { command.call("a side question", env) }.not_to raise_error
      end
    end
  end

  describe "outside a usable tmux" do
    it "prints the exact chat command instead of failing" do
      allow(tmux_surface).to receive(:popup)
        .and_raise(Lain::CLI::TmuxSurface::TmuxUnavailable, "tmux not found on PATH")

      text = command.call("why?", env)

      expect(text).to include("lain chat --btw --fork")
      expect(text).to include("tmux not found on PATH")
    end
  end

  it "returns rendered text and never prints" do
    allow(tmux_surface).to receive(:popup).and_return(placement)

    text = nil
    expect { text = command.call("why?", env) }.not_to output.to_stdout
    expect(text).to be_a(String)
  end
end

RSpec.describe Lain::CLI::Command::Keep do
  let(:marked_path) { "/state/lain/sessions/p/20260723T120000Z-1234.btw.ndjson" }
  let(:promoted_path) { "/state/lain/sessions/p/20260723T120000Z-1234.ndjson" }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, journal_path: marked_path, promote!: promoted_path)
  end
  let(:command) { described_class.new }

  def registration(role, state)
    instance_double(Lain::Supervisor::Registration, role:, state:)
  end

  def env_with(chronicle:, supervisor: Lain::Supervisor::Null)
    build_command_env(chronicle:, supervisor:)
  end

  describe "promotion from the Repl's quiescent point" do
    # Command dispatch happens between the main agent's asks by construction:
    # Repl#converse runs `dispatch` synchronously and an ask completes inside
    # the dispatch that started it (Repl#respond's Sync), so /keep can never
    # overlap a MAIN-agent round trip. With the fleet quiet too, promote! is
    # safe to run right here.
    it "promotes the ephemeral record and reports the durable name" do
      allow(chronicle).to receive(:promote!).and_return(promoted_path)

      text = command.call("", env_with(chronicle:))

      expect(chronicle).to have_received(:promote!)
      expect(text).to include(File.basename(promoted_path))
      expect(text).to include("lain sessions")
    end

    it "refuses while a fleet actor is running, naming the unblocking action -- a parked actor reads " \
       ":running forever, so 'wait' alone could never unblock it" do
      env = env_with(chronicle:, supervisor: [registration("researcher", :running)])

      expect(chronicle).not_to receive(:promote!)
      expect { command.call("", env) }
        .to raise_error(Lain::Error, /wait for the turn to settle.*stop the actors/m)
    end

    it "does not let a dead registration block promotion -- stopped and failed actors are quiescent" do
      env = env_with(chronicle:,
                     supervisor: [registration("researcher", :stopped), registration("clerk", :failed)])
      allow(chronicle).to receive(:promote!).and_return(promoted_path)

      expect(command.call("", env)).to include(File.basename(promoted_path))
      expect(chronicle).to have_received(:promote!)
    end
  end

  describe "refusals" do
    it "refuses a session that is not ephemeral -- nothing wears the mark" do
      durable = instance_double(Lain::CLI::Chronicle, journal_path: promoted_path)

      expect { command.call("", env_with(chronicle: durable)) }
        .to raise_error(Lain::Error, /not ephemeral/i)
    end

    it "refuses under --no-journal -- there is no record to promote" do
      expect { command.call("", env_with(chronicle: Lain::CLI::Chronicle::Null.new)) }
        .to raise_error(Lain::Error, /no session record/i)
    end
  end
end

RSpec.describe "the /btw and /keep registration" do
  it "claims both names in the shipped surface, ahead of the skill fallthrough" do
    Dir.mktmpdir do |root|
      surface = Lain::CLI::Command::Surface.new(
        agent: instance_spy(Lain::Agent), replies: instance_spy(Lain::CLI::HumanReplies), supervisor: Lain::Supervisor::Null,
        role_spawn: instance_spy(Lain::Skill::RoleSpawn), root:, chronicle: Lain::CLI::Chronicle::Null.new,
        status_feed: instance_double(Lain::StatusFeed),
        model_switch: instance_double(Lain::Context::ModelSwitch),
        mode_switch: instance_double(Lain::Mode::Switch),
        library: Lain::Skill::Library.load(root:), ledger: Lain::Sensitivity::Ledger.new,
        sensitivity: Lain::Sensitivity::Policy::Null.instance,
        snapshots: instance_double(Lain::Agent::SnapshotSlot),
        window: Lain::CLI::Backend::WindowBook::Served.new(model: "m", window_tokens: 32_768)
      )

      # A Null chronicle refuses loudly (no journal_path) -- but the REFUSAL
      # proves the command (not the skill middleware) claimed the line.
      expect { surface.commands.dispatch("/btw why?") { raise "fallthrough must not run" } }
        .to raise_error(Lain::Error, /no session record/i)
      expect { surface.commands.dispatch("/keep") { raise "fallthrough must not run" } }
        .to raise_error(Lain::Error, /no session record/i)
    end
  end
end

# The side chat /btw opens forks this session's header, so it asks the same
# backend the session ran on without a backend flag on its pane command. The
# real command composes the popup's command, and that command's argv goes
# through the exe's Thor parse and the real ChatLaunch backend resolution; only
# the conversation, the editor views and the daily reap are stubbed.
RSpec.describe Lain::CLI::Command::Btw, "the side chat's backend" do
  load File.expand_path("../../../../exe/lain", __dir__) unless defined?(LainCLI)

  around do |example|
    Dir.mktmpdir("lain-btw-profile") do |dir|
      env = %w[LAIN_PROVIDER LAIN_API_BASE LAIN_MODEL LAIN_NUM_CTX LAIN_NUM_BATCH].to_h { |name| [name, nil] }
      with_env(env.merge("XDG_STATE_HOME" => dir)) { example.run }
    end
  end

  let(:timeline) do
    Lain::Timeline.empty(store: Lain::Store.new)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end
  let(:session_path) do
    context = Lain::Context.new(model: "qwen3:4b", max_tokens: 64)
    records = [Lain::SessionRecord.header(context:, toolset: Lain::Toolset.new, profile: { "provider" => "ollama" }),
               *timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) },
               Lain::Telemetry::SessionClosed.new(head: timeline.head_digest, reason: :exit).to_journal]
    File.join(Lain::Paths.new.sessions_dir, "20260101T000000-1.ndjson").tap do |path|
      File.write(path, records.map { |record| "#{JSON.generate(record)}\n" }.join)
    end
  end

  before do
    stub_request(:get, %r{/api/ps})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate("models" => []))
    stub_const("Lain::CLI::GcSchedule::SPAWN", ->(*, **) {})
  end

  def composed_command(question)
    surface = instance_double(Lain::CLI::TmuxSurface)
    composed = nil
    allow(surface).to receive(:popup) do |command:, **|
      composed = command
      Lain::CLI::TmuxSurface::Placement.new(kind: :popup, target: "btw", degraded: false, reason: nil)
    end
    chronicle = instance_double(Lain::CLI::Chronicle, journal_path: session_path, catch_up: nil)
    agent = instance_double(Lain::Agent, timeline:, dispatching?: false)
    env = build_command_env(agent:, chronicle:, tmux_surface: surface)
    described_class.new.call(question, env)
    composed
  end

  def resolved_backend(argv)
    seen = nil
    wiring = instance_double(Lain::CLI::Wiring, conductor: instance_spy(Lain::CLI::Conductor), exit_status: 0)
    allow(wiring).to receive(:run) { |backend:, **| seen = backend }
    allow(Lain::CLI::Wiring).to receive(:new).and_return(wiring)
    views = instance_double(Lain::CLI::LiveViews, views: nil, fleet: nil)
    allow(Lain::CLI::LiveViews).to receive(:new).and_return(views)
    LainCLI.start(argv, debug: true)
    seen
  end

  it "asks the side question of an ollama session on ollama" do
    argv = composed_command("a side question").shellsplit.drop_while { |word| word != "exec" }.drop(2)

    expect(argv).to include("--btw", "--fork", "--prompt", "a side question")
    expect(resolved_backend(argv).run_profile.provider).to eq("ollama")
  end
end
