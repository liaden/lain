# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Deny do
  subject(:deny) { described_class.new(prompt:) }

  let(:answers) { [] }
  let(:asked) { [] }
  let(:prompt) do
    Lain::Frontend::ApprovalPolicy.new(output: StringIO.new, reader: lambda { |question|
      asked << question
      answers.shift
    })
  end
  let(:effect) { Struct.new(:name, :input, :tool_use_id) }

  def pending(tool = "bash", input = { "command" => "ls" })
    Lain::Approval::Parked::Queue::Pending.new(effect: effect.new(tool, input, "tu_#{tool}"),
                                               identity: Lain::Requester.main, clock: -> { 0.0 })
  end

  def env_over(parked) = instance_double(Lain::CLI::Command::Env, approvals: parked)

  it "registers as /deny with a one-line usage naming its reason" do
    expect([deny.name, deny.usage]).to match([eq("deny"), include("/deny <reason>")])
  end

  it "declares it reads the human's answer itself, as /approve does" do
    expect(deny.serves_replies?).to be(true)
  end

  describe "as a control command" do
    it "acts during a run" do
      expect(deny.disposition).to eq(:control)
    end

    it "refuses with nothing undecided, and has no refusal while a call is parked" do
      done = pending
      done.approve(surface: "tty")

      expect([deny.refusal(env_over([done])), deny.refusal(env_over([pending]))]).to eq(["no pending approvals", nil])
    end
  end

  describe "with exactly one parked call" do
    let(:parked) { pending }

    it "denies it with the reason, signed by the human at the terminal, asking nothing" do
      said = deny.call("use lain epic status", env_over([parked]))

      expect([parked.decision, parked.reason, parked.surface, parked.human?, asked, said])
        .to eq([:deny, "use lain epic status", "tty", true, [], 'bash({"command" => "ls"}): denied'])
    end

    # It denies whichever call is undecided as it runs, which fails closed; the line says which one that was.
    it "names the call it denied by a short preview of it" do
      long = pending("bash", { "command" => "rm -rf #{"build/" * 20}" })

      said = deny.call("", env_over([long]))

      expect(said).to eq("#{long.call_face[0, 60]}…: denied")
    end

    it "denies it with no reason when none is given" do
      deny.call("", env_over([parked]))

      expect([parked.decision, parked.reason]).to eq([:deny, nil])
    end

    it "reads its reason through the reply grammar, as a deny typed at [y/N] is read" do
      deny.call("- wrong tree", env_over([parked]))

      expect(parked.reason).to eq("wrong tree")
    end
  end

  describe "with several parked calls" do
    let(:parked) { [pending("bash"), pending("edit_file", {}), pending("write_file", {})] }

    it "asks about each call in turn, and denies the one answered no with the reason" do
      answers.push("hold", "n")

      deny.call("wrong tree", env_over(parked))

      expect([asked.size, parked.map(&:decision), parked[1].reason]).to eq([2, [:postpone, :deny, nil], "wrong tree"])
    end

    it "asks y/N for each in turn: a y approves that call, the first n denies with the reason, and asking stops" do
      answers.push("y", "n", "n")

      said = deny.call("wrong tree", env_over(parked))

      expect([asked.size, parked.map(&:decision), parked.map(&:reason), said])
        .to eq([2, [:approve, :deny, nil], [nil, "wrong tree", nil],
                %(bash({"command" => "ls"}): approved\nedit_file({}): denied)])
    end

    it "stops asking once it has denied a call" do
      answers.push("n", "n")

      said = deny.call("wrong tree", env_over(parked))

      expect([asked.size, parked.map(&:decided?), parked.first.reason, said])
        .to eq([1, [true, false, false], "wrong tree", 'bash({"command" => "ls"}): denied'])
    end

    # A call another surface decides mid-walk is not a deny this command made, and its line names the decider.
    it "walks on past a call the clock denied, and names who decided each" do
      clock_first = lambda do |_question|
        parked.first.deny(surface: "timeout")
        nil
      end
      walking = described_class.new(prompt: Lain::Frontend::ApprovalPolicy.new(output: StringIO.new,
                                                                               reader: clock_first))

      said = walking.call("wrong tree", env_over(parked))

      expect([said, parked.map(&:reason)])
        .to eq([%(bash({"command" => "ls"}): denied (timeout)\nedit_file({}): denied (tty_fault)), [nil, nil, nil]])
    end

    it "keeps a reason the human typed at the prompt over the one /deny was given" do
      answers.push("n not this one")

      deny.call("wrong tree", env_over(parked))

      expect(parked.first.reason).to eq("not this one")
    end
  end

  it "says so when nothing is parked" do
    expect(deny.call("why", env_over(Lain::CLI::Command::Env::NoApprovals))).to eq("no pending approvals")
  end

  # Scenario: /deny with one pending call -- the agent's result carries the reason.
  describe "through the gate a call parked at" do
    let(:queue) { Lain::Approval::Parked::Queue.new(journal: Lain::Journal.new(io: StringIO.new), timeout: 1) }
    let(:gate) { Lain::Middleware::Gate.new(policy: Lain::Approval::Escalation::Surfaces.new(queue)) }
    let(:dangerous) do
      Class.new(Lain::Tool) do
        def name = "dangerous"
        def description = "the dangerous tool"
        def requires_approval? = true
        def input_schema = { type: :object, properties: {}, required: [] }
        def perform(_input, _invocation) = Lain::Tool::Result.ok("ran")
      end.new
    end

    it "tells the agent the call was denied, in the human's words" do
      result = Sync do |task|
        call = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "dangerous", input: {})
        gated = task.async { gate.call({ effect: call, tool: dangerous, context: nil }) { raise "must not run" } }
        task.with_timeout(1) { queue.dequeue }
        deny.call("use lain epic status", env_over(queue))
        task.with_timeout(1) { gated.wait }.fetch(:result)
      end

      expect(result).to eq(Lain::Tool::Result.error('approval denied for tool "dangerous": use lain epic status'))
    end
  end
end

RSpec.describe Lain::CLI::Command::Deny, "typed at the watcher's own [y/N], through the chat's real rail" do
  let(:queue) { Lain::Approval::Parked::Queue.new(journal: Lain::Journal.new(io: StringIO.new), timeout: 30) }
  let(:said) { [] }
  let(:screen) do
    Class.new do
      def initialize(said) = @said = said

      %i[render_held render_note render_human_note close_prompt queue_prompt drop_prompt].each do |told|
        define_method(told) { |text| @said << [told, text.to_s] }
      end
    end.new(said)
  end
  let(:bound) { [nil] }
  let(:rail) do
    Lain::Frontend::Intake.new(screen:, commands: Lain::CLI::Wiring::IntakeBuild::Probe.new(bound: -> { bound.first },
                                                                                            screen:))
  end
  let(:policy) { Lain::Frontend::ApprovalPolicy.new(output: StringIO.new, reader: ->(asked) { rail.read(:approval, asked) }) }
  let(:gate) { Lain::Middleware::Gate.new(policy: Lain::Approval::Escalation::Surfaces.new(queue)) }
  let(:dangerous) do
    Class.new(Lain::Tool) do
      def name = "dangerous"
      def description = "the dangerous tool"
      def requires_approval? = true
      def input_schema = { type: :object, properties: {}, required: [] }
      def perform(_input, _invocation) = Lain::Tool::Result.ok("ran")
    end.new
  end

  before do
    env = instance_double(Lain::CLI::Command::Env, approvals: queue)
    bound[0] = Lain::CLI::Command::Registry.new([described_class.new(prompt: policy)]).bind(env)
  end

  def parked(task, name, id)
    effect = Lain::Effect::ToolCall.new(tool_use_id: id, name:, input: {})
    task.async do
      gate.call({ effect:, tool: dangerous, context: nil }) { |inner| inner.merge(result: Lain::Tool::Result.ok("ran")) }
          .fetch(:result)
    end
  end

  def typed(text) = rail << Lain::Frontend::Intake::Line.new(text:, generation: rail.published.generation)

  def asking_about?(name) = rail.published.kind == :approval && rail.published.text.to_s.include?(name)

  it "gives a bare n at that prompt the /deny reason, announces no prompt twice, and says nothing of what answers it" do
    results = Sync do |task|
      calls = [parked(task, "bash", "tu_1"), parked(task, "edit_file", "tu_2")]
      watcher = task.async { policy.watch(queue) }
      pumped_until(task, reason: "the watcher asking about the first call") { asking_about?("bash") }
      drawn = rail.published.generation
      typed("/deny wrong tree")
      pumped_until(task, reason: "the prompt drawn again") { rail.published.generation > drawn }
      typed("n")
      pumped_until(task, reason: "the second call asked") { asking_about?("edit_file") }
      typed("y")
      calls.map(&:wait).tap { watcher.stop }
    end

    expect([results.map(&:error?), results.first.content]).to match([[true, false], include("wrong tree")])
    expect(said.select { _1.first == :queue_prompt }.map(&:last).grep(/bash/)).to eq([])
    expect(said).not_to include([:render_note, Lain::Frontend::ApprovalPolicy::REFUSED])
  end
end
