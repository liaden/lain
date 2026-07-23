# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Fork do
  subject(:fork_command) { described_class.new(environment: { "TMUX" => "/tmp/tmux-1000/default,42,0" }) }

  let(:head) { "blake3:#{"ab12" * 16}" }
  let(:session) { "2026-07-23T10-00-00Z-chat.ndjson" }
  let(:selector) { "#{session}@#{head}" }
  let(:command_line) { "lain chat --fork #{selector}" }

  let(:calls) { [] }
  # A settled head: the mid-tool gate reads role/content off the head turn
  # exactly as the child's Resume#fork would.
  let(:head_turn) { instance_double(Lain::Event, role: "user", content: [{ "type" => "text", "text" => "hi" }]) }
  let(:timeline) { instance_double(Lain::Timeline, head_digest: head, head: head_turn) }
  let(:agent) { instance_double(Lain::Agent, timeline:) }
  let(:chronicle) do
    chronicle = instance_double(Lain::CLI::Chronicle, journal_path: "/sessions/#{session}")
    allow(chronicle).to receive(:catch_up) { calls << :catch_up }
    chronicle
  end
  let(:fork_point) do
    point = instance_double(Lain::CLI::ForkPoint)
    allow(point).to receive(:call) { calls << :resolve }
    point
  end
  let(:placement) { Lain::CLI::TmuxSurface::Placement.new(kind: :window, target: "fork-ab12ab12ab12", degraded: false, reason: nil) }
  let(:tmux_surface) do
    surface = instance_double(Lain::CLI::TmuxSurface)
    allow(surface).to receive(:window) {
      calls << :window
      placement
    }
    surface
  end
  let(:supervisor) { Lain::Supervisor::Null }
  let(:env) do
    instance_double(Lain::CLI::Command::Env,
                    agent:, chronicle:, fork_point:, tmux_surface:, supervisor:)
  end

  it "registers as /fork with a one-line usage" do
    expect(fork_command.name).to eq("fork")
    expect(fork_command.usage).to start_with("/fork")
  end

  describe "forking the orchestrator at its head" do
    it "durably journals the head FIRST, then opens the tmux window" do
      fork_command.call("", env)

      expect(calls.first).to eq(:catch_up)
      expect(calls.last).to eq(:window)
      expect(chronicle).to have_received(:catch_up).with(timeline)
    end

    it "runs the fork through Up's pane recipe, rooted at this project's cwd -- never a bare `lain chat`" do
      fork_command.call("", env)

      expect(tmux_surface).to have_received(:window)
        .with(command: Lain::CLI::Up.pane_command("chat", "--fork", selector),
              name: "fork-ab12ab12ab12", cwd: Dir.pwd)
    end

    it "proves the selector resolves through the SAME ForkPoint the child will use, before any window opens" do
      fork_command.call("", env)

      expect(fork_point).to have_received(:call).with(selector)
      expect(calls.index(:resolve)).to be < calls.index(:window)
    end

    it "returns rendered text naming the window and the exact child command -- never prints" do
      text = nil
      expect { text = fork_command.call("", env) }.not_to output.to_stdout

      expect(text).to include(placement.target, command_line)
    end

    it "lets a ForkPoint refusal propagate -- an unresolvable head must not open a doomed window" do
      allow(fork_point).to receive(:call).and_raise(Lain::CLI::Resume::Refusal, "no turn matching")

      expect { fork_command.call("", env) }.to raise_error(Lain::CLI::Resume::Refusal)
      expect(tmux_surface).not_to have_received(:window)
    end
  end

  describe "a mid-tool head" do
    let(:head_turn) do
      instance_double(Lain::Event, role: "assistant",
                                   content: [{ "type" => "tool_use", "id" => "toolu_01", "name" => "echo",
                                               "input" => { "text" => "hi" } }])
    end

    it "mirrors the child's refuse_mid_tool! gate BEFORE any window opens, in the child's own words" do
      expect { fork_command.call("", env) }
        .to raise_error(Lain::CLI::Resume::Refusal, /awaiting tool results/)

      # The head still journals durably first (idempotent, and the child-side
      # check then reads the same fact from disk) -- but nothing opens.
      expect(calls).to eq([:catch_up])
    end
  end

  describe "a subagent target" do
    let(:supervisor) { [instance_double(Lain::Supervisor::Registration, role: "researcher")] }

    it "is refused honestly: child chains are not on disk, and the orchestrator-head form is named" do
      text = fork_command.call("researcher", env)

      expect(text).to include("researcher")
      expect(text).to match(/not.*on disk|no.*file/i)
      expect(text).to include("/fork")
    end

    it "does NOT attempt the fork" do
      fork_command.call("researcher", env)

      expect(calls).to be_empty
    end
  end

  describe "an unregistered target" do
    it "is refused naming the bare orchestrator-head form, not attempted" do
      text = fork_command.call("nobody", env)

      expect(text).to include("nobody", "/fork")
      expect(calls).to be_empty
    end
  end

  describe "outside tmux" do
    subject(:fork_command) { described_class.new(environment: {}) }

    it "prints the exact `lain chat --fork ...` command instead of failing" do
      text = fork_command.call("", env)

      expect(text).to include(command_line)
      expect(tmux_surface).not_to have_received(:window)
    end

    it "still journals the head durably -- the printed command must be runnable" do
      fork_command.call("", env)

      expect(calls.first).to eq(:catch_up)
      expect(fork_point).to have_received(:call).with(selector)
    end
  end

  describe "tmux unavailable at window time" do
    it "degrades to the exact command instead of failing" do
      allow(tmux_surface).to receive(:window)
        .and_raise(Lain::CLI::TmuxSurface::TmuxUnavailable, "tmux not found on PATH")

      text = fork_command.call("", env)

      expect(text).to include(command_line, "tmux not found on PATH")
    end
  end

  describe "without a durable journal" do
    let(:chronicle) { instance_double(Lain::CLI::Chronicle, journal_path: nil) }

    it "refuses honestly instead of composing a selector no file backs" do
      text = fork_command.call("", env)

      expect(text).to match(/no durable (session )?journal|--no-journal/i)
      expect(calls).to be_empty
    end
  end

  describe "before any turn is recorded" do
    let(:timeline) { instance_double(Lain::Timeline, head_digest: nil) }

    it "refuses honestly: there is no head to fork yet" do
      text = fork_command.call("", env)

      expect(text).to match(/no turns|nothing.*recorded|no head/i)
      expect(calls).to be_empty
    end
  end
end
