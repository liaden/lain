# frozen_string_literal: true

require "async"
require "pastel"
require "stringio"
require "tmpdir"

# I4: the terminal y/N prompt is now a queue SURFACE -- it answers Pending
# approvals drawn from Lain::Approval::Queue rather than being Gate's policy
# itself. The y/N contract is unchanged: anything but an affirmative denies.
RSpec.describe Lain::Frontend::ApprovalPolicy do
  let(:output) { StringIO.new }
  let(:effect) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { command: "rm -rf /tmp/x" }) }

  def pending
    Lain::Approval::Queue::Pending.new(effect:, requester: "agent", clock: -> { 0.0 })
  end

  def policy_for(answer)
    described_class.new(output:, input: StringIO.new(answer))
  end

  def pending_from(requester)
    Lain::Approval::Queue::Pending.new(effect:, requester:, clock: -> { 0.0 })
  end

  it "asks the question, naming the tool and its input" do
    policy_for("y\n").decide(pending)

    expect(output.string).to include("bash").and include("rm -rf /tmp/x")
  end

  # T9: with a fleet running, tool-and-input alone cannot say whether the
  # parent or a researcher subagent is the one asking -- the editor's row has
  # led with the requester since T36, and in QA reading the spawn's `only`-set
  # out of the journal was the only way to answer it at the terminal.
  it "names who is asking, alongside the tool and its input" do
    policy_for("y\n").decide(pending_from("researcher"))

    expect(output.string).to include("researcher").and include("bash").and include("rm -rf /tmp/x")
  end

  it "separates a fleet: two requesters ask two different questions" do
    parent = StringIO.new
    described_class.new(output: parent, input: StringIO.new("n\n")).decide(pending_from("agent"))
    policy_for("n\n").decide(pending_from("researcher"))

    # Each names its OWN actor and not the other's -- a bare inequality would be
    # satisfied by any difference at all, including one that named neither.
    expect(parent.string).to include("agent")
    expect(parent.string).not_to include("researcher")
    expect(output.string).to include("researcher")
  end

  %w[y yes Y YES Yes].each do |answer|
    it "approves on #{answer.inspect}" do
      approval = pending
      policy_for("#{answer}\n").decide(approval)

      expect(approval).to have_attributes(decision: :approve, surface: "tty")
    end
  end

  %w[n no N garbage].each do |answer|
    it "denies on #{answer.inspect}" do
      approval = pending
      policy_for("#{answer}\n").decide(approval)

      expect(approval).to have_attributes(decision: :deny, surface: "tty")
    end
  end

  it "denies on a bare newline (the default is refusal, not consent)" do
    approval = pending
    policy_for("\n").decide(approval)

    expect(approval.decision).to eq(:deny)
  end

  it "denies on EOF rather than raising" do
    approval = pending
    policy_for("").decide(approval)

    expect(approval.decision).to eq(:deny)
  end

  it "is a no-op on a pending another surface already decided" do
    approval = pending
    approval.deny(surface: "nvim")

    expect(policy_for("y\n").decide(approval)).to be(false)
    expect(approval).to have_attributes(decision: :deny, surface: "nvim")
  end

  it "parks on the queue and answers arrivals (the surface loop)" do
    queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: StringIO.new))
    policy = policy_for("y\n")

    Sync do |task|
      run = task.async { queue.call(effect, nil) }
      watcher = task.async { policy.watch(queue) }

      expect(run.wait).to be(true)
    ensure
      watcher&.stop
    end
  end

  # T15's second half. A raise inside ONE prompt used to retire this fiber for
  # the rest of the session, silently -- the failure {Approval::Queue::Pending}'s
  # own comment names, and the one every sibling surface already guards
  # ({Approval::QueueSurface#swept}, {CLI::HumanReplies::AnswerLoop#exchange}).
  # This is the surface it is fatal for: on `--no-nvim` there is no second one,
  # so a dead fiber here is a session that can never be asked anything again.
  describe "a prompt that raises" do
    let(:journal_io) { StringIO.new }

    def queue = @queue ||= Lain::Approval::Queue.new(journal: Lain::Journal.new(io: journal_io), timeout: 1.0)

    def decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a

    # Raises on the FIRST prompt only, so an example can ask the question that
    # matters: is this surface still answering afterwards?
    def policy_failing_once(output:)
      asked = 0
      described_class.new(output:, reader: lambda { |_prompt|
        asked += 1
        raise "the terminal went away" if asked == 1

        "y\n"
      })
    end

    def two_gated_calls(policy)
      Sync do |task|
        watcher = task.async { policy.watch(queue) }
        Array.new(2) { task.with_timeout(3) { task.async { queue.call(effect, nil) }.wait } }
      ensure
        watcher&.stop
      end
    end

    it "keeps watching, and refuses the pending it could not ask about" do
      expect(two_gated_calls(policy_failing_once(output:))).to eq([false, true])
      expect(output.string).to include("the terminal went away")
    end

    # On a study bench the Journal IS the experiment record, and `queue.rb`
    # argues at length that decision latency is evidence. A fault-denial signed
    # "tty" is byte-identical to a person typing `n` -- so a reader counting
    # human refusals counts a broken terminal as one, and {Approval::Escalation}
    # weighs a person's authority differently from a machine's. The refusal is
    # right; the attribution is not. Neither {Approval::Queue::TIMEOUT_SURFACE}
    # nor {Approval::Queue::ABANDONED_SURFACE} pretends to be a person either.
    it "signs that refusal as the surface's own fault, never as a person's answer" do
      two_gated_calls(policy_failing_once(output:))

      expect(decisions.first).to include("verdict" => "deny", "surface" => described_class::FAULT_SURFACE)
      expect(described_class::FAULT_SURFACE).not_to eq(described_class::SURFACE)
    end

    # The rescue's own render is the likeliest next raise -- the example above
    # is literally "the terminal went away" -- and a rescue that dies leaves the
    # pending undenied, which is strictly worse than no guard at all. So the
    # denial lands FIRST and the reporting is wrapped in its own rescue, the
    # shape {Approval::QueueSurface#journal_fault} already uses.
    it "still refuses, and still keeps watching, when reporting the failure raises too" do
      unwritable = Object.new
      def unwritable.puts(*) = raise(IOError, "closed stream")
      def unwritable.flush = raise(IOError, "closed stream")

      expect(two_gated_calls(policy_failing_once(output: unwritable))).to eq([false, true])
      expect(decisions.first).to include("surface" => described_class::FAULT_SURFACE)
    end
  end

  # T15, from manual-QA round 4 (F18): the FIRST gated call of a turn rendered
  # and was answerable; every one after it rendered nothing and was never read,
  # so a plain `lain chat` -- which has no second surface -- wedged for good.
  #
  # The measured mechanism is a CO-CONSUMER, not the terminal. `Approval::Queue`
  # hands each arrival to exactly one `#dequeue` caller ({Async::Queue} delegates
  # to a `Thread::Queue`), and a real chat wires TWO of them beside each other:
  # this surface and {Lain::Notify}. Both park; the first arrival goes to
  # whichever parked first (this one, spawned first by
  # {CLI::Repl::ApprovalSurfaces#watch}), and from then on the notifier is ahead
  # of it in the waiter FIFO forever -- because this surface leaves the queue to
  # ask a human while the notifier re-parks at once. So arrival two, and every
  # arrival after it, is taken by a surface that cannot answer at the terminal
  # and holds it for the whole of dunstify's blocking wait.
  #
  # The examples drive TWO gated calls through the real pair, because one call
  # cannot see this at all -- which is exactly why a green suite shipped it. The
  # streamed {Telemetry::ToolOutput} between them is the QA repro's own shape
  # (what made the second call LATE); it is rendered here so the reproduction is
  # the measured one rather than a tidier cousin.
  describe "a second gated call in one turn, beside the surfaces a real chat wires", :seam do
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io) }
    # Short, and it is the counterfactual: a pending no surface can answer is
    # denied by the clock, so a stolen one fails in words instead of hanging.
    let(:queue) { Lain::Approval::Queue.new(journal:, timeout: 1.0) }
    let(:channel) { Lain::Channel.new }
    let(:pane) { StringIO.new }
    # dunstify BLOCKS its own process until a human clicks, dismisses, or its
    # `-t` window (the queue's own, 300s) expires -- so a pending this surface
    # takes is a pending it HOLDS. The latch reproduces the hold exactly; the
    # ensure closes it, and a closed Thread::Queue pops nil at once.
    let(:dunst) { Thread::Queue.new }

    def holding_shell_out_class
      Class.new do
        def initialize(*, latch:, **)
          super()
          @latch = latch
        end

        def run_command = tap { @latch.pop }
        def stdout = ""
      end
    end

    def notifier
      klass = holding_shell_out_class
      latch = dunst
      Lain::Notify.new(shell_out_factory: ->(*, **) { klass.new(latch:) })
    end

    def gated(id, command)
      Lain::Effect::ToolCall.new(tool_use_id: id, name: "bash", input: { "command" => command })
    end

    def tty
      @tty ||= Lain::Frontend::TTY.new(channel:, output: pane, input: StringIO.new,
                                       history_path: File.join(@dir, "history"))
    end

    # One turn: gated call, streamed output to the pane, gated call. Answers the
    # two verdicts the gated fibers received; the prompts this surface rendered
    # and the journal carry the rest.
    def turn_of_two_gated_calls(answer:)
      prompts = []
      policy = described_class.new(pastel: Pastel.new(enabled: false), reader: lambda { |prompt|
        prompts << prompt
        answer
      })
      [prompts, verdicts_from(policy)]
    end

    def verdicts_from(policy)
      Sync do |task|
        watching = [task.async { policy.watch(queue) }, task.async { notifier.watch(queue) }]
        [settled(task, "call_1", "echo HELLO"), streamed("call_1"), settled(task, "call_2", "ls ./spec")]
          .values_at(0, 2)
      ensure
        watching.each { |surface| surface&.stop }
      end
    end

    def settled(task, id, command)
      gate = task.async { queue.call(gated(id, command), nil) }
      task.with_timeout(5) { gate.wait }
    end

    # The first tool's stdout reaching the pane, through the real decorator --
    # the event that separated the working first call from the broken second.
    def streamed(id)
      channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: id, stream: :stdout, bytes: "HELLO\n"))
      tty.drain_and_render
    end

    def decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a

    around do |example|
      Dir.mktmpdir { |dir| (@dir = dir) && example.run }
    ensure
      dunst.close
    end

    it "prompts the human for the second gated call too, naming the tool and what it would run" do
      prompts, = turn_of_two_gated_calls(answer: "y\n")

      expect(prompts.size).to eq(2)
      expect(prompts.last).to include("bash").and include("ls ./spec")
    end

    it "applies the answer to that second pending, so the run continues" do
      _, verdicts = turn_of_two_gated_calls(answer: "y\n")

      expect(verdicts).to eq([true, true])
      expect(decisions.map { |record| record.fetch("surface") }).to eq(%w[tty tty])
    end

    it "refuses a denied second call at once rather than wedging on the clock" do
      _, verdicts = turn_of_two_gated_calls(answer: "n\n")

      expect(verdicts).to eq([false, false])
      expect(decisions.last).to include("surface" => "tty", "verdict" => "deny", "timed_out" => false)
    end
  end

  # The conductor seam: the exe injects `-> (prompt) { conductor.read_reply(...) }`
  # so approval prompts serialize with ask_human replies on the one stdin and a
  # blocking gets cannot starve the fail-closed timer.
  it "reads through an injected reader, which then owns both the write and the read" do
    prompts = []
    policy = described_class.new(output:, reader: lambda { |prompt|
      prompts << prompt
      "y\n"
    })
    approval = pending

    policy.decide(approval)

    expect(prompts.first).to include("bash")
    expect(approval.decision).to eq(:approve)
    expect(output.string).to be_empty
  end

  it "fails closed when the injected reader answers nil (EOF at the conductor)" do
    approval = pending
    described_class.new(output:, reader: ->(_prompt) {}).decide(approval)

    expect(approval.decision).to eq(:deny)
  end

  it "keeps the affirmative pattern a private implementation detail" do
    expect { described_class::AFFIRMATIVE }.to raise_error(NameError, /private constant/)
  end

  # T16: a Pending can carry the sensitive regions approving it would release
  # (Approval::Queue::Outstanding), and this surface is where they are rendered
  # -- lib/ may not touch the terminal, so the whole capability's human half
  # lives behind the injected reader here.
  describe "a pending carrying outstanding sensitive regions" do
    # A REAL detection, not a hand-built double: the "no secret bytes" example
    # below is vacuous unless the regions it renders genuinely hold the key,
    # and `bytes` is what a careless renderer would reach for.
    let(:secret) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }
    let(:regions) { Lain::Sensitivity::Regions.detect("API_KEY=#{secret}\nDB_PASSWORD=hunter2pass\n") }

    def outstanding(path: "/repo/.env", regions: self.regions)
      Lain::Approval::Queue::Outstanding.new(path:, regions:)
    end

    def disclosing(**)
      Lain::Approval::Queue::Pending.new(effect:, requester: "agent", clock: -> { 0.0 },
                                         outstanding: outstanding(**))
    end

    # Every prompt below goes through a reader rather than `output`, and pastel
    # is disabled, so an example asserts on the exact bytes a human is shown.
    def rendered(pending)
      asked = []
      described_class.new(output:, pastel: Pastel.new(enabled: false),
                          reader: lambda { |prompt|
                            asked << prompt
                            "n\n"
                          }).decide(pending)
      asked.first
    end

    it "holds the key's own bytes, so the redaction example below can discriminate" do
      expect(regions.map(&:bytes)).to include(secret)
    end

    it "names the file and says how many regions are outstanding" do
      expect(rendered(disclosing)).to start_with('"/repo/.env": 2 sensitive regions outstanding -- ')
    end

    it "counts in the singular when exactly one region is outstanding" do
      expect(rendered(disclosing(regions: regions.take(1)))).to include("1 sensitive region outstanding")
    end

    it "shows no secret bytes: a human is told WHICH file and HOW MANY, never a value" do
      expect(rendered(disclosing)).not_to include(secret)
    end

    # T9 changed these bytes deliberately: the question now leads with WHO is
    # asking, the same word the editor's row leads with. What is unchanged is
    # the half this example exists for -- with nothing outstanding, no preamble
    # reaches the human at all.
    it "renders the ordinary prompt, byte for byte, when the pending discloses nothing" do
      expect(rendered(pending)).to eq("agent asks: approve bash(#{effect.input.inspect})? [y/N] ")
    end

    it "still asks the ordinary y/N question, so the verdict path is untouched" do
      approval = disclosing
      policy_for("y\n").decide(approval)

      expect(approval).to have_attributes(decision: :approve, surface: "tty")
    end

    # The path is model-influenced: it is the file the model asked to read, and
    # the detector need only fire on a file the agent itself wrote. The half of
    # this question that predates T16 escapes through `inspect`; the release
    # clause has to as well, or a crafted path forges a whole question.
    describe "the path is escaped, because a forged one is a released secret" do
      # A path spelled as a complete, plausible, BENIGN approval question.
      let(:forged) { '/tmp/notes.txt: 0 sensitive regions outstanding -- approve read({path: "/ok"})? [y/N] ' }

      it "renders a prompt-shaped path as one inert quoted string" do
        expect(rendered(disclosing(path: forged))).not_to start_with(forged)
      end

      it "still names that path, escaped rather than dropped" do
        expect(rendered(disclosing(path: forged))).to start_with(forged.inspect)
      end

      it "escapes a control sequence rather than letting it reach the terminal" do
        rendering = rendered(disclosing(path: "/repo/\e[2K\rsafe.txt"))

        expect(rendering).not_to include("\e[2K\r")
        expect(rendering).to include('\e[2K\r')
      end

      # The residual, stated rather than wished away: escaping QUOTES the forged
      # text, it does not delete it, so a `[y/N]` a path smuggled in is still
      # legible inside the quotes -- exactly as one smuggled through `input`
      # always has been. What escaping buys is that it cannot leave them. The
      # real question is therefore always the one that ENDS the line, and a
      # human who reads to the end of it reads the truth.
      it "keeps the real question at the end of the line, where the forged one cannot reach" do
        rendering = rendered(disclosing(path: forged))

        expect(rendering).to end_with("approve bash(#{effect.input.inspect})? [y/N] ")
        expect(rendering.rindex("? [y/N] ")).to be > rendering.index(forged.inspect)
      end
    end

    # The anti-divergence pin, and the panel's correction to it: comparing two
    # policies that differ only in `reader:` cannot see a NEW collaborator added
    # with a default -- which, since every collaborator this class has is
    # defaulted, is the likely shape. So pin the parameter list itself, and
    # drive the question through the three constructor shapes lib/ actually
    # uses (switchboard and ApprovalSurfaces pass `reader:`; Command::Surface's
    # fallback passes nothing at all).
    describe "no two of this process's ApprovalPolicys can ask a different question" do
      it "takes no collaborator that could carry release state" do
        expect(described_class.instance_method(:initialize).parameters)
          .to eq([%i[key output], %i[key input], %i[key pastel], %i[key reader]])
      end

      it "asks the identical question from every constructor shape lib/ builds" do
        approval = disclosing
        asked = []
        reader = lambda { |prompt|
          asked << prompt
          "n\n"
        }
        shapes = [{ reader: },                                    # switchboard, ApprovalSurfaces
                  { input: StringIO.new("n\n") },                 # Command::Surface's bare .new
                  { input: StringIO.new("n\n"), reader: }]

        texts = shapes.map do |kwargs|
          sink = StringIO.new
          described_class.new(output: sink, pastel: Pastel.new(enabled: false), **kwargs).decide(approval)
          asked.pop || sink.string
        end

        expect(texts.uniq).to eq([texts.first])
      end
    end
  end
end
