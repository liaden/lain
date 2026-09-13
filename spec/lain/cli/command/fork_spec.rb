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
  # "is a run outstanding?" -- the reader `anchor!`'s gate turns on. Defaults to
  # nobody waiting, which is the `you> ` prompt: the ONLY state in which a line
  # is read at all unless a question is parked.
  let(:reply_outstanding) { false }
  let(:replies) { instance_double(Lain::CLI::HumanReplies, pending?: reply_outstanding) }
  let(:env) { build_command_env(agent:, chronicle:, fork_point:, tmux_surface:, supervisor:, replies:) }

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
        .with(command: Lain::CLI::PaneCommand.call("chat", "--fork", selector),
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

  # The inconsistency opened here has an answer, and the review round narrowed
  # it. `lain chat --fork` REPAIRS a torn fork point: it projects a cancellation
  # result for every stranded call. This door does not simply follow, because it
  # is not always looking at the same fact.
  #
  # On disk, an assistant tool_use with no result means the call was stranded --
  # nothing will ever answer it, so answering it as cancelled states a fact.
  # LIVE, the same shape can mean the call is RUNNING. Both prompts dispatch
  # through one bound registry over one Env (`wiring.rb:474`), so `/fork` is
  # typeable at the `human> ` prompt a parked ask_human opens
  # (`human_replies.rb:1113`) -- and there the head's tool_use IS that
  # ask_human, in flight.
  #
  # What separates the two is `env.replies.pending?`, which is exactly true for
  # the life of that prompt (`AnswerLoop#exchange` enqueues BEFORE it parks).
  # So the door refuses only what it can actually see going, and repairs the
  # rest. It fails safe in one direction: a question a subagent queued while the
  # human sat idle at `you> ` also reads pending, which over-refuses a fork that
  # would have been fine.
  describe "a mid-tool head" do
    let(:head_turn) do
      instance_double(Lain::Event, role: "assistant",
                                   content: [{ "type" => "tool_use", "id" => "toolu_01", "name" => "echo",
                                               "input" => { "text" => "hi" } }])
    end

    context "with a reply outstanding -- the call may still be in flight" do
      let(:reply_outstanding) { true }

      it "gates BEFORE any window opens, naming the shape in the words the child uses for it" do
        expect { fork_command.call("", env) }
          .to raise_error(Lain::CLI::Resume::Refusal, /awaiting tool results/)

        # The head still journals durably first (idempotent, and the child-side
        # check then reads the same fact from disk) -- but nothing opens.
        expect(calls).to eq([:catch_up])
      end

      # The refusal may claim only what the door can see. It sees a parked
      # question, not a running tool, so it says "may" -- the earlier draft
      # asserted the call WAS still being made, which is false at `you> `.
      it "says why a live head differs, without asserting more than it knows" do
        expect { fork_command.call("", env) }
          .to raise_error(Lain::CLI::Resume::Refusal) do |error|
            expect(error.message).to include("may")
            expect(error.message).not_to match(/\bis still (running|being made)\b/)
          end
      end

      # The verb is the point of the card: this door forks, so a refusal saying
      # "cannot resume" sends the reader to a command they did not run.
      it "names THIS door and the file, and a remedy the human can reach from here" do
        expect { fork_command.call("", env) }
          .to raise_error(Lain::CLI::Resume::Refusal) do |error|
            expect(error.message).to start_with("cannot fork #{session}:")
            expect(error.message).to include("lain chat --fork")
          end
      end
    end

    context "with nobody waiting on a reply -- the tear is stranded, as on disk" do
      it "opens the window: the child answers the stranded call exactly as `--fork` does" do
        expect { fork_command.call("", env) }.not_to raise_error

        expect(calls).to eq(%i[catch_up resolve window])
      end
    end
  end

  # The gate needs BOTH facts. A parked question over a perfectly settled head
  # is an ordinary fork and must not be refused for the reply's sake.
  describe "a settled head while a reply is outstanding" do
    let(:reply_outstanding) { true }

    it "forks normally" do
      expect { fork_command.call("", env) }.not_to raise_error

      expect(calls).to eq(%i[catch_up resolve window])
    end
  end

  # The load-bearing link under {Fork#anchor!}'s gate, made a check instead of
  # a reading of `wiring.rb:474`. That gate refuses a torn head this command's
  # own child would repair, and the ONLY thing justifying the wider refusal is
  # that `/fork` is reachable while a run is still outstanding -- at the
  # `human> ` prompt a parked ask_human opens, where the head's tool_use is
  # that ask_human, in flight.
  #
  # It is reachable there because `Reply#classify` (`human_replies.rb:1110-1113`)
  # asks `serves_replies?` FIRST and only dispatches the lines that answer
  # false. So if a later card ever gave this command a `serves_replies? = true`
  # -- to open a `human> ` read of its own, the one reason any command declares
  # it -- `/fork` would stop being dispatchable at that prompt, the live
  # in-flight case would evaporate, and `anchor!`'s gate would be left standing
  # on a reason that had quietly become false. Nothing would fail: `Registry`
  # sends the message optionally, after a `respond_to?` check
  # (`registry.rb:68-71`), and `registry_spec.rb:121-148` pins the pair to
  # `/inbox` in both directions and says nothing about this command. A green
  # suite over a justification that no longer holds is the exact shape this
  # chunk exists to attack, so it is witnessed here.
  it "does not serve replies, so it stays DISPATCHABLE at the `human> ` prompt a parked ask_human opens" do
    expect(Lain::CLI::Command::Registry.new([fork_command]).serves_replies?("/fork")).to be(false)
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
