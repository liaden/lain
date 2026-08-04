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

  # A7's fixtures. Records what the post-dispatch seam was handed and WHERE it
  # ran -- the Async task, so a spec can pin the observation to the caller's
  # own scope rather than to a gather child. Shares the dispatch log, so
  # ordering against the tools' own boundaries reads off one ordered list.
  class RecordingObserver
    attr_reader :blocks, :names, :tasks

    def initialize(log: [])
      @log = log
      @blocks = []
      @names = []
      @tasks = []
    end

    def observe(block, tool_name)
      @log << "observe:#{block["tool_use_id"]}"
      @blocks << block
      @names << tool_name
      @tasks << Async::Task.current?
    end
  end

  # Fails every observation and remembers what it was offered: containment is
  # per block, so a raising observer must cost the turn neither its results nor
  # the next block's observation.
  class RaisingObserver
    attr_reader :seen

    def initialize
      @seen = []
    end

    def observe(block, _tool_name)
      @seen << block["tool_use_id"]
      raise "observer exploded"
    end
  end

  # Records what it was asked to summarize, so the observer's POLICY can be
  # pinned without a reactor -- whether a fire survives is {Oracle::Eager}'s
  # own question, answered by the examples above and by eager_spec.
  class RecordingEager
    attr_reader :fired

    def initialize
      @fired = []
    end

    def fire(digest, text)
      @fired << [digest, text]
    end
  end

  # An oracle tier whose Promise stays pending until the spec resolves it, so a
  # fire can be watched outliving the turn that spawned it. eager_spec's idiom.
  class PendingOracle
    def initialize
      @promise = Lain::Promise.new
    end

    def ask(_inputs) = @promise
    def resolve(value) = @promise.resolve(value)
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
    # A Struct rather than a Tool subclass because the harvest is the only
    # behaviour under test, but a Toolset digests its members' schemas at
    # construction, so even this fake answers #to_schema -- agent_spec's
    # equivalent hand-over fake does the same, for the same reason.
    def fake_tool(name)
      fake = Struct.new(:name).new(name)
      fake.define_singleton_method(:to_schema) do
        { "name" => name, "description" => "probe", "input_schema" => { "type" => "object" } }
      end
      fake
    end

    # The real Tools::AskHuman#take_answered_questions shape: hands its
    # digests over exactly once, empty ever after.
    def handover_tool(name, digests)
      fake = fake_tool(name)
      queue = digests.dup
      fake.define_singleton_method(:take_answered_questions) do
        handed = queue.dup
        queue.clear
        handed
      end
      fake
    end

    def plain_tool(name) = fake_tool(name)

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

  # A7: the post-dispatch observation seam. An eager summary of a tool result
  # must be spawned where the CALLER's reactor is -- the agent loop's, which
  # lives for the whole run -- and never from inside #gather, whose `Sync`
  # spins up and closes its own reactor whenever no reactor is ambient. Every
  # parallel-safe read tool goes through #gather, and those are exactly the
  # tools whose results are worth summarizing, so the inside-gather mount
  # misses systematically. Worse than a miss: {Oracle::Eager#fire} consumes the
  # digest BEFORE it spawns, so a reaped fire poisons that content's key for
  # the rest of the session.
  describe "post-dispatch observation" do
    # Big enough to clear Summarizing's real byte threshold, and distinct per
    # tool so the two fires do not collapse into one digest.
    def big(name) = "#{name}:#{"x" * 5000}"

    def probe(name, log:) = ToolRunnerSpecSupport::ProbeTool.new(name:, safe: true, log:, body: -> { big(name) })

    # Two parallel-safe tools: this turn is gatherable, so its results come
    # back through the very scope the observation must outlive.
    def gathering_runner(log:, **options)
      described_class.new(
        handler: Lain::Effect::Handler::Live.new(toolset: Lain::Toolset.new([probe("safe_a", log:),
                                                                             probe("safe_b", log:)])),
        **options
      )
    end

    def gathered_response = tool_response(["tu_1", "safe_a", {}], ["tu_2", "safe_b", {}])

    # A bounded spin, never a synchronization: the fire resolves on its own
    # fiber and the timeout only turns "it never did" into a report instead of
    # a hang. Nothing here awaits the fire's task -- that would prove nothing.
    def settle(task, eager, digest)
      task.with_timeout(1) { task.sleep(0.001) while eager.held(digest).nil? }
    end

    it "hands each result to the observer in the caller's own task, after the gather scope closed" do
      log = []
      observer = ToolRunnerSpecSupport::RecordingObserver.new(log:)

      outer = nil
      Sync do |task|
        outer = task
        gathering_runner(log:, observer:).run(gathered_response, context: nil)
      end

      expect(observer.blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
      # The tool NAME rides alongside the block: gate 4 pins the block's four
      # keys, so the name a summarizer routes on cannot live inside it.
      expect(observer.names).to eq(%w[safe_a safe_b])
      expect(log.index("observe:tu_1")).to be > log.index("safe_b:resolve")
      # The observation ran in the CALLER's task, not in a gather child -- which
      # is exactly what lets a fire it spawns outlive the fan-out.
      expect(observer.tasks).to all(be(outer))
    end

    it "keeps a real Oracle::Eager fire alive past the gather scope, resolving after the turn returns" do
      oracle = ToolRunnerSpecSupport::PendingOracle.new
      eager = Lain::Oracle::Eager.new(oracle:)
      digest = Lain::Canonical.digest(big("safe_a"))
      observer = Lain::Effect::Handler::Summarizing::Observer.new(eager:)

      Sync do |task|
        blocks = gathering_runner(log: [], observer:).run(gathered_response, context: nil)

        expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
        expect(eager.held(digest)).to be_nil # still in flight: the turn waited on nothing
        oracle.resolve({ "summary" => "compressed" })
        settle(task, eager, digest)
      end

      expect(eager.held(digest)).to eq({ "summary" => "compressed" })
    end

    # The pin against the inside-gather mount. With no ambient reactor #gather's
    # `Sync` builds one and closes it, so a fire spawned in there is reaped AND
    # its digest stays consumed -- the summary could never be produced again.
    # Firing post-dispatch inherits the caller's (absent) reactor instead, where
    # #fire is a documented no-op that leaves the digest untouched.
    it "leaves the digest unconsumed when no reactor is ambient, so a later fire still runs" do
      oracle = ToolRunnerSpecSupport::PendingOracle.new
      eager = Lain::Oracle::Eager.new(oracle:)
      text = big("safe_a")
      digest = Lain::Canonical.digest(text)
      observer = Lain::Effect::Handler::Summarizing::Observer.new(eager:)

      gathering_runner(log: [], observer:).run(gathered_response, context: nil)
      expect(eager.held(digest)).to be_nil

      Sync do |task|
        eager.fire(digest, text)
        oracle.resolve({ "summary" => "later" })
        settle(task, eager, digest)
      end

      expect(eager.held(digest)).to eq({ "summary" => "later" })
    end

    # `to_h` is last-wins, so two tool_uses sharing an id would route the FIRST
    # block under the SECOND tool's name -- a silent mislabel where the `fetch`
    # beside it was chosen for loudness. Gate 4 is already violated by such a
    # turn; the pairing says so rather than inventing an answer.
    it "refuses two tool_uses sharing one id rather than mislabelling the pairing" do
      observer = ToolRunnerSpecSupport::RecordingObserver.new
      response = tool_response(["dup", "echo", {}], ["dup", "echo", {}])

      expect { described_class.new(handler: echoing_handler, observer:).run(response, context: nil) }
        .to raise_error(described_class::DuplicateToolUse, /two tool_uses share id "dup"/)
    end

    it "summarizes nothing under the default observer, leaving the blocks byte-identical" do
      response = tool_response(["tu_1", "echo", { "text" => "a" }], ["tu_2", "echo", { "text" => "b" }])

      blocks = described_class.new(handler: echoing_handler).run(response, context: nil)

      expect(Lain::Canonical.dump(blocks)).to eq(Lain::Canonical.dump(
                                                   [{ "type" => "tool_result", "tool_use_id" => "tu_1",
                                                      "content" => "ran tu_1", "is_error" => false },
                                                    { "type" => "tool_result", "tool_use_id" => "tu_2",
                                                      "content" => "ran tu_2", "is_error" => false }]
                                                 ))
    end

    it "returns the tool results unchanged when the observer raises, and still offers the next block" do
      observer = ToolRunnerSpecSupport::RaisingObserver.new
      response = tool_response(["tu_1", "echo", {}], ["tu_2", "echo", {}])

      blocks = described_class.new(handler: echoing_handler, observer:).run(response, context: nil)

      expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
      expect(blocks.map { |block| block["content"] }).to eq(["ran tu_1", "ran tu_2"])
      expect(observer.seen).to eq(%w[tu_1 tu_2])
    end

    # The production observer this seam is built for, pinned at its own
    # boundary: which results earn a summary is policy, and it lives with
    # {Effect::Handler::Summarizing}, the decorator that shares the rule.
    # These examples are here rather than beside that class because A7 owns
    # the observer; the chain-mount decorator's own examples are in
    # spec/lain/oracle/eager_spec.rb.
    describe Lain::Effect::Handler::Summarizing::Observer do
      let(:eager) { ToolRunnerSpecSupport::RecordingEager.new }

      def block_for(content, is_error: false)
        { "type" => "tool_result", "tool_use_id" => "tu_1", "content" => content, "is_error" => is_error }
      end

      def observing(content, is_error: false, tool_name: "bash", **options)
        described_class.new(eager:, **options).observe(block_for(content, is_error:), tool_name)
        eager.fired
      end

      def fired_for(content, tool_name: "bash")
        [Lain::Canonical.digest(content), Lain::Summarizer::Result.new(tool_name:, text: content)]
      end

      # The digest stays the content address of the tool's own bytes -- what
      # {Compaction::SummarySnapshot} looks a summary up by -- while the fired
      # VALUE gains the tool name a custom summarizer routes on.
      it "fires a successful String result over the threshold, keyed by its content address" do
        content = "x" * 5000

        expect(observing(content)).to eq([fired_for(content)])
      end

      it "carries the producing tool's name into the fired result" do
        content = "x" * 5000

        expect(observing(content, tool_name: "read_file")).to eq([fired_for(content, tool_name: "read_file")])
      end

      # A3's escalation trigger: this method already no-ops silently on a
      # Symbol-keyed block (a named follow-up). An observation that cannot say
      # WHICH tool ran must not widen that -- routing every result as nameless
      # would silently disable every tool-keyed summarizer -- so the name is a
      # required argument and its absence is an ArgumentError, not a miss.
      it "refuses an observation with no tool name" do
        observer = described_class.new(eager:)

        expect { observer.observe(block_for("x" * 5000)) }.to raise_error(ArgumentError)
      end

      it "declines an error result however large -- a failure is not worth compressing" do
        expect(observing("x" * 5000, is_error: true)).to be_empty
      end

      # Strictly OVER: the threshold names the size a result must exceed.
      it "declines content of exactly the threshold and fires at one byte more" do
        expect(observing("x" * Lain::Effect::Handler::Summarizing::DEFAULT_THRESHOLD_BYTES)).to be_empty
        expect(observing("x" * (Lain::Effect::Handler::Summarizing::DEFAULT_THRESHOLD_BYTES + 1))).not_to be_empty
      end

      it "declines content well below the threshold" do
        expect(observing("small")).to be_empty
      end

      # Array content is structured blocks, not free text: there is nothing for
      # a prose summarizer to compress.
      it "declines structured block (Array) content" do
        expect(observing([{ "type" => "text", "text" => "x" * 5000 }])).to be_empty
      end

      it "honours an injected threshold_bytes" do
        expect(observing("small", threshold_bytes: 2)).to eq([fired_for("small")])
      end
    end
  end
end
