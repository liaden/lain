# frozen_string_literal: true

require "async"

# A transparent Store that also keeps the objects it was handed, so a spec can
# inspect the lineage events the children put concurrently (the Store itself
# exposes no enumeration -- deliberately, it is content-addressed storage).
class RecordingStore < Lain::Store
  attr_reader :recorded

  def initialize
    super
    @recorded = []
  end

  def put(object)
    @recorded << object
    super
  end
end

# A child provider whose latency is scripted by the order it is CALLED, so the
# children finish in the reverse of the order they were spawned. The delay is
# taken (with no yield point) before the sleep, so the shift order equals the
# task-creation order == tool_use order; the answer is derived from the child's
# own prompt, so a raced return would name the wrong child's text.
class ReverseOrderProvider < Lain::Provider
  attr_reader :completed

  def initialize(delays:)
    super()
    @delays = delays.dup
    @completed = []
  end

  def complete(request)
    delay = @delays.shift
    prompt = prompt_of(request)
    sleep(delay)
    @completed << prompt
    Lain::Response.new(content: [{ "type" => "text", "text" => "answer-#{prompt}" }],
                       stop_reason: :end_turn)
  end

  private

  def prompt_of(request)
    message = request.messages.find { |m| m["role"] == "user" }
    message["content"].find { |block| block["type"] == "text" }["text"]
  end
end

# A child provider that blocks in-flight until stopped: it records that a call
# STARTED but only records FINISHED past the (cancellable) sleep, so a stop
# mid-fan-out is visible as started-without-finished.
class BlockingProvider < Lain::Provider
  attr_reader :started, :finished

  def initialize
    super
    @started = 0
    @finished = 0
  end

  def complete(_request)
    @started += 1
    sleep(2)
    @finished += 1
    Lain::Response.new(content: [{ "type" => "text", "text" => "unreachable" }], stop_reason: :end_turn)
  end
end

# Async fan-out for subagents (5-1.4). A Subagent is `parallel_safe?`, so when a
# parent's assistant turn names several of them the ToolRunner gathers them
# concurrently -- yet gate 2 is unmoved: every tool_result still lands in ONE
# user message, ordered by tool_use order, whatever order the children finish in.
RSpec.describe "Lain::Tools::Subagent async fan-out" do
  let(:store) { RecordingStore.new }

  def spawn_policy
    Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: %i[read_file])
  end

  def build_subagent(child_provider:, parent:)
    Lain::Tools::Subagent.new(
      provider: child_provider,
      context_factory: -> { Lain::Context.new(model: "child-model", max_tokens: 256) },
      toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new]),
      policy: spawn_policy, parent:, journal: Lain::Channel::Null.instance,
      budget: Lain::Agent::Budget.new, max_depth: 3
    )
  end

  # A parent Agent whose single scripted assistant turn fans `prompts` out as
  # `prompts.size` subagent tool_uses, then settles. Returns the parent Agent
  # (not yet asked) plus the subagent tool.
  def fanout_parent(child_provider:, prompts:)
    parent_agent = nil
    tool = build_subagent(child_provider:, parent: -> { parent_agent.timeline })
    calls = prompts.each_with_index.map { |prompt, i| ["call_#{i}", "subagent", { "prompt" => prompt }] }
    parent_agent = Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: [tool_response(*calls), text_response("parent done")]),
      toolset: Lain::Toolset.new([tool]),
      context: Lain::Context.new(model: "parent", max_tokens: 256),
      timeline: Lain::Timeline.empty(store:)
    )
    [parent_agent, tool]
  end

  # ---- Scenario: out-of-order completion, one turn ---------------------------

  describe "out-of-order completion lands in one ordered user turn" do
    it "gathers every result into ONE user message in tool_use order, however the children finish" do
      prompts = %w[go-1 go-2 go-3]
      child_provider = ReverseOrderProvider.new(delays: [0.06, 0.04, 0.02])
      parent_agent, = fanout_parent(child_provider:, prompts:)

      parent_agent.ask("please spawn")

      turns = parent_agent.timeline.to_a
      expect(turns.map(&:role)).to eq(%w[user assistant user assistant])

      results_turn = turns[2]
      expect(results_turn.role).to eq("user")
      expect(results_turn.content.map { |block| block["type"] }).to eq(%w[tool_result tool_result tool_result])
      # Gate 2 + gate 4: results in tool_use order, each carrying its own id.
      expect(results_turn.content.map { |block| block["tool_use_id"] }).to eq(%w[call_0 call_1 call_2])
      expect(results_turn.content.map { |block| block["content"] })
        .to eq(%w[answer-go-1 answer-go-2 answer-go-3])

      # The children genuinely completed out of order: reverse of spawn order.
      expect(child_provider.completed).to eq(%w[go-3 go-2 go-1])
    end
  end

  # ---- Scenario: cancellation propagates -------------------------------------

  describe "a stop mid-fan-out cancels every child and commits nothing" do
    it "leaves no tool_result turn and finishes no child" do
      child_provider = BlockingProvider.new
      parent_agent, = fanout_parent(child_provider:, prompts: %w[go-1 go-2 go-3])

      Sync do |task|
        run = task.async { parent_agent.ask("please spawn") }
        task.async do
          sleep(0.05)
          parent_agent.budget.interrupt(run)
        end.wait
        run.wait
      end

      # The fan-out started, but the stop landed before any child returned.
      expect(child_provider.started).to be > 0
      expect(child_provider.finished).to eq(0)

      # No partial results committed: only [user, assistant(tool_use)] survive.
      roles = parent_agent.timeline.to_a.map(&:role)
      expect(roles).to eq(%w[user assistant])
      expect(parent_agent.timeline.to_a.none? do |turn|
        turn.content.any? { |block| block["type"] == "tool_result" }
      end).to be(true)
    end
  end

  # ---- Scenario: attribution survives concurrency ----------------------------

  describe "interleaved child events keep their attribution" do
    it "pairs every :message's result with its OWN child's final turn, no torn writes" do
      prompts = %w[go-1 go-2 go-3]
      child_provider = ReverseOrderProvider.new(delays: [0.06, 0.04, 0.02])
      parent_agent, = fanout_parent(child_provider:, prompts:)

      parent_agent.ask("please spawn")

      messages = store.recorded.select { |object| object.respond_to?(:kind) && object.kind == :message }
      expect(messages.size).to eq(3)

      # Each :message names a distinct child final turn, and that turn's own text
      # matches the result the message carries -- the check that would fail if the
      # concurrent spawn path raced @last_child against a sibling's.
      finals = messages.map { |message| message.body.fetch("final") }
      expect(finals.uniq.size).to eq(3)

      messages.each do |message|
        final_turn = store.fetch(message.body.fetch("final"))
        final_text = final_turn.content.find { |block| block["type"] == "text" }["text"]
        expect(message.body.fetch("result")).to eq(final_text)
      end

      results = messages.map { |message| message.body.fetch("result") }
      expect(results.sort).to eq(%w[answer-go-1 answer-go-2 answer-go-3])
    end
  end
end
