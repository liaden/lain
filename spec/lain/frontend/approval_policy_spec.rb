# frozen_string_literal: true

require "pastel"
require "stringio"

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
