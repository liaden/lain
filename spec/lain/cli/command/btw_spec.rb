# frozen_string_literal: true

require "shellwords"
require "tmpdir"

# T17: /btw (ephemeral side-question in a tmux popup) and /keep (promote the
# ephemeral session from inside). Keep's quiescence rule is pinned here too:
# RelocatableSpool#relocate is unsynchronized with the ResponseWal monitor, so
# promote! runs only from the Repl's quiescent point -- command dispatch is
# between the MAIN agent's asks by construction (Repl#converse dispatches
# synchronously), and the one cross-ask exception, an adopted fleet actor
# possibly mid-round-trip, is refused conservatively.
RSpec.describe Lain::CLI::Command::Btw do
  let(:head) { "blake3:abc123def456" }
  let(:timeline) { instance_double(Lain::Timeline, head_digest: head) }
  let(:agent) { instance_double(Lain::Agent, timeline:) }
  let(:journal_path) { "/state/lain/sessions/p/20260723T120000Z-1234.ndjson" }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, journal_path:, catch_up: nil)
  end
  let(:tmux_surface) { instance_double(Lain::CLI::TmuxSurface) }
  let(:command) { described_class.new }

  def placement(kind: :popup, degraded: false, reason: nil)
    Lain::CLI::TmuxSurface::Placement.new(kind:, target: "btw", degraded:, reason:)
  end

  def env_with(chronicle:, agent:, supervisor: Lain::Supervisor::Null)
    Lain::CLI::Command::Env.new(
      status: Lain::CLI::Command::Env::NullStatus, sessions: spy("sessions"),
      approvals: Lain::CLI::Command::Env::NullApprovals, supervisor:,
      replies: spy("replies"), fork_point: Lain::CLI::Command::Env::NullForkPoint,
      tmux_surface:, agent:, chronicle:,
      policy_switch: Lain::CLI::Command::Env::NullPolicySwitch,
      model_switch: Lain::CLI::Command::Env::NullModelSwitch,
      role_spawn: Lain::CLI::Command::Env::NullRoleSpawn
    )
  end

  let(:env) { env_with(chronicle:, agent:) }

  describe "the ephemeral popup" do
    it "runs the child through Up's pane recipe (never a bare `lain chat`), rooted at this project's cwd" do
      selector = "#{File.basename(journal_path)}@#{head}"
      expect(tmux_surface).to receive(:popup) do |command:, cwd:, **|
        expect(command).to eq(Lain::CLI::Up.pane_command("chat", "--btw", "--fork", selector,
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

  describe "the control-mode degrade (T2 Placement)" do
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
    double("registration", role:, state:)
  end

  def env_with(chronicle:, supervisor: Lain::Supervisor::Null)
    Lain::CLI::Command::Env.new(
      status: Lain::CLI::Command::Env::NullStatus, sessions: spy("sessions"),
      approvals: Lain::CLI::Command::Env::NullApprovals, supervisor:,
      replies: spy("replies"), fork_point: Lain::CLI::Command::Env::NullForkPoint,
      tmux_surface: spy("tmux_surface"), agent: spy("agent"), chronicle:,
      policy_switch: Lain::CLI::Command::Env::NullPolicySwitch,
      model_switch: Lain::CLI::Command::Env::NullModelSwitch,
      role_spawn: Lain::CLI::Command::Env::NullRoleSpawn
    )
  end

  describe "promotion from the Repl's quiescent point" do
    # Command dispatch happens between the main agent's asks by construction:
    # Repl#converse runs `dispatch` synchronously and an ask completes inside
    # the dispatch that started it (Repl#respond's Sync), so /keep can never
    # overlap a MAIN-agent round trip. With the fleet quiet too, promote! is
    # safe to run right here.
    it "promotes the ephemeral record and reports the durable name" do
      expect(chronicle).to receive(:promote!).and_return(promoted_path)

      text = command.call("", env_with(chronicle:))

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
      expect(chronicle).to receive(:promote!).and_return(promoted_path)

      expect(command.call("", env)).to include(File.basename(promoted_path))
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

RSpec.describe "the /btw and /keep registration (T17 wiring)" do
  it "claims both names in the shipped surface, ahead of the skill fallthrough" do
    Dir.mktmpdir do |root|
      surface = Lain::CLI::Command::Surface.new(
        agent: spy("agent"), replies: spy("replies"), supervisor: Lain::Supervisor::Null,
        role_spawn: spy("role_spawn"), root:, chronicle: Lain::CLI::Chronicle::Null.new
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
