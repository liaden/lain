# frozen_string_literal: true

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

  it "asks the question, naming the tool and its input" do
    policy_for("y\n").decide(pending)

    expect(output.string).to include("bash").and include("rm -rf /tmp/x")
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
end
