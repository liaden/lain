# frozen_string_literal: true

require "async"

# E2's fixtures, kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ToolRunnerSpecSupport
  # Null gate: announcing entry goes nowhere and release never parks, so an
  # ungated probe runs straight through -- no probe ever guards on nil.
  class OpenGate
    def enqueue(_value) = nil
    def dequeue = nil
  end

  # Logs "#{name}:enter" / "#{name}:resolve" around its own dispatch into one
  # shared list, so overlap and barrier ordering are assertions over a single
  # ordered log, never over a clock. Given entered/release queues it also
  # announces entry and parks until released -- the deterministic barrier
  # idiom from spec/lain/tools/parallel_safety_spec.rb. `body` is the
  # observable side effect (the shared-state write/read probes); its return
  # value becomes the result content.
  class ProbeTool < Lain::Tool
    def initialize(name:, safe:, log:, entered: OpenGate.new, release: OpenGate.new, body: nil)
      super()
      @tool_name = name
      @safe = safe
      @log = log
      @entered = entered
      @release = release
      @body = body || -> { @tool_name }
    end

    def name = @tool_name
    def description = "test double: logs dispatch boundaries around an optional gate"
    def input_schema = { type: :object, properties: {} }
    def parallel_safe? = @safe

    protected

    def perform(_input, _context)
      @log << "#{@tool_name}:enter"
      @entered.enqueue(@tool_name)
      @release.dequeue
      value = @body.call
      @log << "#{@tool_name}:resolve"
      Lain::Tool::Result.ok(value)
    end
  end
end

# ToolRunner turns an assistant turn's tool_use blocks into the tool_result
# blocks that answer them. These close the spec-less gap on the collaborator
# directly, rather than only through agent_spec.
RSpec.describe Lain::Agent::ToolRunner do
  # Answers every call with a result naming the id it saw, so order and
  # id-matching are observable in the returned blocks.
  def echoing_handler
    Lain::Effect::Handler::Mock.new do |effect, _context|
      Lain::Tool::Result.ok("ran #{effect.tool_use_id}")
    end
  end

  # Gate 2: all of a turn's tool_results assemble into ONE user message, in the
  # order the tool_use blocks appeared. ToolRunner produces exactly that ordered
  # list; the Agent commits it as a single user turn.
  it "answers every tool_use with an ordered tool_result (gate 2, one user turn)" do
    response = tool_response(
      ["tu_1", "echo", { "text" => "a" }],
      ["tu_2", "echo", { "text" => "b" }]
    )

    blocks = described_class.new(handler: echoing_handler).run(response, context: nil)

    expect(blocks.map { |block| block["type"] }).to eq(%w[tool_result tool_result])
    # Gate 4: each result carries the id of the tool_use that asked for it, order preserved.
    expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
    expect(blocks.map { |block| block["content"] }).to eq(["ran tu_1", "ran tu_2"])
  end

  it "reports a failed tool as is_error rather than raising past the loop (gate 3)" do
    handler = Lain::Effect::Handler::Mock.new do |_effect, _context|
      Lain::Tool::Result.error("boom")
    end
    response = tool_response(["tu_1", "boom", {}])

    block = described_class.new(handler:).run(response, context: nil).first

    expect(block["is_error"]).to be(true)
    expect(block["content"]).to eq("boom")
  end

  # Gate 5: the Provider has already parsed `tool_use.input` into a Hash;
  # ToolRunner fetches it and hands it to the effect verbatim, performing no
  # String -> Hash re-parse of its own. So the effect sees a Hash, never a raw
  # JSON String -- the parsing responsibility stays with the Provider.
  it "passes the parsed Hash input through to the effect, never re-parsing (gate 5)" do
    seen_input = nil
    handler = Lain::Effect::Handler::Mock.new do |effect, _context|
      seen_input = effect.input
      Lain::Tool::Result.ok("ok")
    end
    input = { "text" => "hi" }
    response = tool_response(["tu_1", "echo", input])

    described_class.new(handler:).run(response, context: nil)

    expect(seen_input).to be_a(Hash)
    expect(seen_input).to eq(input)
  end

  it "threads the effect through its middleware phase, terminating in the handler" do
    seen = nil
    probe = Class.new(Lain::Middleware::Base) do
      define_method(:call) do |env, &downstream|
        seen = env
        downstream.call(env)
      end
    end.new
    stack = Lain::Middleware::Stack.new.use(probe)
    response = tool_response(["tu_1", "echo", { "text" => "a" }])

    described_class.new(handler: echoing_handler, middleware: stack).run(response, context: :ctx)

    expect(seen).to be_a(Lain::Middleware::Env)
    expect(seen.effect).to be_a(Lain::Effect::ToolCall)
    expect(seen[:context]).to eq(:ctx)
  end

  # I6: one user-turn delivery = the tool_result blocks PLUS the consumption
  # edges harvested from the toolset -- pinned here at the collaborator's own
  # boundary with consume-once fakes, so the contract does not rest on
  # agent_spec's end-to-end examples alone.
  describe "#delivery" do
    # The real Tools::AskHuman#take_answered_questions shape: hands its
    # digests over exactly once, empty ever after.
    def handover_tool(name, digests)
      fake = Struct.new(:name).new(name)
      queue = digests.dup
      fake.define_singleton_method(:take_answered_questions) do
        handed = queue.dup
        queue.clear
        handed
      end
      fake
    end

    def plain_tool(name) = Struct.new(:name).new(name)

    def runner(*tools)
      described_class.new(handler: echoing_handler, toolset: Lain::Toolset.new(tools))
    end

    it "pairs the tool_result blocks with the harvested digests as causal_parents" do
      subject = runner(plain_tool("echo"), handover_tool("ask_human", ["blake3:q1"]))

      delivery = subject.delivery(tool_response(["tu_1", "ask_human", { "question" => "q?" }]), context: nil)

      expect(delivery.fetch(:content).map { |block| block["tool_use_id"] }).to eq(["tu_1"])
      expect(delivery.fetch(:causal_parents)).to eq(["blake3:q1"])
    end

    it "harvests exactly once: the next delivery cites nothing" do
      subject = runner(handover_tool("ask_human", ["blake3:q1"]))
      subject.delivery(tool_response(["tu_1", "ask_human", { "question" => "q?" }]), context: nil)

      second = subject.delivery(tool_response(["tu_2", "ask_human", { "question" => "again?" }]), context: nil)

      expect(second.fetch(:causal_parents)).to eq([])
    end

    it "collects across every hand-over tool and ignores tools without the message" do
      subject = runner(plain_tool("echo"), handover_tool("ask_a", ["blake3:q1"]),
                       handover_tool("ask_b", ["blake3:q2"]))

      delivery = subject.delivery(tool_response(["tu_1", "echo", {}]), context: nil)

      # Toolset iterates name-sorted, so the collection order is deterministic.
      expect(delivery.fetch(:causal_parents)).to eq(%w[blake3:q1 blake3:q2])
    end

    it "yields causal_parents: [] for a toolset with nothing to hand over (ordinary turns unmoved)" do
      delivery = runner(plain_tool("echo")).delivery(tool_response(["tu_1", "echo", {}]), context: nil)

      expect(delivery.fetch(:causal_parents)).to eq([])
    end

    it "yields causal_parents: [] under the default (empty) toolset" do
      delivery = described_class.new(handler: echoing_handler)
                                .delivery(tool_response(["tu_1", "echo", {}]), context: nil)

      expect(delivery.fetch(:causal_parents)).to eq([])
    end
  end

  # E2: barrier semantics for mixed turns. The turn partitions into maximal
  # CONTIGUOUS runs of parallel-safe tools; each safe run gathers
  # concurrently, and each unsafe tool is a barrier that runs alone --
  # strictly after everything before it, strictly before everything after --
  # so execution order never diverges from the wire order the model saw.
  describe "barrier semantics over contiguous runs" do
    def probe(name, safe:, log:, **options)
      ToolRunnerSpecSupport::ProbeTool.new(name:, safe:, log:, **options)
    end

    def runner_for(*tools)
      described_class.new(handler: Lain::Effect::Handler::Live.new(toolset: Lain::Toolset.new(tools)))
    end

    it "overlaps a leading safe run, runs the barrier alone after it, then the trailing safe tool" do
      entered = Async::Queue.new
      release = Async::Queue.new
      log = []
      runner = runner_for(
        probe("safe_a", safe: true, log:, entered:, release:),
        probe("safe_b", safe: true, log:, entered:, release:),
        probe("unsafe_c", safe: false, log:, entered:, release:),
        probe("safe_d", safe: true, log:, entered:, release:)
      )
      response = tool_response(["tu_1", "safe_a", {}], ["tu_2", "safe_b", {}],
                               ["tu_3", "unsafe_c", {}], ["tu_4", "safe_d", {}])

      Sync do |task|
        run = task.async { runner.run(response, context: nil) }

        # Both leading safe tools are provably mid-dispatch before either
        # resolves. The timeout is a failure bound, never a synchronization:
        # a sequential dispatch parks safe_a on `release` and never enters
        # safe_b, and without the bound that failure would hang, not report.
        overlap = task.with_timeout(1) { [entered.dequeue, entered.dequeue] }
        expect(overlap).to contain_exactly("safe_a", "safe_b")
        release.enqueue(:go)
        release.enqueue(:go)

        # The barrier enters only once BOTH safe results have resolved. The
        # include() guard first: on a regression it fails with a readable
        # diff, where a bare index comparison would raise Integer-vs-nil.
        expect(task.with_timeout(1) { entered.dequeue }).to eq("unsafe_c")
        expect(log).to include("safe_a:resolve", "safe_b:resolve", "unsafe_c:enter")
        barrier_entered = log.index("unsafe_c:enter")
        expect(barrier_entered).to be > log.index("safe_a:resolve")
        expect(barrier_entered).to be > log.index("safe_b:resolve")
        release.enqueue(:go)

        # ...and the trailing safe tool only once the barrier has.
        expect(task.with_timeout(1) { entered.dequeue }).to eq("safe_d")
        expect(log).to include("unsafe_c:resolve", "safe_d:enter")
        expect(log.index("safe_d:enter")).to be > log.index("unsafe_c:resolve")
        release.enqueue(:go)

        blocks = run.wait
        expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2 tu_3 tu_4])
        expect(blocks.map { |block| block["content"] }).to eq(%w[safe_a safe_b unsafe_c safe_d])
      ensure
        run&.stop
      end
    end

    # The pin against the rejected alternative (gather the safe SUBSET first,
    # unsafe remainder after): reordering execution against wire order would
    # run safe_reader BEFORE the barrier's write and observe "safe-wrote" --
    # a silent causal lie. Barrier semantics must observe exactly what full
    # sequential would.
    it "lets a trailing safe tool observe the barrier's write, exactly as sequential would" do
      state = { value: "initial" }
      log = []
      runner = runner_for(
        probe("safe_writer", safe: true, log:, body: -> { state[:value] = "safe-wrote" }),
        probe("unsafe_writer", safe: false, log:, body: -> { state[:value] = "barrier-wrote" }),
        probe("safe_reader", safe: true, log:, body: -> { state[:value] })
      )
      response = tool_response(["tu_1", "safe_writer", {}], ["tu_2", "unsafe_writer", {}],
                               ["tu_3", "safe_reader", {}])

      blocks = runner.run(response, context: nil)

      expect(blocks.map { |block| block["content"] }).to eq(%w[safe-wrote barrier-wrote barrier-wrote])
      # Runs of one gain nothing: this schedule is exactly the sequential one.
      expect(log).to eq(%w[safe_writer:enter safe_writer:resolve
                           unsafe_writer:enter unsafe_writer:resolve
                           safe_reader:enter safe_reader:resolve])
    end

    it "runs a single-tool turn strictly sequentially" do
      log = []
      runner = runner_for(probe("safe_only", safe: true, log:))

      blocks = runner.run(tool_response(["tu_1", "safe_only", {}]), context: nil)

      expect(log).to eq(%w[safe_only:enter safe_only:resolve])
      expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1])
    end

    it "runs an all-unsafe turn strictly sequentially in wire order" do
      log = []
      runner = runner_for(
        probe("unsafe_a", safe: false, log:),
        probe("unsafe_b", safe: false, log:),
        probe("unsafe_c", safe: false, log:)
      )
      response = tool_response(["tu_1", "unsafe_a", {}], ["tu_2", "unsafe_b", {}],
                               ["tu_3", "unsafe_c", {}])

      blocks = runner.run(response, context: nil)

      expect(log).to eq(%w[unsafe_a:enter unsafe_a:resolve unsafe_b:enter unsafe_b:resolve
                           unsafe_c:enter unsafe_c:resolve])
      expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2 tu_3])
    end
  end
end
