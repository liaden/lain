# frozen_string_literal: true

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ApproveSpecSupport
  # The minimal effect a {Approval::Queue::Pending} reads: a name and an input.
  Effect = Struct.new(:name, :input)
end

RSpec.describe Lain::CLI::Command::Approve do
  subject(:approve) { described_class.new(prompt:) }

  let(:answers) { [] }
  let(:asked) { [] }
  # The drain UX is Frontend::ApprovalPolicy's own prompt loop, its reader
  # scripted the way the Repl scripts it over the conductor -- so decisions are
  # signed with its "tty" surface, not a name this command invents.
  let(:prompt) do
    Lain::Frontend::ApprovalPolicy.new(reader: lambda { |question|
      asked << question
      answers.shift
    })
  end

  def pending(tool = "bash", input = { "command" => "ls" })
    Lain::Approval::Queue::Pending.new(effect: ApproveSpecSupport::Effect.new(tool, input),
                                       requester: "agent", clock: -> { 0.0 })
  end

  def env_over(parked)
    instance_double(Lain::CLI::Command::Env, approvals: parked)
  end

  it "registers as /approve with a one-line usage" do
    expect(approve.name).to eq("approve")
    expect(approve.usage).to include("/approve")
  end

  describe "draining three parked pendings inline" do
    let(:parked) { [pending("bash"), pending("edit_file", { "path" => "/etc/passwd" }), pending("bash")] }
    let(:answers) { %w[y n y] }

    it "renders each pending for y/N in turn" do
      approve.call("", env_over(parked))

      expect(asked.size).to eq(3)
      expect(asked.first).to include("bash")
      expect(asked[1]).to include("edit_file")
    end

    it "decides each pending as answered, signed tty" do
      approve.call("", env_over(parked))

      expect(parked.map(&:decision)).to eq(%i[approve deny approve])
      expect(parked.map(&:surface)).to eq(%w[tty tty tty])
    end

    it "returns the decisions as rendered text, never printing" do
      text = nil
      expect { text = approve.call("", env_over(parked)) }.not_to output.to_stdout
      expect(text).to be_a(String).and include("approved").and include("denied")
    end
  end

  it "skips a pending another surface already decided -- no human is asked about a settled call" do
    settled = pending("bash")
    settled.approve(surface: "editor")
    live = pending("edit_file")
    answers << "y"

    approve.call("", env_over([settled, live]))

    expect(asked.size).to eq(1)
    expect(settled.surface).to eq("editor")
  end

  it "names the deciding surface when another surface wins mid-drain" do
    racy = pending("bash")
    race_prompt = Lain::Frontend::ApprovalPolicy.new(reader: lambda { |_question|
      racy.deny(surface: "timeout")
      "y"
    })

    text = described_class.new(prompt: race_prompt).call("", env_over([racy]))

    expect(text).to include("bash: denied (timeout)")
  end

  it "renders an honest empty drain when nothing is parked" do
    expect(approve.call("", env_over([]))).to include("no pending approvals")
  end

  it "degrades to the same empty drain over YoloApprovals (a --yolo session)" do
    expect(approve.call("", env_over(Lain::CLI::Command::Env::YoloApprovals))).to include("no pending approvals")
  end
end
