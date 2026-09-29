# frozen_string_literal: true

require "async"
require "fileutils"
require "json"
require "monitor"
require "stringio"
require "tmpdir"
require "timeout"

# A REAL isolation backend, small enough to live beside the examples that drive
# it: every acquire provisions an actual directory named for the worker and
# hands back a lease whose cwd points there, and release removes it. Not a
# stand-in for the duck -- a child dispatched under one of these leases really
# does resolve its relative paths inside that directory, which is what makes
# "the grandchild ran somewhere else" an assertion rather than string math over
# a path nothing ever used. {Lain::Isolation::Worktree} is the concrete backend,
# and spec/lain/cli/wiring_spec.rb drives THAT one end to end through the real
# `--isolation` wiring; it costs five git subprocesses per lease, where what
# these examples are about is the lease LIFECYCLE.
#
# It keeps Worktree's one-live-lease-per-path refusal, so a worker-id allocator
# that handed two live spawns one id fails as loudly here as it would there.
class SubagentSpecIsolation
  attr_reader :worker_ids, :leased, :released

  # `reclaim: :refuse` is {Lain::Isolation::Worktree}'s real teardown failure:
  # `#remove` raises rather than leave a checkout it could not reclaim standing.
  def initialize(root, reclaim: :succeed)
    @root = root
    @reclaim = reclaim
    @worker_ids = []
    @leased = []
    @released = []
    @live = []
    @monitor = Monitor.new
  end

  def acquire(worker_id)
    path = File.join(@root, worker_id.to_s)
    @monitor.synchronize do
      raise Lain::Error, "#{path} is already leased" if @live.include?(path)

      claim(path, worker_id)
    end
    Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default.with(cwd: path),
                               on_release: -> { give_back(path) })
  end

  private

  def claim(path, worker_id)
    FileUtils.mkdir_p(path)
    @live << path
    @worker_ids << worker_id.to_s
    @leased << path
  end

  def give_back(path)
    @monitor.synchronize do
      @live.delete(path)
      raise Lain::Error, "could not reclaim #{path}" if @reclaim == :refuse

      @released << path
    end
  end
end

# A provider that refuses every prompt whole for not fitting the context it
# loaded, raising it the way any provider does: the figures ride the
# {Lain::WindowExceeded} duck and the MESSAGE is the server's own body. That
# body is the point -- it is what a spawner must never be handed in place of
# words it can act on.
class SubagentSpecRefusingProvider < Lain::Provider::Mock
  BODY = '{"error":"model requires more system memory than is available"}'

  class Refusal < Lain::Error
    include Lain::WindowExceeded
  end

  def complete(_request, **)
    raise Refusal.new(BODY, prompt_tokens: 41_000, window_tokens: 32_768, source: "ollama")
  end
end

# Reports the working directory of the Session it was dispatched under, and
# records every one it saw. A child's cwd is otherwise unobservable from
# outside: a spawn hands back a Timeline, never the Agent, so where a GRANDchild
# ran has to be asked from inside its own dispatch.
class SubagentSpecCwdTool < Lain::Tool
  def initialize(seen)
    super()
    @seen = seen
  end

  def name = "cwd"
  def description = "Reports the directory this session resolves relative paths against."
  def input_schema = { type: :object, properties: {} }

  def perform(_input, invocation)
    session_of(invocation).worker_env.cwd.tap { |cwd| @seen << cwd }.then { |cwd| Lain::Tool::Result.ok(cwd) }
  end
end

# A tool guard that records the name of every call it is handed and passes it
# on, so an example can see which tools really ran behind it.
class SubagentSpecToolGuard < Lain::Middleware::Base
  attr_reader :seen

  def initialize
    super
    @seen = []
  end

  def call(env, &app)
    @seen << env.fetch(:effect).name
    downstream(env, &app)
  end
end

# The handoff duck a lease ends in, recorded: which of the two completions ran,
# for which worker, and whether the lease was still live when it did -- the
# handback has nothing to read from a checkout that is already gone. It
# releases, as every real handoff does on its way out.
class SubagentSpecHandoff
  attr_reader :calls

  def initialize(report:, calls: [])
    @report = report
    @calls = calls
  end

  def reclaim(lease, worker_id:, sync: nil) = completed(:reclaim, lease, worker_id, sync)
  def surrender(lease, worker_id:, sync: nil) = completed(:surrender, lease, worker_id, sync)

  # What each completion was told the sync did, in call order.
  def synced = @synced ||= []

  private

  def completed(way, lease, worker_id, sync)
    @calls << [way, worker_id, lease.released?]
    synced << sync
    lease.release
    @report
  end
end

# The self-sync duck, recorded into the same log as the handoff so the ORDER
# of the two is the assertion. It asks a worker it may ask, which is what
# proves the child is still live when the sync runs, and it tags the
# environment it is asked to make editorless.
class SubagentSpecSync
  attr_reader :replies

  def initialize(calls)
    @calls = calls
    @replies = []
  end

  def call(lease, worker:, worker_id:)
    @calls << [:sync, worker_id, lease.released?, worker.askable?]
    @replies << worker.ask("rebase, please").text if worker.askable?
    result
  end

  # What this sync answers, so a spec can see it arrive at the handoff.
  def result = @result ||= Lain::Isolation::SelfSync::Result.new(outcome: :current)

  def editorless(worker_env) = worker_env.with(env: worker_env.env.merge("GIT_EDITOR" => "true"))
end

# A stand-in named for the one tool that lets a child run git: whether a
# worker may be asked to rebase turns on the NAME it was granted, never on
# what the tool does, so this one does nothing.
class SubagentSpecShell < Lain::Tool
  def name = "bash"
  def description = "Stands in for a shell."
  def input_schema = { type: :object, properties: {} }
  def perform(_input, _invocation) = Lain::Tool::Result.ok("")
end

# Reports the GIT_EDITOR of the environment its Session was dispatched under.
class SubagentSpecEditorTool < Lain::Tool
  def initialize(seen)
    super()
    @seen = seen
  end

  def name = "editor"
  def description = "Reports the git editor this session's commands would open."
  def input_schema = { type: :object, properties: {} }

  def perform(_input, invocation)
    @seen << session_of(invocation).worker_env.env["GIT_EDITOR"]
    Lain::Tool::Result.ok("reported")
  end
end

RSpec.describe Lain::Tools::Subagent do
  # A shared Store, and a two-turn parent chain whose head is H.
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end

  # The union the child attenuates from: an allowed tool (read_file) and a
  # disallowed one (echo). `only(:read_file)` is the attenuation under test.
  let(:union) { Lain::Toolset.new([Lain::Tools::ReadFile.new, EchoTool.new]) }
  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

  # What a spawn left behind, watched through the seam's own `observer:` --
  # the outward slot the live session scribe attaches to, so an example reads
  # exactly what production reads. One per example unless an example builds
  # two tools and must tell their records apart.
  let(:record) { SpawnRecord.new }

  def spawn_policy(prefix: :fresh, posture: :schema, only: %i[read_file], unattended: false)
    Lain::Tool::SpawnPolicy.new(prefix:, posture:, only:, unattended:)
  end

  # `**seam` forwards the loose seam members a spawn is adopted over -- the
  # gating pair, in practice -- so an example can wire one without restating the
  # six collaborators every other example shares.
  def build_subagent(provider:, policy: spawn_policy, parent: self.parent,
                     journal: Lain::Channel::Null.instance, max_depth: 3, toolset: union,
                     tool_middleware: ToolRegistry::UNGUARDED, observer: record, **seam)
    described_class.new(
      provider:, context_factory: -> { child_context }, toolset:, policy:,
      parent:, journal:, budget: Lain::Agent::Budget.new, max_depth:, tool_middleware:, observer:, **seam
    )
  end

  def mock(*responses)
    Lain::Provider::Mock.new(responses:)
  end

  # Every child now holds an `ask_human` of its OWN, granted at the spawn
  # rather than inherited from the union it attenuates from -- so a rendered
  # tools block is the set under test PLUS that one, in {Toolset}'s sorted
  # order. Said once here, because the alternative is nine call sites each
  # restating a capability none of them is about.
  def with_asker(*names) = (names.flatten + %w[ask_human]).sort

  # The through-the-loop shape: a real parent Agent whose toolset holds the
  # subagent, late-bound through a thunk (the toolset is built before the
  # Agent, exactly the exe wiring). Returns [tool, parent_agent], settled.
  def loop_driven(child_provider:)
    parent_agent = nil
    tool = build_subagent(provider: child_provider, parent: -> { parent_agent.timeline })
    parent_agent = loop_parent(tool)
    parent_agent.ask("please spawn")
    [tool, parent_agent]
  end

  def loop_parent(tool)
    Lain::Agent.new(
      provider: mock(tool_response(["call_1", "subagent", { "prompt" => "go" }]), text_response("parent done")),
      toolset: Lain::Toolset.new([tool]),
      context: Lain::Context.new(model: "parent", max_tokens: 256),
      timeline: Lain::Timeline.empty(store:)
    )
  end

  it "has a model-facing name and description" do
    tool = build_subagent(provider: mock(text_response))
    expect(tool.name).to eq("subagent")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  # Retiring an actor rebases its work first, and a conflict is put to the
  # actor itself -- which only an actor holding a shell could act on.
  describe "the worker a launched actor offers its self-sync" do
    def actor_over(provider, tools)
      build_subagent(provider:, policy: spawn_policy(only: []), toolset: Lain::Toolset.new(tools), mode: :actor)
    end

    it "requires the environment its actor runs in, so none defaults to the process's own directory" do
      expect { actor_over(mock(text_response("ready")), [EchoTool.new]).launch_actor("go") }
        .to raise_error(ArgumentError, /worker_env/)
    end

    it "is the actor's own child when it was granted a shell, and nobody otherwise" do
      # Stopped from the `ensure`: a parked actor keeps the Sync open, so a
      # failed expectation would otherwise hang rather than fail.
      Sync do
        provider = mock(text_response("ready"))
        with_shell = actor_over(provider, [SubagentSpecShell.new]).launch_actor("go", worker_env: Lain::WorkerEnv.default)
        without = actor_over(mock(text_response("ready")), [EchoTool.new]).launch_actor("go", worker_env: Lain::WorkerEnv.default)

        expect(without.worker.askable?).to be(false)
        expect(with_shell.worker.askable?).to be(true)
        with_shell.worker.ask("rebase your work")
        expect(provider.call_count).to eq(2)
      ensure
        [with_shell, without].compact.each(&:stop)
      end
    end
  end

  # ---- Scenario: fresh root over the shared Store (5-1.1) --------------------

  describe "fresh-root spawn" do
    it "gives the child no parent turn, an empty meet, and a :spawn event with a causal edge to H" do
      tool = build_subagent(provider: mock(text_response("did the thing")))
      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok

      child = record.child(store)
      expect(child.include?(parent.head_digest)).to be(false)
      expect(Lain::Dag::RenderAncestry.meet(child, parent)).to be_empty

      spawn = record.spawn
      expect(spawn.kind).to eq(:spawn)
      expect(spawn.causal_parents).to include(parent.head_digest)
    end

    # The Journal is the experiment record, so the recorded spawn has to
    # DETERMINE the child's toolset -- and `unattended` is the fourth thing the
    # policy decides. Written only when true, riding `lifecycle`'s conditional
    # shape, so every attended spawn's bytes and every digest already derived
    # from them are unchanged.
    it "journals the unattended declaration, and omits the key entirely when attended" do
      # A record each, since the claim is that two spawns wrote DIFFERENT
      # bytes: one shared observer would leave only the second's.
      attended_record = SpawnRecord.new
      build_subagent(provider: mock(text_response("done")), observer: attended_record)
        .call({ "prompt" => "go" }, invocation)

      build_subagent(provider: mock(text_response("done")),
                     policy: spawn_policy(unattended: true)).call({ "prompt" => "go" }, invocation)

      expect(attended_record.spawn.body).not_to have_key("unattended")
      expect(record.spawn.body).to include("unattended" => true)
      expect(record.spawn.body.fetch("only")).to eq(%w[read_file])
    end
  end

  # ---- Scenario: the return is an ordinary tool_result (5-1.1) ---------------

  describe "the child's result comes back as a tool_result" do
    # The `lifecycle` expectation rides HERE rather than in a dispatch of its
    # own: the completion is written on the real dispatch path, and what the
    # mark has to cost the parent is nothing -- so the pin belongs beside the
    # result it must not have disturbed.
    it "returns the final text, marked terminal, and names the :spawn and F among its causal parents" do
      tool = build_subagent(provider: mock(text_response("child answer")))
      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok
      expect(result.content).to eq("child answer")

      final = record.child(store).head_digest
      message = record.message
      expect(message.kind).to eq(:message)
      expect(message.body.fetch("lifecycle")).to eq(Lain::StatusFeed::SpawnLifecycle::STOPPED)
      expect(message.causal_parents).to include(record.spawn.digest)
      expect(message.causal_parents).to include(final)
    end

    # Gate 2 survives a real nested spawn: the parent Agent, running the subagent
    # as an ordinary tool, still lands the child's result in ONE user turn.
    it "lands in a single parent user turn when driven through the parent's loop (gate 2 intact)" do
      _tool, parent_agent = loop_driven(child_provider: mock(text_response("child answer")))

      turns = parent_agent.timeline.to_a
      expect(turns.map(&:role)).to eq(%w[user assistant user assistant])
      results_turn = turns[2]
      expect(results_turn.content.map { |b| b["type"] }).to eq(%w[tool_result])
      expect(results_turn.content.first["content"]).to eq("child answer")
      expect(results_turn.content.first["is_error"]).to be(false)
    end
  end

  # A child that raised or was stopped still ends its spawn on the record. The
  # fleet, the windows and a watch retire a spawn only on a completion, so a
  # spawn whose child never answered used to stay running for the rest of the
  # session.
  describe "a one-shot child that does not finish" do
    let(:failed) { Lain::StatusFeed::SpawnLifecycle::FAILED }

    # Asks for a tool it was never granted on every turn, so only the ceiling
    # ends it.
    def looping_child = mock(tool_response(["e1", "echo", { "text" => "again" }]))

    def dispatched_by_parent(provider: looping_child, observer: record, **seam)
      parent_agent = nil
      tool = described_class.new(provider:, context_factory: -> { child_context }, toolset: union,
                                 policy: spawn_policy, parent: -> { parent_agent.timeline },
                                 budget: Lain::Agent::Budget.new(max_iterations: 2), max_depth: 3,
                                 tool_middleware: ToolRegistry::UNGUARDED, observer:, **seam)
      parent_agent = loop_parent(tool)
      parent_agent.ask("please spawn")
      parent_agent.timeline.to_a[2].content.first
    end

    def published_fleet(events = record.events)
      Dir.mktmpdir do |dir|
        feed = Lain::StatusFeed.new(path: File.join(dir, "state.json"))
        events.each { |event| feed << event }
        feed.state.fetch("fleet")
      end
    end

    # A session record that takes the spawn and refuses the completion: a
    # closed journal, or a live-view sink raising after the file leg landed.
    def refusing_completions
      lambda do |event|
        raise IOError, "the journal is closed" if event.kind == :message

        record.call(event)
      end
    end

    it "journals the lost completion, naming the spawn and the error class, and the fleet still retires it" do
      telemetry = Lain::Channel.new

      dispatched_by_parent(observer: refusing_completions, telemetry:)

      lost = telemetry.drain.grep(Lain::Tools::Subagent::Lineage::EndingNotRecorded)
      expect(lost.map(&:to_h)).to eq([{ spawn: record.spawn.digest, record: "completion",
                                        lifecycle: failed, error: "IOError" }])
      expect(published_fleet(record.events + lost)).to eq([])
    end

    # The second stop lands while the stopped completion is being written, and
    # the write suspends -- a contended monitor, a scheduler-routed write.
    it "writes a stopped completion though a second stop lands during its write" do
      entered = false
      slow = lambda do |event|
        if event.kind == :message
          entered = true
          sleep 0.2
        end
        record.call(event)
      end
      parked = Class.new(Lain::Provider::Mock) { def complete(*) = sleep }
      tool = described_class.new(provider: parked.new(responses: []), context_factory: -> { child_context },
                                 toolset: union, policy: spawn_policy, parent:, observer: slow,
                                 tool_middleware: ToolRegistry::UNGUARDED)

      Sync do |task|
        run = task.async { tool.run("go") }
        task.sleep(0.05)
        run.stop
        pumped_until(task, timeout: 2) { entered }
        run.stop
        task.sleep(0.4)
      end

      expect(record.messages.map { |message| message.body.fetch("lifecycle") }).to eq(["stopped"])
    end

    it "hands the parent an error result and journals a failed completion naming the error and the child's head" do
      result = dispatched_by_parent

      expect(result["is_error"]).to be(true)
      body = record.message.body
      expect(body).to include("lifecycle" => failed, "error" => "Lain::Agent::Budget::Exceeded")
      expect(body).not_to have_key("result")
      child = Lain::Timeline.new(head_digest: body.fetch("final"), store:)
      expect(child.to_a.first.content.first["text"]).to eq("go")
      expect(record.message.causal_parents).to contain_exactly(record.spawn.digest, child.head_digest)
    end

    it "retires the spawn from the fleet the HUD publishes" do
      dispatched_by_parent

      expect(record.spawns.size).to eq(1)
      expect(published_fleet).to eq([])
    end

    # A child whose only output was a tool call written as prose. Its provider
    # is the real ollama decode over a scripted socket, so the reading travels
    # the production road: decode -> the child's own loop -> this tool.
    context "when its only output was a tool call the model wrote as prose" do
      let(:envelope) { "<function=bash>\n<parameter=command>\nls\n</parameter>\n</function>" }

      def prose_child = Lain::Provider::Ollama.new(transport: OllamaWire.queue_transport([text_response(envelope)]))

      def fleet_rows
        Dir.mktmpdir do |dir|
          feed = Lain::StatusFeed.new(path: File.join(dir, "state.json"))
          record.events.each { |event| feed << event }
          feed.state.fetch("fleet_tree")
        end
      end

      it "does not answer its parent: the completion carries failed and no result" do
        result = dispatched_by_parent(provider: prose_child)

        expect(result["is_error"]).to be(true)
        expect(result["content"].to_s).not_to include("<function=bash>")
        expect(record.message.body).to include("lifecycle" => failed,
                                               "error" => "Lain::Tools::Subagent::MalformedAnswer")
        expect(record.message.body).not_to have_key("result")
      end

      it "is rendered failed on the fleet surface" do
        dispatched_by_parent(provider: prose_child)

        expect(fleet_rows.map { |row| row["state"] }).to eq(["failed"])
      end

      it "tells the parent WHICH reading it was, so the diagnostic can be checked against the turn" do
        result = dispatched_by_parent(provider: prose_child)

        expect(result["content"].to_s).to include("tool call written as prose")
      end
    end

    # The provider reads a turn that said NOTHING as malformed too, and it
    # reaches this tool by the same road. The refusal is right; naming it a
    # prose tool call would not be, and on a bench whose deliverable is
    # observability a diagnostic pointing at the wrong failure is worse than
    # none.
    context "when it answered nothing at all" do
      def silent_child
        Lain::Provider::Ollama.new(transport: OllamaWire.queue_transport([text_response("")]))
      end

      it "does not answer its parent, and says the child said nothing rather than naming a prose call" do
        result = dispatched_by_parent(provider: silent_child)

        expect(result["is_error"]).to be(true)
        expect(result["content"].to_s).to include("said nothing at all")
        expect(result["content"].to_s).not_to include("written as prose")
        expect(record.message.body).to include("lifecycle" => failed,
                                               "error" => "Lain::Tools::Subagent::MalformedAnswer")
      end
    end

    # A request refused before the child's first answer leaves a head no
    # iteration returned to write, and the completion cites it.
    it "settles the head of a child that failed before its first answer into the record ahead of the completion" do
      dispatched_by_parent(provider: mock)

      final = record.message.body.fetch("final")
      expect(record.events.index { |event| event.digest == final })
        .to be < record.events.index(record.message)
    end

    it "names no head for a child that was never built" do
      tool = described_class.new(provider: mock, context_factory: -> { raise "this child gets no context" },
                                 toolset: union, policy: spawn_policy, parent:, observer: record,
                                 tool_middleware: ToolRegistry::UNGUARDED)

      expect { tool.run("go") }.to raise_error("this child gets no context")
      expect(record.message.body).to eq("lifecycle" => failed, "error" => "RuntimeError")
      expect(record.message.causal_parents).to eq([record.spawn.digest])
    end

    it "writes no spawn when the lease is refused, and hands the parent the refusal" do
      refusing = Class.new { def acquire(_worker_id) = raise(Lain::Error, "no checkout for this worker") }.new

      result = dispatched_by_parent(isolation: Lain::Isolation::Leases.new(backend: refusing))

      expect(result).to include("is_error" => true, "content" => "no checkout for this worker")
      expect(record.spawns).to be_empty
      expect(record.messages).to be_empty
    end
  end

  # ---- Scenario: an answer too large for the parent's context ---------------
  #
  # A parent cannot drop a tool_result, so ONE oversized child answer pins its
  # occupancy with nothing compactable underneath it -- the mechanism behind a
  # live finding of a context at ~100% with an empty compactable head. The
  # ruling is neither truncation nor refusal: the child summarizes its OWN
  # answer, which is cheap because its context already holds it.

  describe "a child answer over the ceiling" do
    let(:ceiling) { Lain::Tools::Subagent::ANSWER_BOUND.limit }
    let(:oversized) { "narration " * ((ceiling / 10) + 1) }

    it "returns an ordinary answer as it was, asking the child nothing further" do
      provider = mock(text_response("child answer"))

      result = build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      expect(result.content).to eq("child answer")
      expect(provider.call_count).to eq(1)
    end

    # The SAME child, not a fresh spawn: the summarizing ask lands as a second
    # user turn on the child's own Timeline, which is what makes it cheap.
    it "comes back shorter, summarized by that same child" do
      provider = mock(text_response(oversized), text_response("the short version"))
      tool = build_subagent(provider:)

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok
      expect(result.content).to include("the short version")
      expect(result.content.bytesize).to be < oversized.bytesize
      # Two provider calls is a property of THIS provider, not of production:
      # `ask` is a whole agentic run, and a child with tools spends as many
      # calls as its loop takes. What the tool guarantees is one further ASK.
      expect(provider.call_count).to eq(2)
      expect(record.child(store).to_a.map(&:role)).to eq(%w[user assistant user assistant])
    end

    it "tells the parent it is reading a summary, naming the size and the ceiling" do
      provider = mock(text_response(oversized), text_response("the short version"))

      result = build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      expect(result.content).to match(/summar/i)
      expect(result.content).to include(oversized.bytesize.to_s)
      expect(result.content).to include(ceiling.to_s)
    end

    # The floor: a child that will not shrink is not asked a third time, and
    # what the parent gets DISCLOSES -- it names the size and the ceiling and
    # offers a narrower move -- rather than carrying a silent prefix of the
    # payload.
    it "answers without asking again when the summary is itself over the ceiling" do
      provider = mock(text_response(oversized), text_response(oversized))

      result = build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      expect(provider.call_count).to eq(2)
      expect(result.content.bytesize).to be < ceiling
      expect(result.content).to include(ceiling.to_s)
      expect(result.content).not_to include("narration narration")
    end

    # The actor path is the one with no ceiling at all today: `reply` puts the
    # child's whole answer into a note that {Context::Mailbox} folds straight
    # into the parent's render, so it is bounded on the same rule.
    it "bounds an actor's oversized reply the same way before it folds into the parent" do
      log = Lain::Tools::Subagent::Log.new
      tool = described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider: mock(text_response(oversized), text_response("the short version")),
        context_factory: -> { child_context }, toolset: union, policy: spawn_policy,
        parent:, mode: :actor, log:
      )

      Sync do
        actor = tool.launch_actor("go", worker_env: Lain::WorkerEnv.default)
        actor.settle
        actor.stop
      end

      settled = log.to_a.find { |event| event.body["lifecycle"] == "settled" }
      expect(settled.body.fetch("text")).to include("the short version")
      expect(settled.body.fetch("text")).to match(/summar/i)
      expect(settled.body.fetch("text").bytesize).to be < oversized.bytesize
    end

    # The summarizing ask is a real model call on the child, so the child's own
    # ceilings can refuse it. Losing an answer already paid for is the outcome
    # this must not have: the parent is answered, and told why it is short.
    it "still answers the parent when the child's budget refuses the summarizing ask" do
      child = instance_double(Lain::Agent)
      allow(child).to receive(:ask).and_raise(Lain::Agent::Budget::Exceeded, "loop ran 25 iterations")
      response = Lain::Response.new(content: [{ "type" => "text", "text" => oversized }], stop_reason: :end_turn)

      bounded = Lain::Tools::Subagent::Answer.new.bounded(child, response)

      expect(bounded.text).to include(ceiling.to_s)
      expect(bounded.text).to include("loop ran 25 iterations")
      expect(bounded.text.bytesize).to be < ceiling
    end

    # A provider that answers once and then fails, which is what a 429, a 529 or
    # a socket reset looks like from inside the summarizing ask. The first
    # answer was already paid for: a transient blip on the second call must not
    # be able to destroy it.
    def failing_second_call(*responses)
      mock(*responses).tap do |provider|
        calls = 0
        allow(provider).to receive(:complete).and_wrap_original do |original, *args, **kwargs|
          calls += 1
          raise Lain::Error, "529 overloaded" if calls > 1

          original.call(*args, **kwargs)
        end
      end
    end

    # Without the floor this raises past `remember`: no :message is written, and
    # the parent is handed an error instead of work the child had finished.
    it "floors rather than raising when the summarizing ask fails, keeping the spawn's record" do
      tool = build_subagent(provider: failing_second_call(text_response(oversized)))

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok
      expect(result.content).to include("529 overloaded")
      expect(result.content).to include(ceiling.to_s)
      expect(record.message.kind).to eq(:message)
      expect(record.message.body.fetch("result")).to eq(result.content)
    end

    # The same failure on the actor path used to end the fiber with nothing
    # settled at all -- `process` raised, `run` stored it as `@failure`, and the
    # parent's mailbox saw a launch and then a farewell.
    it "keeps an actor's answer when its summarizing ask fails, and leaves it alive to settle" do
      log = Lain::Tools::Subagent::Log.new
      tool = described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider: failing_second_call(text_response(oversized)),
        context_factory: -> { child_context }, toolset: union, policy: spawn_policy,
        parent:, mode: :actor, log:
      )

      Sync do
        actor = tool.launch_actor("go", worker_env: Lain::WorkerEnv.default)
        actor.settle
        actor.stop
      end

      settled = log.to_a.find { |event| event.body["lifecycle"] == "settled" }
      expect(settled.body.fetch("text")).to include("529 overloaded")
      expect(settled.body.fetch("text")).to include(ceiling.to_s)
    end

    # Zero bytes fits any ceiling, so the naive size check delivers the note and
    # nothing under it -- a disclosure promising a summary that is not there,
    # which is worse than the floor it skipped. A child that settled `:refusal`
    # is re-askable, so this is live rather than theoretical.
    it "floors an empty summary rather than delivering a note with nothing under it" do
      provider = mock(text_response(oversized), text_response(""))

      result = build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      expect(result.content).not_to include("summarized by the subagent itself")
      expect(result.content).to include("it answered nothing when asked")
      expect(result.content).to include(ceiling.to_s)
    end

    # The card's own criterion: the floor must not be a silent truncation. A
    # summary cut off at the model's token ceiling is exactly that, and only
    # `stop_reason` can tell it apart from a short answer.
    it "floors a summary the model cut off at :max_tokens instead of labelling it a summary" do
      provider = mock(text_response(oversized), text_response("half a sen", stop_reason: :max_tokens))

      result = build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      expect(result.content).not_to include("half a sen")
      expect(result.content).to include("token ceiling")
      expect(result.content).to include(ceiling.to_s)
    end

    # A real Response, not a stand-in that answers only `text`: the members a
    # reader of the record needs survive, and the value stays shareable, which
    # a bare Data carrying an interpolated String does not.
    it "delivers the child's own Response, shareable, with its other members intact" do
      child = instance_double(Lain::Agent)
      allow(child).to receive(:ask).and_return(text_response("the short version"))
      answered = text_response(oversized, model: "child-model", id: "msg_1")

      bounded = Lain::Tools::Subagent::Answer.new.bounded(child, answered)

      expect(bounded).to be_a(Lain::Response)
      expect(Ractor.shareable?(bounded)).to be(true)
      expect(bounded.model).to eq("child-model")
      expect(bounded.id).to eq("msg_1")
      expect(bounded.text).to include("the short version")
    end

    # The bench's deliverable is that strategies be swappable, OBSERVABLE and
    # comparable. Without this record an operator has two blind channels -- a
    # silent journal and an `is_error` of false -- and the only signal left is
    # English inside a result meant for the model.
    it "journals the bounding decision, and which way it went" do
      journal = Lain::Channel.new
      build_subagent(provider: mock(text_response(oversized), text_response("short")),
                     journal:).call({ "prompt" => "go" }, invocation)
      summarized = journal.drain.map(&:to_journal).find { |row| row["type"] == "answer_bounded" }

      floored = Lain::Channel.new
      build_subagent(provider: mock(text_response(oversized), text_response("")),
                     journal: floored).call({ "prompt" => "go" }, invocation)
      floor = floored.drain.map(&:to_journal).find { |row| row["type"] == "answer_bounded" }

      expect(summarized).to include("outcome" => "summarized", "limit" => ceiling,
                                    "size" => oversized.bytesize, "reason" => "")
      expect(floor).to include("outcome" => "floor", "reason" => "it answered nothing when asked")
    end

    # The ceiling is injectable, and the injection has to REACH the two places a
    # spawn actually happens -- a descended copy and a launched actor -- or the
    # seam reads as tested while only the constructor is.
    it "hands an injected ceiling to a descended child and to an actor it launches" do
      log = Lain::Tools::Subagent::Log.new
      tool = described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider: mock(text_response("an answer well over eight bytes")),
        context_factory: -> { child_context }, toolset: union, policy: spawn_policy,
        parent:, log:, answer: Lain::Tools::Subagent::Answer.new(bounds: Lain::Tool::Bounds::Artifact.new(limit: 8))
      )

      expect(tool.run("go").content).to include("over the ceiling of 8")
      descended = tool.descend(parent:, escalation: [], ceiling: 1)
      expect(descended.run("go").content).to include("over the ceiling of 8")

      Sync do
        actor = tool.launch_actor("go", worker_env: Lain::WorkerEnv.default)
        actor.settle
        actor.stop
      end

      settled = log.to_a.find { |event| event.body["lifecycle"] == "settled" }
      expect(settled.body.fetch("text")).to include("over the ceiling of 8")
    end

    # A refusal is not a summary. `stop_reason` survives on the returned
    # Response so a reader can recover the truth, but the LABEL is the part the
    # model reads, and "[summarized by the subagent itself]\nI decline." tells
    # it the decline is the answer it asked for.
    it "floors a summary the child refused instead of labelling the refusal a summary" do
      provider = mock(text_response(oversized), text_response("I decline.", stop_reason: :refusal))

      result = build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      expect(result.content).not_to include("summarized by the subagent itself")
      expect(result.content).to include("declined")
      expect(result.content).to include(ceiling.to_s)
    end

    # The same reason, for a summary the child wrote as a prose tool call: its
    # provider reads it as malformed, and an envelope labelled a summary hands
    # the parent a call as though it were the child's findings.
    it "floors a summary the child wrote as a prose tool call" do
      envelope = "<function=bash>\n<parameter=command>\nls\n</parameter>\n</function>"
      transport = OllamaWire.queue_transport([text_response(oversized), text_response(envelope)])

      result = build_subagent(provider: Lain::Provider::Ollama.new(transport:)).call({ "prompt" => "go" }, invocation)

      expect(result.content).not_to include("summarized by the subagent itself")
      expect(result.content).not_to include("<function=bash>")
      expect(result.content).to include("a tool call written as prose")
    end

    # An exception message is unbounded, and it rides into BOTH the model-facing
    # floor and an NDJSON journal line: a provider error carrying a response
    # body, a `JSON::ParserError` echoing its document, a `NoMethodError`
    # inspecting a large receiver. Unclamped, the sentence built to withhold
    # oversized bytes carries them itself -- through `subject:`, which
    # {Lain::Tool::Bounds} states is prose by design and deliberately unpoliced.
    it "clamps a failure's own message, so the floor cannot blow through the ceiling it enforces" do
      journal = Lain::Channel.new
      child = instance_double(Lain::Agent)
      allow(child).to receive(:ask).and_raise(Lain::Error, "response body: #{"x" * 60_000}")

      bounded = Lain::Tools::Subagent::Answer.new.bounded(child, text_response(oversized), journal:)

      expect(Lain::Tools::Subagent::ANSWER_BOUND.admits?(bounded.text.bytesize)).to be(true)
      expect(bounded.text).to include("Lain::Error")
      expect(journal.drain.map(&:to_journal).last.fetch("reason").bytesize).to be < 1024
    end
  end

  # ---- Provenance at correlation grain (panel ruling) -------------------------

  describe "provenance at correlation grain" do
    # Ruling (review panel): the parent's rendered tool_result turn keeps
    # causal_parents [] -- ToolRunner and Timeline#commit stay out of this card.
    # The child is reachable at CORRELATION grain instead: message.to names the
    # parent chain's correlation (its root event digest), and the causal walk
    # descends from there to the :spawn and the child's final turn F. The
    # edge-grain gap is recorded in the plan for a later tail.
    it "finds :spawn, :message, and F from the parent's settled state by correlation" do
      _tool, parent_agent = loop_driven(child_provider: mock(text_response("child answer")))

      correlation = parent_agent.timeline.to_a.first.digest
      message = record.message
      expect(message.to).to eq(correlation)
      expect(message.correlation).to eq(correlation)

      spawn = record.spawn
      expect(spawn.correlation).to eq(correlation)
      expect(message.causal_parents).to include(spawn.digest)

      final = store.fetch(message.body.fetch("final"))
      expect(final.digest).to eq(record.child(store).head_digest)

      # The rendered tool_result turn itself carries no causal edge (ruling).
      expect(parent_agent.timeline.to_a[2].causal_parents).to eq([])
    end
  end

  # Two subagent calls in one assistant turn spawn from one head, through the
  # real loop and the real tool. What separates their addresses is the prompt
  # each CALL carried reaching the spawn record, which no example that builds
  # its spawns straight from a Lineage can see.
  describe "a spawn's address" do
    it "differs for two calls of different work in one assistant turn, each naming its own prompt" do
      parent_agent = nil
      tool = build_subagent(provider: mock(text_response("aspirin done"), text_response("statin done")),
                            parent: -> { parent_agent.timeline })
      calls = tool_response(["call_1", "subagent", { "prompt" => "survey the aspirin trials" }],
                            ["call_2", "subagent", { "prompt" => "survey the statin trials" }])
      parent_agent = Lain::Agent.new(provider: mock(calls, text_response("parent done")),
                                     toolset: Lain::Toolset.new([tool]),
                                     context: Lain::Context.new(model: "parent", max_tokens: 256),
                                     timeline: Lain::Timeline.empty(store:))

      parent_agent.ask("please spawn")

      expect(record.spawns.map { |spawn| spawn.body.fetch("spawned_from") }.uniq.size).to eq(1)
      expect(record.spawns.map(&:digest).uniq.size).to eq(2)
      expect(record.spawns.map { |spawn| spawn.body.fetch("task") })
        .to contain_exactly(Lain::Canonical.digest("survey the aspirin trials"),
                            Lain::Canonical.digest("survey the statin trials"))
    end
  end

  # ---- Scenario: attenuation under each posture (5-1.2) ----------------------

  describe "attenuation postures" do
    it "schema posture: the child renders only the allowed tool's schema" do
      provider = mock(text_response("done"))
      tool = build_subagent(provider:, policy: spawn_policy(posture: :schema))
      tool.call({ "prompt" => "go" }, invocation)

      rendered = provider.last_request.tools.map { |t| t["name"] }
      expect(rendered).to eq(with_asker("read_file"))
    end

    # handler_union: the child's rendered tools block equals the SHARED UNION --
    # sibling-equality is the win (two siblings spawned from this union
    # render byte-identical tools blocks) -- NOT "the parent's own toolset",
    # which may differ (in exe the parent holds base + subagent; the union
    # handed to the tool is base).
    it "handler_union posture: renders the shared union, refuses a disallowed call, and journals the refusal" do
      provider = mock(
        tool_response(["t1", "echo", { "text" => "x" }]),
        text_response("done")
      )
      journal = Lain::Channel.new
      tool = build_subagent(provider:, policy: spawn_policy(posture: :handler_union), journal:)
      tool.call({ "prompt" => "go" }, invocation)

      rendered = provider.requests.first.tools.map { |t| t["name"] }
      expect(rendered).to eq(with_asker(union.names))

      refusal_turn = record.child(store).to_a.find do |turn|
        turn.role == "user" && turn.content.any? { |b| b["type"] == "tool_result" }
      end
      expect(refusal_turn.content.first["is_error"]).to be(true)

      journaled = journal.drain.map { |event| event.to_journal["type"] }
      expect(journaled).to include("refused")
    end
  end

  # ---- Scenario: inherit is O(1) (5-1.3) ------------------------------------

  describe "inherit prefix" do
    it "starts the child from the parent's head, so its history includes H" do
      tool = build_subagent(provider: mock(text_response("done")), policy: spawn_policy(prefix: :inherit))
      tool.call({ "prompt" => "go" }, invocation)

      expect(record.child(store).include?(parent.head_digest)).to be(true)
    end
  end

  # ---- Scenario: the sibling-template prefix ---------------------------------

  describe "sibling-template prefix" do
    let(:template) { "You are one of a set of sibling workers over one shared brief. " * 20 }

    def sibling_template_policy(template, posture: :handler_union, only: %i[read_file])
      Lain::Tool::SpawnPolicy.new(
        prefix: Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate.new(template:),
        posture:, only:
      )
    end

    def cache_marks(request)
      system_marks = (request.system || []).select { |b| b["cache"] }
      message_marks = request.messages.flat_map { |m| m["content"] }.select { |b| b.is_a?(Hash) && b["cache"] }
      [system_marks, message_marks]
    end

    it "gives three siblings a byte-identical prefix through the template breakpoint, per-child content after it" do
      provider = mock(text_response("one"), text_response("two"), text_response("three"))
      tool = build_subagent(provider:, policy: sibling_template_policy(template))

      %w[alpha beta gamma].each { |task| expect(tool.call({ "prompt" => task }, invocation)).to be_ok }

      requests = provider.requests
      expect(requests.size).to eq(3)

      # The shared prefix (tools + system) is byte-identical across siblings...
      expect(requests.map { |r| Lain::Canonical.dump(r.cache_prefix) }.uniq.size).to eq(1)

      # ...so the digest chains share their head, and it sits at the system
      # marker -- the template breakpoint.
      heads = requests.map { |r| r.prefix_digests.first }
      expect(heads.uniq.size).to eq(1)
      expect(heads.first.first).to eq(Lain::Request::SYSTEM_PREFIX)

      # Per-child content lands AFTER the breakpoint: each task is its own
      # first user message, and the chains diverge there.
      %w[alpha beta gamma].each_with_index do |task, index|
        expect(requests[index].messages.first["content"].first["text"]).to eq(task)
      end
      expect(requests.map { |r| r.prefix_digests.last }.uniq.size).to eq(3)
    end

    # The 5-mark-400 pin: count ALL marks that reach the wire, across
    # system AND messages. Exactly one system mark -- Context#cache_marked's,
    # landing ON the template because the strategy leaves it as the last,
    # unmarked block -- plus CacheBreakpoints' marks on messages. A second
    # system mark would overrun Anthropic's 4-marker cap once CacheBreakpoints
    # spends its 3-message budget.
    it "sends exactly the intended marks: one on the template block, the rest CacheBreakpoints' own" do
      provider = mock(text_response("done"))
      tool = build_subagent(provider:, policy: sibling_template_policy(template))
      tool.call({ "prompt" => "go" }, invocation)

      system_marks, message_marks = cache_marks(provider.last_request)
      expect(system_marks.size).to eq(1)
      expect(system_marks.first["text"]).to eq(template)
      expect(message_marks.size).to eq(1)
    end

    it "renders all three prefix strategies through the same Context seam" do
      strategies = {
        fresh: :fresh, inherit: :inherit,
        sibling_template: Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate.new(template:)
      }

      systems = strategies.transform_values do |prefix|
        provider = mock(text_response("done"))
        tool = build_subagent(provider:, policy: spawn_policy(prefix:))
        expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok
        expect(provider.last_request.model).to eq("child-model")
        provider.last_request.system
      end

      # Same seam, one divergence: only the template arm reshapes system.
      expect(systems[:fresh]).to be_nil
      expect(systems[:inherit]).to be_nil
      expect(systems[:sibling_template].last["text"]).to eq(template)
    end

    it "handler_union keeps sibling tool schemas byte-identical, refusing per child at the Handler" do
      provider = mock(
        text_response("first done"),
        tool_response(["t1", "echo", { "text" => "x" }]),
        text_response("second done")
      )
      journal = Lain::Channel.new
      tool = build_subagent(provider:, policy: sibling_template_policy(template), journal:)

      expect(tool.call({ "prompt" => "one" }, invocation)).to be_ok
      expect(tool.call({ "prompt" => "two" }, invocation)).to be_ok

      # Every sibling request carries the same union schema bytes (position-0
      # sharing preserved)...
      expect(provider.requests.map { |r| Lain::Canonical.dump(r.tools) }.uniq.size).to eq(1)
      expect(provider.requests.first.tools.map { |t| t["name"] }).to eq(with_asker(union.names))

      # ...and the second child's disallowed echo was refused at the Handler.
      refusal = record.child(store).to_a.find do |turn|
        turn.role == "user" && turn.content.any? { |b| b["type"] == "tool_result" }
      end
      expect(refusal.content.first["is_error"]).to be(true)
      expect(journal.drain.map { |event| event.to_journal["type"] }).to include("refused")
    end

    # The floor scenario: a template under the minimum cacheable prefix is
    # REPORTED (a journaled note per spawn), never silently un-cacheable.
    it "journals a template_below_floor note when the template sits under the floor" do
      journal = Lain::Channel.new
      tool = build_subagent(provider: mock(text_response("done")),
                            policy: sibling_template_policy("tiny brief"), journal:)
      tool.call({ "prompt" => "go" }, invocation)

      expect(journal.drain.map { |event| event.to_journal["type"] }).to include("template_below_floor")
    end

    # The strip rides the spawn seam's own journal: a factory that hands over a
    # pre-marked system (the role_spec probe shape) gets exactly one wire mark
    # -- on the template -- and the discarded caller mark lands in the record.
    it "threads the strip note through the spawn seam when the factory context arrives pre-marked" do
      marked_context = Lain::Context.new(
        model: "child-model", max_tokens: 256,
        system: [{ "type" => "text", "text" => "bulk", "cache" => true }]
      )
      journal = Lain::Channel.new
      provider = mock(text_response("done"))
      tool = described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider:, context_factory: -> { marked_context }, toolset: union,
        policy: sibling_template_policy(template), parent:, journal:
      )
      expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok

      system_marks, = cache_marks(provider.last_request)
      expect(system_marks.size).to eq(1)
      expect(system_marks.first["text"]).to eq(template)
      expect(journal.drain.map { |event| event.to_journal["type"] }).to include("system_mark_stripped")
    end

    it "journals no floor note when the template clears the minimum cacheable prefix" do
      floor = Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate::MINIMUM_CACHEABLE_TOKENS *
              Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate::CHARS_PER_TOKEN
      journal = Lain::Channel.new
      tool = build_subagent(provider: mock(text_response("done")),
                            policy: sibling_template_policy("x" * floor), journal:)
      tool.call({ "prompt" => "go" }, invocation)

      expect(journal.drain.map { |event| event.to_journal["type"] }).not_to include("template_below_floor")
    end

    # The floor note has no lifecycle exemption: an actor-mode sibling below the
    # floor must be reported through #launch_actor's path exactly as a one-shot's is
    # through #perform's -- silence here is the un-cacheable fan-out the note
    # exists to expose.
    it "journals the floor note on an actor-mode launch too" do
      journal = Lain::Channel.new
      tool = described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider: mock(text_response("actor done")), context_factory: -> { child_context },
        toolset: union, policy: sibling_template_policy("tiny"), parent:, journal:,
        mode: :actor, log: Lain::Tools::Subagent::Log.new
      )
      Sync do
        actor = tool.launch_actor("go", worker_env: Lain::WorkerEnv.default)
        actor.settle
        actor.stop
      end

      expect(journal.drain.map { |event| event.to_journal["type"] }).to include("template_below_floor")
    end
  end

  # ---- The injected role persona reshapes the child system -------------------
  #
  # The persona is a NEW injected collaborator ({Role::Persona}); its Null
  # default keeps every existing spawn path byte-identical. The full persona
  # acceptance (segment sharing, override reach, fused-String failure) lives in
  # spec/lain/role_prelude_wiring_spec.rb; these two pin the seam's presence and
  # its Null default here, beside the tool.
  describe "the injected role persona" do
    it "defaults to Null: with no persona wired the child's system is unchanged" do
      provider = mock(text_response("done"))
      build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      # child_context carries system: nil, and the Null persona is identity.
      expect(provider.last_request.system).to be_nil
    end

    it "reshapes the child system to the role prelude segments when a persona is wired" do
      Dir.mktmpdir do |root|
        slots = Lain::Prompt::Slots.load(root:)
        role = Lain::Role::Catalog.fetch(:researcher)
        read_union = Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new,
                                        Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])
        provider = mock(text_response("done"))
        tool = described_class.new(
          tool_middleware: ToolRegistry::UNGUARDED,
          provider:, context_factory: -> { child_context }, toolset: read_union,
          policy: role.spawn_policy, parent:, persona: Lain::Role::Persona.new(role:, slots:)
        )

        tool.call({ "prompt" => "go" }, invocation)

        system = provider.last_request.system
        expect(system.size).to eq(2)
        expect(system.first["text"]).to eq(slots.render("system"))
        expect(system.first["cache"]).to be(true)
        expect(system.last["text"]).to eq(slots.render_role(:researcher))
      end
    end
  end

  # ---- The public synchronous run-one-prompt -> result entry ----------------
  #
  # A role-selecting seam ({Skill::RoleSpawn}) builds a one-shot Subagent per
  # call and drives it DIRECTLY -- no model-facing {#call}/effect-handler
  # dispatch, no actor launch. {#run} is that entry: one prompt to a single
  # final {Tool::Result}, synchronously, over the same {#spawn_one_shot}
  # machinery {#perform} uses (so its records land in @last_* just the same).
  describe "the public #run entry" do
    it "runs one prompt to a single final result without the effect handler or the actor path" do
      tool = build_subagent(provider: mock(text_response("child answer")))
      result = tool.run("go")

      expect(result).to be_ok
      expect(result.content).to eq("child answer")
      expect(record.child(store)).not_to be_nil
      expect(record.message.kind).to eq(:message)
    end

    it "honors the depth ceiling exactly as #perform does: refuses at 0, spawning nothing" do
      tool = build_subagent(provider: mock(text_response("unused")), max_depth: 0)
      before = store.size

      result = tool.run("go")

      expect(result).to be_error
      expect(result.content).to include("depth")
      expect(record.spawn).to be_nil
      expect(store.size).to eq(before)
    end
  end

  # ---- A child has a model phase of its own ---------------------------------
  #
  # A prompt its provider refuses WHOLE for not fitting the context is the one
  # failure a child cannot report as an answer: no model saw it. Without a
  # budget in front of the child's provider, whoever spawned it was handed the
  # server's own error body -- a JSON blob naming neither the child nor what to
  # do -- and nothing recorded that the refusal happened at all.
  describe "a child's prompt the provider refuses whole" do
    let(:journal) { [] }
    let(:telemetry) { [] }

    def refusing = SubagentSpecRefusingProvider.new(responses: [])

    def refusing_spawn(**seam)
      build_subagent(provider: refusing, name: "diff_critic", journal:, **seam)
    end

    def pressures(records) = records.grep(Lain::Telemetry::WindowPressure)

    it "refuses in words that name the child and the task it was handed" do
      expect { refusing_spawn.run("critique lib/a.rb") }
        .to raise_error(Lain::Middleware::RequestBudget::OverWindow, /diff_critic.*task/)
    end

    def raised(tool)
      tool.run("critique lib/a.rb")
      raise "expected a refusal"
    rescue Lain::WindowExceeded => e
      e
    end

    it "carries the provider's own figures without carrying its body" do
      error = raised(refusing_spawn)

      expect(error).to have_attributes(prompt_tokens: 41_000, window_tokens: 32_768, source: "ollama")
      expect(error.message).to include("41000", "32768")
      expect(error.message).not_to include(SubagentSpecRefusingProvider::BODY)
    end

    # The real path, not a hand-marked error: the child's own {Agent#ask}
    # takes the prompt back and MARKS this error as it climbs, exactly as a
    # chat's does. The chain it came off ended with the child, so the clause a
    # chat's refusal ends with would describe a conversation the spawner
    # cannot go back to -- and the words must stay one line either way.
    it "is withdrawn by the child's own ask, and says nothing of it" do
      error = raised(refusing_spawn)

      expect(error).to be_withdrawn
      expect(error.message).not_to include("withdrawn")
      expect(error.message.lines.size).to eq(1)
    end

    # The seam's `journal` is the session file alone and `telemetry` is the tee
    # a cockpit's live views fold. The record is the CHILD's, so it belongs in
    # the durable half only: a HUD folding it would move the parent's occupancy
    # onto a window and a chain the parent never rendered.
    it "writes the record to the seam's durable journal, naming the spawn, and never to the tee" do
      expect { refusing_spawn(telemetry:).run("critique lib/a.rb") }.to raise_error(Lain::WindowExceeded)

      expect(pressures(journal).map(&:spawn)).to eq(["diff_critic"])
      expect(pressures(journal).map(&:prompt_tokens)).to eq([41_000])
      expect(pressures(telemetry)).to be_empty
    end

    # The child names the turn its own render stood on, off its own chain --
    # the first user turn of a fresh root, never the parent's head.
    it "tags the record with the child's own turn, not the parent's" do
      expect { refusing_spawn.run("critique lib/a.rb") }.to raise_error(Lain::WindowExceeded)

      expect(pressures(journal).map(&:stands_on)).to eq([nil])
    end
  end

  # ---- Depth ceiling (escalation-trigger guard) -----------------------------

  # One model-facing spawner offering several roles, the role named per call:
  # how an orchestrator hands implementing to a child that writes and
  # reviewing to one that cannot.
  describe "a spawner offering roles by name" do
    def offering(**spawners) = Lain::Tools::Subagent::Choice.new(spawners)

    def tool_result_in(request)
      request.messages.flat_map { |message| Array(message["content"]) }
             .find { |block| block.is_a?(Hash) && block["type"] == "tool_result" }
    end

    it "spawns the role the call names, through that role's own spawner" do
      reading = mock(text_response("read it"))
      other = mock(text_response("unused"))
      tool = offering(reader: build_subagent(provider: reading), other: build_subagent(provider: other))

      result = tool.call({ "prompt" => "look", "role" => "reader" }, invocation)

      expect(result.content).to eq("read it")
      expect([reading.call_count, other.call_count]).to eq([1, 0])
    end

    it "refuses a role it does not offer, naming the ones it does, and spawns nothing" do
      provider = mock(text_response("unused"))

      result = offering(reader: build_subagent(provider:)).call({ "prompt" => "look", "role" => "writer" }, invocation)

      expect(result).to be_error
      expect(result.content).to include("writer", "reader")
      expect(provider.call_count).to eq(0)
    end

    it "is shown as the subagent tool, with the roles on offer as the role's enum" do
      tool = offering(reader: build_subagent(provider: mock), other: build_subagent(provider: mock))

      expect(tool.name).to eq("subagent")
      expect(tool.roles).to eq(%w[reader other])
      expect(tool.input_schema["properties"]["role"]["enum"]).to eq(%w[reader other])
      expect(tool.input_schema["required"]).to contain_exactly("prompt", "role")
    end

    # A child's union holding the offer gets a descended copy, so every role
    # on offer spawns at the child's ceiling and never past it.
    it "descends into a child's union, so a role it offers is capped at the child's ceiling" do
      child = mock(tool_response(["c1", "subagent", { "prompt" => "deeper", "role" => "reader" }]),
                   text_response("child done"))
      offer = offering(reader: build_subagent(provider: mock(text_response("never asked")), max_depth: 3))
      outer = build_subagent(provider: child, max_depth: 1, toolset: Lain::Toolset.new([offer]),
                             policy: spawn_policy(only: %i[subagent]))

      expect(outer.run("go").content).to eq("child done")
      expect(tool_result_in(child.last_request)).to include("is_error" => true)
      expect(tool_result_in(child.last_request)["content"].to_s).to include("depth exceeded")
    end
  end

  describe "the spawn-depth ceiling" do
    it "refuses to spawn at depth 0, emitting no :spawn event and touching no Store" do
      tool = build_subagent(provider: mock(text_response("unused")), max_depth: 0)
      before = store.size

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_error
      expect(result.content).to include("depth")
      expect(store.size).to eq(before)
      expect(record.spawn).to be_nil
    end

    # The ceiling must be TRANSITIVE (review panel, substantive): a Subagent
    # reachable in the child's union must not keep its constructing ceiling,
    # or recursion never terminates via the cap. Each spawn hands descendants
    # a decremented copy: depth 2 -> the child may spawn (copies at 1) -> the
    # grandchild may spawn (copies at 0) -> the great-grandchild is refused.
    it "decrements through descendants: depth 2 spawns child and grandchild, refuses the great-grandchild" do
      provider = mock(
        tool_response(["c1", "subagent", { "prompt" => "go deeper" }]),
        tool_response(["g1", "subagent", { "prompt" => "deeper still" }]),
        text_response("grandchild done"),
        text_response("child done")
      )
      deepest = build_subagent(provider:, policy: spawn_policy(only: []),
                               toolset: Lain::Toolset.new([EchoTool.new]), max_depth: 9)
      mid = build_subagent(provider:, policy: spawn_policy(only: []),
                           toolset: Lain::Toolset.new([EchoTool.new, deepest]), max_depth: 9)
      tool = build_subagent(provider:, policy: spawn_policy(only: []),
                            toolset: Lain::Toolset.new([EchoTool.new, mid]), max_depth: 2)

      result = tool.call({ "prompt" => "start" }, invocation)

      expect(result).to be_ok
      expect(result.content).to eq("child done")
      # Four model rounds: child x2 + grandchild x2. The great-grandchild was
      # refused BEFORE any model call, and the refusal reached the grandchild
      # as an is_error tool_result in its second request.
      expect(provider.call_count).to eq(4)
      refusal = provider.requests[2].messages.flat_map { |m| m["content"] }
                                    .find { |b| b.is_a?(Hash) && b["type"] == "tool_result" }
      expect(refusal["is_error"]).to be(true)
      expect(refusal["content"]).to include("depth")
    end

    # A tool's OWN tighter ceiling survives the copy: descending must never
    # RAISE a ceiling (that would be capability escalation), only lower it.
    it "never raises a descendant's own tighter ceiling" do
      provider = mock(
        tool_response(["c1", "subagent", { "prompt" => "go deeper" }]),
        text_response("child done")
      )
      never_spawns = build_subagent(provider:, policy: spawn_policy(only: []),
                                    toolset: Lain::Toolset.new([EchoTool.new]), max_depth: 0)
      tool = build_subagent(provider:, policy: spawn_policy(only: []),
                            toolset: Lain::Toolset.new([EchoTool.new, never_spawns]), max_depth: 5)

      result = tool.call({ "prompt" => "start" }, invocation)

      expect(result).to be_ok
      # Only the child's two rounds ran: its spawn attempt was refused even
      # though the spawner had depth to spare, because the inner tool said 0.
      expect(provider.call_count).to eq(2)
      refusal = provider.requests[1].messages.flat_map { |m| m["content"] }
                                    .find { |b| b.is_a?(Hash) && b["type"] == "tool_result" }
      expect(refusal["is_error"]).to be(true)
      expect(refusal["content"]).to include("depth")
    end

    # The shape the epic's Subagent takes: an issue_orchestrator child at depth
    # 2, holding a spawner of its own. Its grandchild here is handed a spawner
    # too, which no shipped role grants, so the refusal at the third level is
    # the ceiling's and not the attenuation's.
    it "lets an issue orchestrator fan out exactly one level" do
      provider = mock(
        tool_response(["o1", "subagent", { "prompt" => "implement it" }]),
        tool_response(["g1", "subagent", { "prompt" => "deeper still" }]),
        text_response("grandchild done"),
        text_response("orchestrated")
      )
      deepest = build_subagent(provider:, policy: spawn_policy(only: []),
                               toolset: Lain::Toolset.new([EchoTool.new]), max_depth: 9)
      spawner = build_subagent(provider:, policy: spawn_policy(only: []),
                               toolset: Lain::Toolset.new([EchoTool.new, deepest]), max_depth: 9)
      floor = %w[read_file list_files glob grep edit_file write_file todo_write bash run_skill]
      epic = build_subagent(provider:, policy: Lain::Role::Catalog.fetch(:issue_orchestrator).spawn_policy,
                            toolset: Lain::Toolset.new(floor.map { |name| ToolRegistry.build(name) } + [spawner]),
                            max_depth: 2)

      result = epic.call({ "prompt" => "run the plan" }, invocation)

      expect(result.content).to eq("orchestrated")
      expect(provider.call_count).to eq(4)
      refusal = provider.requests[2].messages.flat_map { |m| m["content"] }
                                    .find { |b| b.is_a?(Hash) && b["type"] == "tool_result" }
      expect(refusal["is_error"]).to be(true)
      expect(refusal["content"]).to eq("subagent spawn depth exceeded: this agent is at the ceiling")
    end

    # The exe shape -- a union holding no subagent -- passes through untouched:
    # nothing to replace, same names rendered.
    it "leaves a subagent-free union (the exe shape) unchanged" do
      provider = mock(text_response("done"))
      tool = build_subagent(provider:, policy: spawn_policy(posture: :handler_union), max_depth: 2)
      tool.call({ "prompt" => "go" }, invocation)

      expect(provider.last_request.tools.map { |t| t["name"] }).to eq(with_asker(union.names))
    end
  end

  # ---- Children get a real Session ------------------------------------------
  #
  # Before this card, every spawned child ran under Session::Null
  # (spawn_agent's `session: Session::Null.instance`), so EditFile's
  # read-before-write contract -- its `requires` block calls
  # `session_of(invocation).read?(input.path)` -- could never be satisfied:
  # Session::Null#read? is unconditionally false. A write-capable child was
  # structurally unable to ever pass its own contract.
  describe "children get a real Session" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    attr_reader :tmpdir

    def write(name, content)
      path = File.join(tmpdir, name)
      File.write(path, content)
      path
    end

    def tool_result_blocks(timeline)
      timeline.to_a.select { |turn| turn.role == "user" && turn.content.any? { |b| b["type"] == "tool_result" } }
              .flat_map(&:content)
              .select { |b| b["type"] == "tool_result" }
    end

    def read_edit_toolset
      Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::EditFile.new])
    end

    it "lets a write-capable child satisfy read-before-write" do
      path = write("hello.txt", "hello world")
      provider = mock(
        tool_response(["r1", "read_file", { "path" => path }]),
        tool_response(["e1", "edit_file", { "path" => path, "old_string" => "hello", "new_string" => "goodbye" }]),
        text_response("edited")
      )
      tool = build_subagent(provider:, toolset: read_edit_toolset, policy: spawn_policy(only: %i[read_file edit_file]))

      result = tool.call({ "prompt" => "read then edit" }, invocation)

      expect(result).to be_ok
      expect(tool_result_blocks(record.child(store))).to all(include("is_error" => false))
      expect(File.read(path)).to eq("goodbye world")
    end

    it "does not hand a child the parent's read-set: the child's session starts empty" do
      path = write("hello.txt", "hello world")
      parent_session = Lain::Session.new.record_read(path)
      provider = mock(
        tool_response(["e1", "edit_file", { "path" => path, "old_string" => "hello", "new_string" => "goodbye" }]),
        text_response("gave up")
      )
      tool = build_subagent(provider:, toolset: read_edit_toolset, policy: spawn_policy(only: %i[read_file edit_file]))

      result = tool.call({ "prompt" => "edit blind" }, Lain::Tool::Invocation.new(context: parent_session))

      expect(result).to be_ok
      results = tool_result_blocks(record.child(store))
      expect(results).not_to be_empty
      expect(results.first["is_error"]).to be(true)
      expect(File.read(path)).to eq("hello world")
    end

    it "gives sibling children their own Session: a second spawn does not inherit the first's read-set" do
      path = write("hello.txt", "hello world")
      provider = mock(
        tool_response(["r1", "read_file", { "path" => path }]),
        tool_response(["e1", "edit_file", { "path" => path, "old_string" => "hello", "new_string" => "goodbye" }]),
        text_response("first done"),
        tool_response(["e2", "edit_file", { "path" => path, "old_string" => "goodbye", "new_string" => "farewell" }]),
        text_response("second done")
      )
      tool = build_subagent(provider:, toolset: read_edit_toolset, policy: spawn_policy(only: %i[read_file edit_file]))

      first = tool.call({ "prompt" => "read then edit" }, invocation)
      expect(first).to be_ok
      expect(File.read(path)).to eq("goodbye world")

      second = tool.call({ "prompt" => "edit blind" }, invocation)
      expect(second).to be_ok
      second_results = tool_result_blocks(record.child(store))
      expect(second_results.first["is_error"]).to be(true)
      expect(File.read(path)).to eq("goodbye world")
    end
  end

  # ---- A child runs in a LEASED environment ---------------------------------
  #
  # `--isolation worktree` used to reach only an actor an OPERATOR adopted:
  # #run_child hard-coded {Lain::WorkerEnv.default}, so a model-dispatched child
  # worked in the human's own checkout however the run was started. The lease is
  # taken per DISPATCH now, and taken UNCONDITIONALLY -- {Lain::Isolation::Null}
  # hands back WorkerEnv.default and reclaims nothing, so an unisolated run pays
  # one object and there is no `if isolation` anywhere to get backwards.
  describe "the isolation lease a child runs under" do
    around do |example|
      Dir.mktmpdir("lain-subagent-leases") do |dir|
        @leases_root = dir
        example.run
      end
    end

    attr_reader :leases_root

    let(:backend) { SubagentSpecIsolation.new(leases_root) }
    let(:leases) { Lain::Isolation::Leases.new(backend:) }
    let(:seen) { [] }
    let(:cwd_tool) { SubagentSpecCwdTool.new(seen) }

    def reports_cwd = mock(tool_response(["c1", "cwd", {}]), text_response("done"))

    def cwd_only(*names) = Lain::Toolset.new([cwd_tool, *names])

    # Sibling fan-out only pays under a shared template prefix, so the policy
    # says so -- what this file's fan-out group uses, narrowed to the one tool.
    def staggered_policy_with_scope
      Lain::Tool::SpawnPolicy.new(
        prefix: Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate.new(template: "one shared brief. " * 20),
        posture: :handler_union, only: %i[cwd scope]
      )
    end

    def staggered_policy
      Lain::Tool::SpawnPolicy.new(
        prefix: Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate.new(template: "one shared brief. " * 20),
        posture: :handler_union, only: %i[cwd]
      )
    end

    it "runs in the host working directory when no isolation is wired" do
      tool = build_subagent(provider: reports_cwd, toolset: cwd_only, policy: spawn_policy(only: %i[cwd]))

      expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok
      expect(seen).to eq([Dir.pwd])
    end

    it "runs the child in the leased directory, and releases the lease when it returns" do
      tool = build_subagent(provider: reports_cwd, toolset: cwd_only,
                            policy: spawn_policy(only: %i[cwd]), isolation: leases)

      expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok
      expect(seen).to eq(backend.leased)
      expect(seen).not_to eq([Dir.pwd])
      expect(backend.released).to eq(backend.leased)
    end

    # A lease the caller already holds, lent to the child: the dispatch cuts
    # no checkout of its own and hands nothing back, because the holder hands
    # the checkout back when its own work is done.
    it "runs the child in an environment its caller holds, handing nothing back" do
      held = Lain::WorkerEnv.default.with(cwd: leases_root)
      tool = build_subagent(provider: reports_cwd, toolset: cwd_only, policy: spawn_policy(only: %i[cwd]),
                            isolation: Lain::Isolation::Leases::InPlace.new(worker_env: held))

      result = tool.run("go")

      expect(seen).to eq([leases_root])
      expect(result.content).to eq("done")
    end

    # Plan scope confines the session to a spike, and every child spawned while
    # it stands works there too -- whichever way it is spawned: a model's tool
    # call, a human's `@role/skill` ({#run}), a fan-out, or an actor. The scope
    # is read off the seam, which a chat builds over the board that holds it,
    # so no spawn path can miss it.
    describe "while the seam's scope confines" do
      let(:spike) { File.join(File.realpath(leases_root), "spike").tap { FileUtils.mkdir_p(_1) } }
      let(:scope) do
        Lain::Session::Confined.new(worker_env: Lain::WorkerEnv.new(cwd: spike, env: {}, checkout: spike),
                                    reminder: "in a spike")
      end
      let(:reader) { Struct.new(:current).new(scope) }
      let(:scopes) { [] }
      let(:scope_tool) do
        held = scopes
        Class.new(Lain::Tool) do
          define_method(:name) { "scope" }
          define_method(:description) { "Reports the scope this session is confined to." }
          define_method(:input_schema) { { type: :object, properties: {} } }
          define_method(:perform) do |_input, invocation|
            held << session_of(invocation).scope
            Lain::Tool::Result.ok("reported")
          end
        end.new
      end

      def reports_both = mock(tool_response(["c1", "cwd", {}], ["c2", "scope", {}]), text_response("done"))

      def confined_tool(provider = reports_both, **rest)
        build_subagent(provider:, toolset: cwd_only(scope_tool), policy: spawn_policy(only: %i[cwd scope]),
                       isolation: leases, scope: reader, **rest)
      end

      def inherited = [seen, scopes, backend.leased]

      it "runs a child a tool call spawned in the scope's directory, confined, leasing nothing" do
        expect(confined_tool.call({ "prompt" => "go" }, invocation)).to be_ok
        expect(inherited).to eq([[spike], [scope], []])
      end

      it "runs a child a human's role skill spawned there too" do
        expect(confined_tool.run("go").content).to eq("done")
        expect(inherited).to eq([[spike], [scope], []])
      end

      it "runs every child of a fan-out there" do
        provider = mock(tool_response(["c1", "cwd", {}], ["c2", "scope", {}]), text_response("done"),
                        tool_response(["c3", "cwd", {}], ["c4", "scope", {}]), text_response("done"))
        Sync { confined_tool(provider, policy: staggered_policy_with_scope).fan_out(%w[one two]) }

        expect(inherited).to eq([[spike, spike], [scope, scope], []])
      end

      # A checkout lent on purpose -- a critic reading the reviewed head -- is
      # what that child is for, so it keeps it; its writes stay the board's to
      # confine, and nothing tells it it is in the spike.
      it "keeps a checkout the caller lent explicitly, rather than the scope's directory" do
        held = Lain::WorkerEnv.new(cwd: File.realpath(leases_root), env: {}, checkout: File.realpath(leases_root))
        tool = confined_tool(isolation: Lain::Isolation::Leases::InPlace.new(worker_env: held))

        expect(tool.run("go").content).to eq("done")
        expect([seen, scopes]).to eq([[held.cwd], [Lain::Session::Unconfined]])
      end

      # The supervisor leased the actor a checkout of the run's own, and plan
      # scope puts the actor in the spike instead.
      it "runs an actor in the scope's directory whatever environment it was launched with" do
        tool = confined_tool(mode: :actor)
        Sync do
          actor = tool.launch_actor("go", worker_env: Lain::WorkerEnv.default)
          actor.settle
          actor.stop
        end

        expect(inherited).to eq([[spike], [scope], []])
      end
    end

    # The other exit. A context that will not render is {ChildBuilder#spawned}'s
    # own named example of a spawn raising past the acquire, and a lease held by
    # a raise is a leaked checkout that defeats the NEXT acquire at that path.
    it "releases the lease when the spawn raises, not only when the child returns" do
      tool = described_class.new(provider: mock(text_response("unused")),
                                 context_factory: -> { raise "this child gets no context" },
                                 toolset: cwd_only, policy: spawn_policy(only: %i[cwd]),
                                 parent:, isolation: leases, budget: Lain::Agent::Budget.new,
                                 tool_middleware: ToolRegistry::UNGUARDED)

      expect { tool.run("go") }.to raise_error("this child gets no context")
      expect(backend.leased.size).to eq(1)
      expect(backend.released).to eq(backend.leased)
    end

    # A grandchild takes a SIBLING checkout, never one nested inside its
    # parent's: a worktree-of-a-worktree is a peer in git's one registry anyway,
    # and the parent's release force-removes its tree, which would either
    # destroy the grandchild's or be blocked by it. So "did not escape" is
    # asserted against the PARENT's leased path as well as the host's -- a
    # sibling is trivially not the host's cwd, so the host alone would pass on
    # the bug this pins.
    it "gives a nested child a leased directory of its own -- neither the host's nor its parent's" do
      provider = mock(
        tool_response(["c1", "subagent", { "prompt" => "deeper" }]),
        tool_response(["g1", "cwd", {}]),
        text_response("grandchild done"),
        tool_response(["c2", "cwd", {}]),
        text_response("child done")
      )
      inner = build_subagent(provider:, toolset: cwd_only, policy: spawn_policy(only: %i[cwd]),
                             max_depth: 9, isolation: leases)
      tool = build_subagent(provider:, toolset: cwd_only(inner), max_depth: 2,
                            policy: spawn_policy(only: %i[cwd subagent]), isolation: leases)

      expect(tool.call({ "prompt" => "start" }, invocation)).to be_ok

      grandchild, child = seen
      expect(seen.size).to eq(2)
      expect(grandchild).not_to eq(child)
      expect(seen).not_to include(Dir.pwd)
      expect(seen.sort).to eq(backend.leased.sort)
    end

    # The teardown that FAILS. {Lain::Isolation::Worktree#remove} raises rather
    # than leave a checkout it could not reclaim, and `Tool#call` does not
    # rescue -- so a bare `ensure lease.release` hands the parent the teardown
    # failure instead of the answer a completed child already paid for. The
    # tolerance is {Lain::Supervisor#reap}'s, at the seam with the same shape:
    # the failure is journaled rather than swallowed, because a checkout that
    # outlived its lease is a real leak and the record is where its key is
    # found.
    it "returns the child's answer when the lease cannot be reclaimed, journaling the leak" do
      journal = Lain::Channel.new
      unreclaimable = SubagentSpecIsolation.new(leases_root, reclaim: :refuse)
      tool = build_subagent(provider: mock(text_response("child answer")), toolset: cwd_only,
                            policy: spawn_policy(only: %i[cwd]), journal:,
                            isolation: Lain::Isolation::Leases.new(backend: unreclaimable))

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok
      expect(result.content).to eq("child answer")
      leaks = journal.drain.grep(Lain::Isolation::LeaseNotReclaimed)
      expect(leaks.map(&:worker_key)).to eq(unreclaimable.worker_ids)
      # `error` is the half a human can act on: the worker key is hashed into
      # the path, so what names the directory still standing is the backend's
      # own message.
      expect(leaks.map(&:error)).to all(include(leases_root))
    end

    # #fan_out dispatches siblings concurrently over one tool, so two fibers are
    # really inside the allocator at once. A shared counter that lost an
    # increment would hand two live siblings one worker id, and a backend that
    # keys a checkout on it refuses the second -- which is why the id allocation
    # is the thing under test here, not the refusal.
    it "allocates a distinct worker id per dispatch, so concurrent siblings never share one" do
      provider = mock(text_response("a"), text_response("b"), text_response("c"))
      tool = build_subagent(provider:, toolset: cwd_only, policy: staggered_policy, isolation: leases)

      results = tool.fan_out(%w[alpha beta gamma])

      expect(results).to all(be_ok)
      expect(backend.worker_ids.uniq.size).to eq(3)
      expect(backend.released.sort).to eq(backend.leased.sort)
    end

    # Minted through the ONE object both allocators draw from, never spelled
    # here: {Lain::Supervisor} numbers the actors an operator adopts off a
    # sequence this one cannot see, and a spawn that spelled its own id would
    # put the disjointness of the two in a string convention neither asserts.
    it "mints its worker ids in the spawned lane of the shared allocator" do
      tool = build_subagent(provider: mock(text_response("done")), toolset: cwd_only,
                            policy: spawn_policy(only: %i[cwd]), isolation: leases, name: "researcher")

      tool.call({ "prompt" => "go" }, invocation)

      expect(backend.worker_ids)
        .to eq([Lain::Isolation::WorkerId.spawned(role: "researcher", ordinal: 1).to_s])
    end

    # A worker's commits are never optional: a returning child's lease ends in
    # the handoff's RECLAIM, which hands the work back while the checkout is
    # still on disk, and never in a bare release that deletes it. A child that
    # raised is SURRENDERED instead -- anchored, with no resolver spawned while
    # an exception climbs.
    describe "the handoff a child's lease ends in" do
      let(:report) { Lain::Isolation::WorkerHandoff::Report.nothing }
      let(:handoff) { SubagentSpecHandoff.new(report:) }
      let(:handing) { Lain::Isolation::Leases.new(backend:, handoff:) }
      let(:spawned_id) { Lain::Isolation::WorkerId.spawned(role: "subagent", ordinal: 1).to_s }

      it "reclaims a returning child's lease through the handoff while it is still live, naming the worker" do
        tool = build_subagent(provider: mock(text_response("child answer")), toolset: cwd_only,
                              policy: spawn_policy(only: %i[cwd]), isolation: handing)

        expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok
        expect(handoff.calls).to eq([[:reclaim, spawned_id, false]])
        expect(backend.released).to eq(backend.leased)
      end

      it "surrenders, never reclaims, the lease of a spawn that raised" do
        tool = described_class.new(provider: mock(text_response("unused")),
                                   context_factory: -> { raise "this child gets no context" },
                                   toolset: cwd_only, policy: spawn_policy(only: %i[cwd]),
                                   parent:, isolation: handing, budget: Lain::Agent::Budget.new,
                                   tool_middleware: ToolRegistry::UNGUARDED)

        expect { tool.run("go") }.to raise_error("this child gets no context")
        expect(handoff.calls).to eq([[:surrender, spawned_id, false]])
        expect(backend.released).to eq(backend.leased)
      end

      context "when the handback landed something" do
        let(:report) do
          Lain::Isolation::WorkerHandoff::Report.new(kind: :merged, ref: "refs/lain/worker/subagent-1-abc",
                                                     sha: "a" * 40, fast_forward: true)
        end

        # The one line a caller folds into the worker's result: the parent is
        # told where its child's work went, on the result AND on the record of
        # what it was given, so the two cannot disagree.
        it "folds the report's summary into what the parent is given" do
          tool = build_subagent(provider: mock(text_response("child answer")), toolset: cwd_only,
                                policy: spawn_policy(only: %i[cwd]), isolation: handing)

          result = tool.call({ "prompt" => "go" }, invocation)

          expect(result.content).to start_with("child answer")
          expect(result.content).to include(report.summary)
          expect(record.message.body["result"]).to eq(result.content)
        end
      end

      it "gives the answer back byte-identical when the handback has nothing to report" do
        tool = build_subagent(provider: mock(text_response("child answer")), toolset: cwd_only,
                              policy: spawn_policy(only: %i[cwd]), isolation: handing)

        expect(tool.call({ "prompt" => "go" }, invocation).content).to eq("child answer")
      end
    end

    # Between the child's answer and its reclaim, the worker is offered a
    # chance to rebase onto where the working branch now is -- while it is
    # still live, since only a live child can be asked to resolve a conflict.
    describe "the self-sync between a child's answer and its handback" do
      let(:calls) { [] }
      let(:handoff) { SubagentSpecHandoff.new(report: Lain::Isolation::WorkerHandoff::Report.nothing, calls:) }
      let(:sync) { SubagentSpecSync.new(calls) }
      let(:syncing) { Lain::Isolation::Leases.new(backend:, handoff:, sync:) }
      let(:spawned_id) { Lain::Isolation::WorkerId.spawned(role: "subagent", ordinal: 1).to_s }

      it "syncs a returning child on its live lease, before the lease is reclaimed" do
        tool = build_subagent(provider: mock(text_response("child answer")), toolset: cwd_only,
                              policy: spawn_policy(only: %i[cwd]), isolation: syncing)

        expect(tool.call({ "prompt" => "go" }, invocation).content).to eq("child answer")
        expect(calls).to eq([[:sync, spawned_id, false, false], [:reclaim, spawned_id, false]])
      end

      it "offers a child holding a shell as a worker it may ask, and the child answers" do
        tool = build_subagent(provider: mock(text_response("child answer"), text_response("rebased")),
                              toolset: cwd_only(SubagentSpecShell.new), policy: spawn_policy(only: %i[cwd bash]),
                              isolation: syncing)

        expect(tool.call({ "prompt" => "go" }, invocation).content).to eq("child answer")
        expect(calls.first).to eq([:sync, spawned_id, false, true])
        expect(sync.replies).to eq(["rebased"])
      end

      # The checkout of a spawn that raised is still read before it is
      # surrendered, so uncommitted work is named on the record. The child is
      # not asked: it is the one that just failed.
      it "syncs a spawn that raised without asking it, before its lease is surrendered" do
        tool = described_class.new(provider: mock(text_response("unused")),
                                   context_factory: -> { raise "this child gets no context" },
                                   toolset: cwd_only, policy: spawn_policy(only: %i[cwd]),
                                   parent:, isolation: syncing, budget: Lain::Agent::Budget.new,
                                   tool_middleware: ToolRegistry::UNGUARDED)

        expect { tool.run("go") }.to raise_error("this child gets no context")
        expect(calls).to eq([[:sync, spawned_id, false, false], [:surrender, spawned_id, false]])
      end

      it "runs the child in the environment the sync hands it" do
        editors = []
        tool = build_subagent(provider: mock(tool_response(["e1", "editor", {}]), text_response("done")),
                              toolset: Lain::Toolset.new([SubagentSpecEditorTool.new(editors)]),
                              policy: spawn_policy(only: %i[editor]), isolation: syncing)

        tool.call({ "prompt" => "go" }, invocation)

        expect(editors).to eq(["true"])
      end

      it "hands what the sync did to the handoff, so it rides the handback's record" do
        tool = build_subagent(provider: mock(text_response("child answer")), toolset: cwd_only,
                              policy: spawn_policy(only: %i[cwd]), isolation: syncing)

        tool.call({ "prompt" => "go" }, invocation)

        expect(handoff.synced).to eq([sync.result])
      end

      it "surrenders with the sync's facts when the dispatch raises after the sync ran" do
        expect do
          syncing.hold("subagent", journal: Lain::Channel::Null.instance) do |_worker_env, sync_child|
            sync_child.call(Lain::Isolation::SelfSync::Unaskable)
            raise "the dispatch failed after the sync"
          end
        end.to raise_error("the dispatch failed after the sync")

        expect(calls.last.first).to eq(:surrender)
        expect(handoff.synced).to eq([sync.result])
      end
    end
  end

  # ---- The PATH boundary reaches a child, or it is a privilege inversion ------
  #
  # A child's gate is built by the tool stack builder its seam carries. So a
  # sensitivity policy that reached the parent's gate and not the seam would
  # leave every subagent able to read what its parent must ask about -- and the
  # child is the LESS supervised of the two, so that is an inversion rather than
  # a wiring omission to fix later.
  #
  # Driven end to end through a real child loop and a real ReadFile, because
  # what is being asserted is about the gate a child really runs behind. The
  # discriminator is the two RESULTS: a refusal names the approval, a permitted
  # read hands back the bytes.
  describe "a sensitive path a child names for itself" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    attr_reader :tmpdir

    let(:secret) do
      path = File.join(tmpdir, ".env")
      File.write(path, "TOKEN=shhh")
      path
    end
    let(:sensitivity) do
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: "/home/tester", cwd: tmpdir))
    end

    # The stack a child here runs behind, as the tool guard builds one: gated
    # by `gate_policy` over `sensitivity`, and over no path policy at all when
    # none travelled the seam.
    def guarded(gate_policy:, sensitivity: Lain::Sensitivity::Policy::Null.instance)
      { tool_middleware: ToolRegistry.gated(policy: gate_policy, sensitivity:) }
    end

    def child_reads(path, **gating)
      tool = build_subagent(provider: mock(tool_response(["r1", "read_file", { "path" => path }]),
                                           text_response("done")),
                            **guarded(**gating))
      tool.call({ "prompt" => "read it" }, invocation)
      record.child(store).to_a
            .select { |turn| turn.role == "user" }
            .flat_map(&:content)
            .find { |block| block["type"] == "tool_result" }
    end

    it "sends the child's read of .env through the same approval policy its parent asks" do
      result = child_reads(secret, gate_policy: Lain::Middleware::Gate::DenyAll.new, sensitivity:)

      expect(result["is_error"]).to be(true)
      expect(result["content"]).to include("approval denied")
      expect(result["content"]).to include("read_file")
    end

    # The other half of the discriminator, and the mutation guard: with the
    # policy absent the identical call is NOT gated and the bytes come back. An
    # assertion that only pinned the refusal would pass against a gate that
    # refused every read there is.
    it "leaves the same read ungated when no sensitivity policy travelled the seam" do
      result = child_reads(secret, gate_policy: Lain::Middleware::Gate::DenyAll.new)

      expect(result["is_error"]).to be(false)
      expect(result["content"]).to include("TOKEN=shhh")
    end

    it "leaves an ordinary path ungated, so the boundary is the path and not the tool" do
      ordinary = File.join(tmpdir, "notes.md")
      File.write(ordinary, "nothing secret")

      result = child_reads(ordinary, gate_policy: Lain::Middleware::Gate::DenyAll.new, sensitivity:)

      expect(result["is_error"]).to be(false)
      expect(result["content"]).to include("nothing secret")
    end

    # Two spawns deep, which is the level the direct-child examples above cannot
    # see. The seam travels by {Subagent#descend} -> {ChildBuilder#config} ->
    # `@seam.with(parent:)`, so a GRANDCHILD's gate is built from a COPY of the
    # seam rather than from the object the session wired. A `with` that dropped
    # the member, or a `descend` that rebuilt the seam from its required members
    # only, would leave the DEEPEST agent -- the least supervised one in the run
    # -- the only one able to read the file.
    #
    # The grandchild's tool_result is read off the request that FOLLOWS it,
    # because the record's child is the outer spawn's timeline and the grandchild's
    # own is nested one further down.
    def nesting_provider
      mock(tool_response(["c1", "subagent", { "prompt" => "go deeper" }]),
           tool_response(["g1", "read_file", { "path" => secret }]),
           text_response("grandchild done"),
           text_response("child done"))
    end

    def two_deep(provider, **seam)
      reader = Lain::Toolset.new([Lain::Tools::ReadFile.new])
      inner = build_subagent(provider:, max_depth: 9, toolset: reader, **seam)
      build_subagent(provider:, max_depth: 2, toolset: Lain::Toolset.new(reader.to_a + [inner]),
                     policy: spawn_policy(only: %i[read_file subagent]), **seam)
    end

    def grandchild_result(**gating)
      provider = nesting_provider
      two_deep(provider, **guarded(**gating)).call({ "prompt" => "start" }, invocation)

      provider.requests[2].messages.flat_map { |message| message["content"] }
                          .find { |block| block.is_a?(Hash) && block["type"] == "tool_result" }
    end

    it "gates a GRANDCHILD's read of .env, two spawns deep" do
      refusal = grandchild_result(gate_policy: Lain::Middleware::Gate::DenyAll.new, sensitivity:)

      expect(refusal["is_error"]).to be(true)
      expect(refusal["content"]).to include("approval denied")
    end

    # The control, without which a probe that gated every read there is would
    # score as a pass at this depth too.
    it "hands the grandchild the bytes when no policy travelled the seam" do
      leaked = grandchild_result(gate_policy: Lain::Middleware::Gate::DenyAll.new)

      expect(leaked["is_error"]).to be(false)
      expect(leaked["content"]).to include("TOKEN=shhh")
    end

    # ---- A DENIED path, which no approval lifts at any depth ----------------
    #
    # The examples above prove a child's gate ASKS. This proves the child's
    # stack also REFUSES outright, which is a different layer
    # ({Middleware::Sensitivity}) built by the same {CLI::ToolGuard} from the
    # same seam. Built for the parent alone it would reach every parent and no
    # child, so a subagent could read what its parent may not -- the same
    # inversion closed above, one axis over.
    #
    # `secret` is overridden rather than added beside: `child_reads`,
    # `nesting_provider`, `two_deep` and `grandchild_result` all read it, so
    # pointing it at a DENIED name reuses that whole apparatus unchanged and
    # the two blocks stay comparable line for line. `.netrc` is a name rule, so
    # it denies wherever it sits.
    describe "and a DENIED path, which no approval can lift" do
      let(:secret) do
        path = File.join(tmpdir, ".netrc")
        File.write(path, "machine example.com password hunter2")
        path
      end

      # The layer composition itself -- which layer sits outside which, over
      # one policy object, on both postures and through the board delegator --
      # is pinned in spec/lain/tools/subagent_gate_spec.rb against the stack a
      # built child really holds. What stays here is the behaviour at depth.
      #
      # LEVEL 4 -- a real spawn, a real ReadFile, and the bytes really on disk.
      # ApproveAll on purpose: the point is that approving everything does not
      # lift this, so the gate axis cannot be what produced the refusal.
      it "refuses a CHILD's read of a denied path though its gate approves everything" do
        result = child_reads(secret, gate_policy: Lain::Middleware::Gate::ApproveAll.new, sensitivity:)

        expect(result["is_error"]).to be(true)
        expect(result["content"]).to include("protected path", secret)
        expect(result["content"]).not_to include("hunter2")
      end

      # The control. Without it an assertion that only pinned the refusal would
      # pass against a chain that refused every read there is.
      it "hands the child the bytes when no policy travelled the seam" do
        leaked = child_reads(secret, gate_policy: Lain::Middleware::Gate::ApproveAll.new)

        expect(leaked["is_error"]).to be(false)
        expect(leaked["content"]).to include("hunter2")
      end

      it "leaves an ordinary path alone, so the refusal is not a blanket one" do
        ordinary = File.join(tmpdir, "notes.md")
        File.write(ordinary, "nothing secret")

        result = child_reads(ordinary, gate_policy: Lain::Middleware::Gate::ApproveAll.new, sensitivity:)

        expect(result["is_error"]).to be(false)
        expect(result["content"]).to include("nothing secret")
      end

      # THE inversion test: the DEEPEST agent in the run, the least supervised
      # one, reached through a seam COPY that `descend` rebuilt.
      it "refuses a GRANDCHILD's read of a denied path, two spawns deep" do
        refusal = grandchild_result(gate_policy: Lain::Middleware::Gate::ApproveAll.new, sensitivity:)

        expect(refusal["is_error"]).to be(true)
        expect(refusal["content"]).to include("protected path", secret)
        expect(refusal["content"]).not_to include("hunter2")
      end

      it "hands the grandchild the bytes when no policy travelled the seam" do
        leaked = grandchild_result(gate_policy: Lain::Middleware::Gate::ApproveAll.new)

        expect(leaked["is_error"]).to be(false)
        expect(leaked["content"]).to include("hunter2")
      end
    end
  end

  # ---- Scope expansion: the observer reaches Lineage from the outside --------

  # The live session scribe attaches at the TOOL's constructor (the only seam
  # the exe wires), so Subagent must forward an `observer:` to the Lineage it
  # builds -- an observer nobody can wire from the exe is silent record loss
  # one level up.
  describe "the injectable observer" do
    # This seam carries more than it once did: the child's own turns ride it too,
    # between the :spawn and the :message, because the session record cannot
    # reach them any other way -- a Timeline walk sees ONE chain, and the
    # scribe's is the parent's. `@log` is unmoved: it is {Lineage}'s
    # append-only read side, and a child turn is not lineage.
    # The middle of the sequence is independent evidence, not a restatement:
    # the child's turns are walked from the Store using the digest the
    # :message recorded, so an observer that dropped them, reordered the pair
    # around them, or emitted either twice fails this `eq`.
    it "sees the :spawn, the child's own turns, and the :message, with @log still receiving the two" do
      log = Lain::Tools::Subagent::Log.new
      tool = described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider: mock(text_response("did the thing")), context_factory: -> { child_context },
        toolset: union, policy: spawn_policy, parent:,
        log:, observer: record
      )

      result = tool.call({ "prompt" => "go" }, invocation)
      child = record.child(store)

      expect(result).to be_ok
      expect(record.events).to eq([record.spawn, *child.ancestors.to_a.reverse, record.message])
      expect(log.to_a).to eq([record.spawn, record.message])
    end

    # What replaced the tool's own `@last_*` record. A spec asks the EVENTS:
    # the :spawn says what the child was granted and where it forked from, the
    # :message names the child's final turn, and the shared Store turns that
    # digest back into the child's own Timeline -- so the identity is verified
    # against the record rather than against an ivar the tool kept.
    it "is how a spec reads a spawn's record: the spawn, the child's identity, and its answer" do
      tool = build_subagent(provider: mock(text_response("child answer")))

      expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok
      expect(record.spawn.kind).to eq(:spawn)
      expect(record.spawn.body.fetch("spawned_from")).to eq(parent.head_digest)
      expect(record.message.body.fetch("result")).to eq("child answer")
      expect(record.child(store).head.content.find { |block| block["type"] == "text" }["text"])
        .to eq("child answer")
    end

    it "defaults to no observer, every existing path byte-identical" do
      tool = described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider: mock(text_response("done")), context_factory: -> { child_context },
        toolset: union, policy: spawn_policy, parent:
      )
      expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok
    end
  end

  # ---- A child's escalation, with no queue for a human to answer from -------
  #
  # {Tools::Subagent::Seam}'s DEFAULT `askers:` is
  # {Tools::Subagent::NoAskers} -- every fixture above this line spawns over
  # it, since none of them wires a real {CLI::Wiring::Askers}. A child
  # enrolled that way used to hold a bare {AskHuman} that wrote its Q and then
  # parked FOREVER: nothing was ever going to answer it, because nothing
  # announced it to anyone. {NoAskers} now enrols an
  # {Tools::AskHuman::Unattended} instead, so the refusal is immediate and the
  # child's own dispatch never blocks on a human it had no way to reach.
  describe "a child's escalation with nowhere to relay to" do
    def asks_with_no_queue = tool_response(["c1", "ask_human", { "question" => "which db?" }])

    it "refuses the escalation by name, and hands the child that refusal as its answer rather than waiting" do
      tool = build_subagent(provider: mock(asks_with_no_queue, text_response("proceeded without an answer")))

      result = tool.call({ "prompt" => "go" }, invocation)

      # The child's own loop survived the refusal and went on to its final
      # turn -- nothing about the escalation being unreachable stops the spawn
      # itself from completing.
      expect(result).to be_ok
      refusal = record.child(store).to_a.flat_map(&:content).find { |block| block["type"] == "tool_result" }
      expect(refusal["is_error"]).to be(true)
      expect(refusal["content"]).to include("no human mailbox is reachable")
      expect(refusal["content"]).not_to include("--non-interactive")
    end
  end

  # ---- A child of its own may ask the human ---------------------------------
  #
  # The capability policy this chunk reverses. A subagent used to be denied
  # `ask_human` deliberately ({CLI::Wiring::ToolsetBuild}'s layering comment);
  # it now holds one of its OWN -- never the parent's, whose questions would be
  # attributed to the parent's chain and whose promise the parent's
  # {AskHuman::Outstanding} holds -- enrolled per spawn on the run's ONE
  # {CLI::Wiring::Askers}. That is what makes several question sets pending at
  # once, which is the case the inbox has always rendered for and the reply
  # path could not serve until the directory routed by name.
  #
  # Driven through the REAL arrival seam rather than through a directory alone.
  # A plain {AskHuman} writes Q to the Store and announces to nobody, and
  # {Event::Projection#pending} reads the Store -- so every other claim in this
  # block passes for a child whose questions never reach the TTY. The queue,
  # and the sender the arrival carries, are what say they do.
  describe "asking the human from inside a child" do
    let(:askers) { Lain::CLI::Wiring::Askers.new(observer: Lain::Event::ChainWriter::Null.new) }

    # The chat the human is having, holding its own asker on the SAME seam --
    # so "parent and child are pending at once" is a claim about two real
    # askers and one queue, not about one asker asked twice.
    let(:parent_asker) { askers.enrol(parent, agent: "lain").asker }

    def asking_seam(provider)
      Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { child_context }, parent:, askers:,
                                      tool_middleware: ToolRegistry::UNGUARDED, observer: record)
    end

    def asking_subagent(provider, toolset: union, max_depth: 1, name: "subagent",
                        policy: spawn_policy(only: []), **over)
      described_class.new(seam: asking_seam(provider), toolset:, policy:, max_depth:, name:, **over)
    end

    def asks(question = "which db?") = tool_response(["c1", "ask_human", { "question" => question }])

    def arrival(task)
      pumped_until(task) { !askers.questions.empty? }
      askers.questions.dequeue
    end

    # Runs a spawn that PARKS on the human, and stops its fiber on every exit.
    #
    # The `ensure` is the whole reason these examples can FAIL. A dispatch that
    # asks a question does not return until the set is answered, so an
    # expectation that does not hold -- or the timeout above -- raises out of
    # the `Sync` while the child's fiber is still parked on `Promise#await`,
    # and a raise out of a Sync with a parked child NEVER RETURNS. The process
    # wedges, and a killed run prints "1 example, 0 failures" with no progress
    # character: a green line meaning nothing was measured, in the exact shape
    # a dead `parallel_rspec` worker takes. Stopping the task first is what
    # turns a silent child into a failing example instead of a hang, and it is
    # why every parked example below goes through this method or copies it.
    def spawning(task, tool)
      run = task.async { yield_result(tool) }
      yield run
    ensure
      run.stop
    end

    # The dispatch itself, on the child's fiber. `@dispatched` rather than a
    # block-local so `spawning`'s caller can read the result after the fiber
    # has been stopped as well as after it has finished.
    def yield_result(tool) = @dispatched = tool.call({ "prompt" => "go" }, invocation)

    attr_reader :dispatched

    # An actor parks the same way a one-shot dispatch does, so it is stopped on
    # every exit for `spawning`'s reason. {Actor#stop} is idempotent, so the
    # examples that stop it themselves are unaffected by this.
    def launching(tool, prompt: "go")
      actor = tool.launch_actor(prompt, worker_env: Lain::WorkerEnv.default)
      yield actor
    ensure
      actor&.stop
    end

    def actor_tool
      asking_subagent(mock(asks, text_response("done")), mode: :actor, log: Lain::Tools::Subagent::Log.new)
    end

    def unroutable!(digest)
      expect { askers.directory.reply("too late", digest) }
        .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion, /cannot be answered/)
    end

    # {Directory#size} counts NAMES, so a registration that never opened one is
    # invisible to it -- and an enrolment stranded by a failed launch is
    # exactly that shape. This reaches for the count the public surface does
    # not publish, because the alternative is an assertion that cannot fail.
    def registrations = askers.directory.instance_variable_get(:@registrations).size

    # Ask, arrive, answer, settle -- the full round trip, with the fiber
    # guaranteed stopped whichever step gives out.
    def answered(tool, answer: "postgres")
      item = nil
      Sync do |task|
        spawning(task, tool) do |run|
          item = arrival(task)
          askers.directory.reply(answer, item.digest)
          run.wait
        end
      end
      [dispatched, item]
    end

    # The session such a run RECORDS. A child's question cites the head the
    # CHILD stood at when it asked, and the lineage `"final"` edge cites the
    # child's last turn -- neither of which any `turn` record carried, because
    # the scribe walks one chain and it is the parent's. Rebuilding such a file
    # raised Store::MissingObject, which is not even the Corrupt the resume path
    # knows how to refuse, so every session with a subagent question in it was
    # unforkable.
    describe "the session record it leaves behind" do
      let(:journal_io) { StringIO.new }
      let(:journal) { Lain::Journal.new(io: journal_io) }
      let(:session_context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
      let(:scribe) do
        Lain::SessionRecord::Scribe.new(journal:, context: session_context, toolset: union,
                                        workspace: Lain::Workspace.empty)
      end
      let(:observer) { ->(event) { scribe.call(event) } }
      # The chronicle's own wiring: ONE scribe observes the whole funnel, the
      # askers' Q/A included.
      let(:askers) { Lain::CLI::Wiring::Askers.new(observer:) }

      def recorded_tool(provider: mock(asks, text_response("done")), toolset: union,
                        policy: spawn_policy(only: []), max_depth: 1)
        described_class.new(
          seam: Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { child_context },
                                                parent:, askers:, observer:,
                                                tool_middleware: ToolRegistry::UNGUARDED),
          toolset:, policy:, max_depth:
        )
      end

      # A spawn TWO deep, where the parking is the grandchild's. A grandchild's
      # :spawn cites the CHILD's live head exactly as a question cites its
      # asker's, and a grandchild parked mid-iteration leaves the child's
      # iteration unreturned too.
      def nested_tool
        inner = recorded_tool(provider: mock(asks("which db?"), text_response("inner done")), max_depth: 3)
        recorded_tool(provider: mock(tool_response(["s1", "subagent", { "prompt" => "deeper" }]),
                                     text_response("outer done")),
                      toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new, inner]), max_depth: 3)
      end

      # A closed file for a run that ASKED and was answered: the shape every
      # fixture here had before the parked one below it.
      def answered_journal
        answered(recorded_tool)
        settled_journal
      end

      # And the shape none of them had: the question reaches the queue, nobody
      # answers, and the child's fiber is stopped where it stands -- a Ctrl-C,
      # or a run that outlived the human. The iteration that asked never
      # returns, so the turn the question cites reaches the file only because
      # the child's own agent settled it before the tool ran. Every fixture that
      # answers the question would hide a miss.
      def parked_journal(tool = recorded_tool)
        Sync { |task| spawning(task, tool) { arrival(task) } }
        settled_journal
      end

      def cited_by(bytes)
        recording = Lain::Bench::Session.load(bytes.each_line)
        [recording, recording.messages.flat_map(&:causal_parents).uniq]
      end

      def settled_journal
        scribe.catch_up(parent)
        scribe.close(reason: :exit)
        journal_io.string
      end

      def recorded_session = Lain::Bench::Session.load(answered_journal.each_line)

      # The two doors a human reloads a session through. The refusal lives at
      # LOAD, so `--fork` and `--resume` meet it alike -- and both read a FILE,
      # which is the one shape neither can be driven without.
      def reopened(bytes)
        Dir.mktmpdir do |state_home|
          paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home })
          File.write(File.join(paths.sessions_dir, "20260101T000000-1.ndjson"), bytes)
          yield Lain::CLI::Resume.new(paths:)
        end
      end

      def fork_selector = "20260101@#{parent.head_digest.delete_prefix("blake3:")[0, 12]}"

      it "reloads, and the fork point checks out, with no dangling causal parent" do
        recording = nil

        expect { recording = recorded_session }.not_to raise_error
        expect(recording.timeline.checkout(recording.timeline.head_digest).head_digest)
          .to eq(parent.head_digest)
      end

      it "carries every digest its message records cite" do
        recording = recorded_session
        cited = recording.messages.flat_map(&:causal_parents).uniq

        expect(cited).to all(satisfy { |digest| recording.timeline.store.key?(digest) })
      end

      # The answered path, at the doors themselves rather than at the load
      # alone: it worked before this card and has to go on working.
      it "forks and resumes when the question was answered" do
        reopened(answered_journal) do |resume|
          expect(resume.fork(selector: fork_selector).timeline.head_digest).to eq(parent.head_digest)
          expect(resume.call.timeline.head_digest).to eq(parent.head_digest)
        end
      end

      # The settle before the tool runs and the catch-up its iteration runs
      # afterwards share ONE feed, and the stop digest advancing per turn is
      # the whole of why the second walks nothing. Doubled records would be
      # this file's own claim about the run, told twice.
      it "journals each child turn exactly once when the question was answered" do
        answered_journal
        recorded = journal_io.string.each_line.filter_map do |line|
          record = JSON.parse(line)
          record["digest"] if record["type"] == "child_turn"
        end

        expect(recorded).to eq(recorded.uniq)
        expect(recorded).not_to be_empty
      end

      # A chat's own spawn, from an agent wired as the chronicle wires one. What
      # the file holds is read at the instant the :spawn reaches the scribe,
      # before the scribe writes it.
      it "writes a chat agent's spawn after the turn its causal parent names" do
        agent = nil
        held = nil
        recorded = ->(digest) { journal_io.string.each_line.any? { |line| JSON.parse(line)["digest"] == digest } }
        watching = lambda do |event|
          held = recorded.call(event.causal_parents.first) if event.kind == :spawn
          scribe.call(event)
        end
        tool = described_class.new(
          seam: Lain::Tools::Subagent::Seam.new(provider: mock(text_response("child done")),
                                                context_factory: -> { child_context }, parent: -> { agent.timeline },
                                                observer: watching, tool_middleware: ToolRegistry::UNGUARDED),
          toolset: union, policy: spawn_policy(only: []), max_depth: 1
        )
        agent = Lain::Agent.new(
          provider: mock(tool_response(["tu_1", "subagent", { "prompt" => "go" }]), text_response("parent done")),
          context: session_context, toolset: Lain::Toolset.new([tool]), timeline: Lain::Timeline.empty(store:),
          turn_middleware: Lain::Middleware::Stack.new([Lain::Middleware::JournalTurns.new(
            scribe:, timeline: -> { agent.timeline }
          )])
        )

        agent.ask("spawn one")

        expect(held).to be(true)
      end

      describe "when the question is never answered" do
        it "carries every digest the parked question cites" do
          recording, cited = cited_by(parked_journal)

          expect(cited).to all(satisfy { |digest| recording.timeline.store.key?(digest) })
        end

        it "forks at its head" do
          reopened(parked_journal) do |resume|
            expect(resume.fork(selector: fork_selector).timeline.head_digest).to eq(parent.head_digest)
          end
        end

        it "resumes onto that head" do
          reopened(parked_journal) do |resume|
            expect(resume.call.timeline.head_digest).to eq(parent.head_digest)
          end
        end

        # `fresh` gives the child a root with no render edge out of it;
        # `inherit` forks the parent, so the child's first turn RENDERS onto a
        # parent head whose own turn record is not written yet either.
        it "carries every cited digest under an inherit prefix too" do
          inheriting = recorded_tool(policy: spawn_policy(prefix: :inherit, only: []))
          recording, cited = cited_by(parked_journal(inheriting))

          expect(cited).to all(satisfy { |digest| recording.timeline.store.key?(digest) })
        end

        # The other disposition a parked question can end in: nobody COULD
        # answer it, so the record is an `unanswered` message rather than an A.
        it "carries every cited digest when the question ends unanswered" do
          tool = recorded_tool
          Sync do |task|
            spawning(task, tool) do |run|
              item = arrival(task)
              askers.directory.reply(Lain::Tools::AskHuman::Unanswered.new, item.digest)
              run.wait
            end
          end
          recording, cited = cited_by(settled_journal)

          expect(cited).to all(satisfy { |digest| recording.timeline.store.key?(digest) })
        end

        # One builder, two children parked at once. The feed a spawn settles
        # through is built PER SPAWN for exactly this: a shared feed would walk
        # one sibling's turns against the other's stop digest.
        it "carries every cited digest when two siblings park at once" do
          tool = recorded_tool(provider: mock(asks("first?"), asks("second?"), text_response("done")))
          Sync do |task|
            siblings = [task.async { tool.call({ "prompt" => "a" }, invocation) },
                        task.async { tool.call({ "prompt" => "b" }, invocation) }]
            pumped_until(task) { askers.questions.size >= 2 }
            siblings.each(&:stop)
          end
          recording, cited = cited_by(settled_journal)

          expect(cited).to all(satisfy { |digest| recording.timeline.store.key?(digest) })
        end

        # The SECOND question parks, so this settle runs on a feed whose
        # stop digest the first iteration's catch-up already advanced.
        it "carries every cited digest when a child parks on its second question" do
          tool = recorded_tool(provider: mock(asks("first?"), asks("second?"), text_response("done")))
          Sync do |task|
            spawning(task, tool) do
              askers.directory.reply("postgres", arrival(task).digest)
              arrival(task)
            end
          end
          recording, cited = cited_by(settled_journal)

          expect(cited).to all(satisfy { |digest| recording.timeline.store.key?(digest) })
        end
      end

      # One level up, where the record's exposure is the grandchild's :spawn
      # rather than its question -- the same head, cited by a different
      # record. A depth qualifier nobody wrote is not a scope boundary, so this
      # door has to open too.
      describe "when the parked question is a GRANDchild's" do
        it "carries every digest its records cite" do
          recording, cited = cited_by(parked_journal(nested_tool))

          expect(cited).to all(satisfy { |digest| recording.timeline.store.key?(digest) })
        end

        it "forks and resumes" do
          reopened(parked_journal(nested_tool)) do |resume|
            expect(resume.fork(selector: fork_selector).timeline.head_digest).to eq(parent.head_digest)
            expect(resume.call.timeline.head_digest).to eq(parent.head_digest)
          end
        end
      end
    end

    it "offers ask_human to a spawned child, though the union it attenuates from holds none" do
      provider = mock(text_response("done"))

      asking_subagent(provider).call({ "prompt" => "go" }, invocation)

      expect(union.names).not_to include("ask_human")
      expect(provider.last_request.tools.map { |tool| tool["name"] }).to include("ask_human")
    end

    # THE acceptance criterion of this card: announcement lives in `#ask`'s
    # `notify:` seam, so a child wired to a bare asker (no notify: at all)
    # satisfies every other example here while its questions reach nobody.
    it "lands a child's question on the arrival queue a parent's goes to, under the child's own name" do
      tool = asking_subagent(mock(asks, text_response("done")), name: "researcher")

      result, item = answered(tool)

      expect(result).to be_ok
      expect(result.content).to eq("done")
      expect(item.question.to_s).to eq("which db?")
      expect(item.from).to eq("researcher")
    end

    # Who the human is TOLD is asking, at both surfaces that render a sender.
    #
    # The identifier is the asker's NAME, not its chain correlation.
    # `ChainWriter.correlation_of` is a chain's ROOT digest and an `:inherit`
    # child is `parent.fork`, so parent and child share a root permanently --
    # and `:inherit` is the DEFAULT posture for a `@role` spawn
    # (`middleware/skill_dispatch.rb`), which makes that the COMMON case
    # rather than a corner of one. Both postures are driven for exactly that
    # reason: the point of naming the asker is that who-is-asking stops
    # depending on which prefix strategy a spawn happened to use.
    describe "who the human is told is asking" do
      # A parent and a child holding a question each, at the same time, over
      # one queue -- the situation this whole card exists to create.
      def pending_pair(prefix)
        tool = asking_subagent(mock(asks("deploy now?"), text_response("done")),
                               policy: spawn_policy(only: [], prefix:), announces_as: "researcher")
        Sync { |task| spawning(task, tool) { |run| both_asked(task, run) } }
        @pair
      end

      # The parent asks beside the child, both are listed, then both are
      # answered so the dispatch can settle rather than the fiber being cut.
      def both_asked(task, run)
        parent_asker.ask("which db?")
        pumped_until(task) { askers.questions.size == 2 }
        @pair = answered_pair
        run.wait
      end

      # Both listed items, taken off the queue and answered -- so the child's
      # dispatch settles on its own rather than being cut by `spawning`'s
      # ensure, which would leave the example proving less than it says.
      def answered_pair
        [askers.questions.dequeue, askers.questions.dequeue]
          .each { |item| askers.directory.reply("ok", item.digest) }
      end

      # The sender column, as a surface prints it: both clamp, and two names
      # that differ only PAST the clamp collide on screen even though the
      # values do not.
      def senders(lines) = lines.map { |line| line.split("  ").first }

      # Surface 1 -- the TTY. `Frontend::TTY::Inbox` renders `item.from` in
      # both places it names an asker: the arrival note (`#arrival`, through
      # `HumanReplies#render_arrival`) and the `/inbox` drain (`#line_for`).
      # Clamped here through the shared row, which is where the width the
      # surfaces collide on now has its one spelling.
      def tty_senders(items)
        items.map { |item| Lain::Tools::AskHuman::InboxRow.sender(item.from) }
      end

      # Surface 2 -- the nvim inbox buffer. It does NOT consume the arrival:
      # it folds the RECORD stream ({Telemetry::Message}, the shape its own
      # spec drives) and builds its own row, so what it renders is
      # `event.from` and never the name the arrival carries.
      def nvim_senders(items)
        view = Lain::Frontend::Neovim::InboxView.new(store:, clock: -> { Time.at(0) })
        senders(items.map { |item| Lain::Telemetry::Message.from_event(store.fetch(item.digest)) }
                     .map { |record| view.update(record) }.last)
      end

      %i[fresh inherit].each do |prefix|
        it "names the child apart from its parent at the TTY drain, on a #{prefix} spawn" do
          expect(tty_senders(pending_pair(prefix))).to contain_exactly("lain", "researcher")
        end
      end

      # The old identifier, named so a regression to it cannot pass: this is
      # the exact value that made an `:inherit` child indistinguishable.
      it "uses the asker's name and not the correlation an :inherit child shares with its parent" do
        items = pending_pair(:inherit)

        expect(items.map(&:from)).not_to include(Lain::Event::ChainWriter.correlation_of(parent))
      end

      it "names the child apart from its parent in the nvim inbox, on a fresh spawn" do
        expect(nvim_senders(pending_pair(:fresh)).uniq.size).to eq(2)
      end

      # Was PINNED PENDING, and it is the half the arrival fix did
      # NOT reach: `HumanReplies::InboxItem.asked` prefers the asker's name,
      # which closes the TTY, but the nvim view never sees an InboxItem -- it
      # folds the record stream, so it rendered the shared root digest and the
      # two rows collided. Closed by the NAME riding the RECORD: the asker
      # writes it into the Q event's body ({Tools::AskHuman::ASKED_BY}) and the
      # view reads it there, so both surfaces name an asker the same way.
      it "names the child apart from its parent in the nvim inbox, on an inherit spawn" do
        expect(nvim_senders(pending_pair(:inherit)).uniq.size).to eq(2)
      end
    end

    it "carries the human's answer back into the child's own conversation" do
      tool = asking_subagent(mock(asks, text_response("done")))

      answered(tool, answer: "postgres, it is already provisioned")

      delivered = record.child(store).to_a.flat_map(&:content).select { |block| block["type"] == "tool_result" }
      expect(delivered.map { |block| block["content"] }).to eq(["postgres, it is already provisioned"])
    end

    # Driven through the REAL enrolment path -- {Lain::CLI::Wiring::Askers}, the
    # same seam every example above spawns a child over -- rather than through a
    # hand-built {Tools::AskHuman}: a spec that constructs the asker itself
    # proves the relay mechanism works, not that a child asker built the way
    # {Tools::Subagent::ChildBuilder#build} builds one actually relays.
    #
    # `item.digest` -- what the queue announced and what a reply would name --
    # is the OUTERMOST hop, addressed to the literal human so `pending("human")`
    # still finds it; the child's OWN question, addressed to the parent, is
    # its causal parent. Both hops are in the record, which is the whole of
    # what "reaches the human through its parent" means.
    it "reaches the human through its parent, and the record shows both hops" do
      tool = asking_subagent(mock(asks, text_response("done")))
      parent_correlation = Lain::Event::ChainWriter.correlation_of(parent)

      _dispatched, item = answered(tool, answer: "postgres")
      relayed = store.fetch(item.digest)
      own_question = store.fetch(relayed.causal_parents.first)

      expect(relayed.to).to eq(Lain::Tools::AskHuman::HUMAN)
      expect(relayed.from).to eq(parent_correlation)
      expect(own_question.to).to eq(parent_correlation)
      expect(own_question.from).not_to eq(parent_correlation)
    end

    # The pair must stay legible however far it relayed: a reader walking Q to
    # A finds the answer attributed to the SAME address the outermost Q was
    # sent to -- the literal human, since that is who actually typed it --
    # never the parent it passed through on the way. {Directory#reply} hands
    # back the A event it wrote, so this reads the attribution off the real
    # reply path rather than re-deriving it.
    it "answers a child's question from the address its outermost hop was sent to" do
      tool = asking_subagent(mock(asks, text_response("done")))

      Sync do |task|
        spawning(task, tool) do |run|
          item = arrival(task)
          a = askers.directory.reply("postgres", item.digest)

          expect(a.from).to eq(Lain::Tools::AskHuman::HUMAN)
          expect(a.causal_parents).to include(item.digest)
          run.wait
        end
      end
    end

    # Two hops deep: a GRANDchild relays through the child that spawned it,
    # which relays through the run's own chat. {ChildBuilder#config} is what
    # carries the road that far -- a child's OWN escalation ({Chain#escalation})
    # becomes the escalation a NESTED seam hands to whatever it spawns, so a
    # grandchild's question passes through its immediate parent rather than
    # skipping straight to whichever ancestor happens to be attended. The
    # SAME body rides every hop, {Tools::AskHuman::ASKED_BY} included, so the
    # human learns which ROLE originally asked -- "researcher" -- never
    # "subagent", the name of whichever tool relayed it.
    it "tells the human which role originally asked, two relay hops deep" do
      grandchild = asking_subagent(mock(asks, text_response("grandchild done")),
                                   name: "researcher", announces_as: "researcher", max_depth: 3)
      middle = asking_subagent(mock(tool_response(["m1", "researcher", { "prompt" => "deeper" }]),
                                    text_response("middle done")),
                               toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new, grandchild]), max_depth: 3)

      Sync do |task|
        spawning(task, middle) do |run|
          item = arrival(task)
          relayed = store.fetch(item.digest)

          expect(relayed.to).to eq(Lain::Tools::AskHuman::HUMAN)
          expect(relayed.body.fetch(Lain::Tools::AskHuman::ASKED_BY)).to eq("researcher")

          askers.directory.reply("postgres", item.digest)
          run.wait
        end
      end
    end

    it "keeps the parent and the child pending at once, and the inbox projection lists both" do
      tool = asking_subagent(mock(asks("deploy now?"), text_response("done")))

      Sync do |task|
        spawning(task, tool) do |run|
          parent_asker.ask("which db?")
          pumped_until(task) { askers.questions.size == 2 }
          items = [askers.questions.dequeue, askers.questions.dequeue]

          expect(parent_asker).to be_pending
          expect(items.map(&:from).uniq.size).to eq(2)
          expect(Lain::Event::Projection.new(items.map { |item| store.fetch(item.digest) })
                                        .pending("human").to_a.size).to eq(2)

          items.each { |item| askers.directory.reply("ok", item.digest) }
          run.wait
        end
      end
    end

    it "resolves each set through the asker that asked it, never through whoever asked last" do
      tool = asking_subagent(mock(asks("deploy now?"), text_response("done")))

      Sync do |task|
        spawning(task, tool) do |run|
          child_item = arrival(task)
          parent_set = parent_asker.ask("which db?")

          askers.directory.reply("postgres", parent_set.digest)

          expect(parent_asker.last_answer.body["answer"]).to eq("postgres")
          expect(dispatched).to be_nil

          askers.directory.reply("kubernetes", child_item.digest)
          run.wait
        end
      end

      expect(dispatched.content).to eq("done")
      delivered = record.child(store).to_a.flat_map(&:content).select { |block| block["type"] == "tool_result" }
      expect(delivered.map { |block| block["content"] }).to eq(["kubernetes"])
    end

    # The union {ChildBuilder#child_union} hands a grandchild is the base one
    # again, so the capability rides the SEAM rather than the set -- which is
    # the whole reason a descended copy re-injects the seam verbatim.
    it "gives a grandchild an asker of its own" do
      provider = mock(tool_response(["c1", "subagent", { "prompt" => "deeper" }]),
                      text_response("grandchild done"), text_response("child done"))
      inner = asking_subagent(provider, max_depth: 9)
      outer = asking_subagent(provider, toolset: Lain::Toolset.new(union.to_a + [inner]), max_depth: 2)

      expect(outer.call({ "prompt" => "go" }, invocation)).to be_ok
      expect(provider.requests[1].tools.map { |tool| tool["name"] }).to include("ask_human")
    end

    # A role's `only:` says what an arm may TOUCH; `unattended` says it may not
    # PARK. The docent answers while a human stands mid-review waiting for the
    # line to change, so an asker granted past the attenuation would hang
    # exactly the answer the human is waiting on -- and `only:` cannot express
    # a tool the role must NOT hold, because the grant happens outside it.
    it "withholds the asker from an unattended spawn" do
      provider = mock(text_response("done"))
      tool = asking_subagent(provider, policy: spawn_policy(only: [], unattended: true))

      tool.call({ "prompt" => "go" }, invocation)

      expect(provider.last_request.tools.map { |rendered| rendered["name"] }).to eq(%w[echo read_file])
    end

    # {ChildBuilder#granted} runs TWICE -- once on the attenuated set and once
    # on the raw union -- and under `handler_union` it is the UNION the child is
    # shown and dispatched against. An `ask_human` surviving there is the
    # PARENT's, reachable by the very child the declaration muted.
    it "strips the parent's asker from an unattended child's dispatch union too" do
      provider = mock(text_response("done"))
      poisoned = Lain::Toolset.new(union.to_a + [Lain::Tools::AskHuman.new(parent:)])
      tool = asking_subagent(provider, toolset: poisoned,
                                       policy: spawn_policy(only: [], posture: :handler_union, unattended: true))

      tool.call({ "prompt" => "go" }, invocation)

      expect(provider.last_request.tools.map { |rendered| rendered["name"] }).to eq(%w[echo read_file])
    end

    # The other half of the same rule: an ATTENDED child still gets an asker,
    # and it is its OWN. The union here is poisoned with the parent's, whose
    # questions would be attributed to the parent's chain and whose promise the
    # parent's {AskHuman::Outstanding} holds -- so the sender the human is told
    # is the assertion that tells the two apart.
    it "still grants an attended child its own asker, announced as the child" do
      poisoned = Lain::Toolset.new(union.to_a + [parent_asker])
      tool = asking_subagent(mock(asks, text_response("done")), toolset: poisoned, name: "researcher",
                                                                policy: spawn_policy(only: [], posture: :handler_union))

      result, item = answered(tool)

      expect(result).to be_ok
      expect(item.question.to_s).to eq("which db?")
      expect(item.from).to eq("researcher")
    end

    # Retention runs from `register` to `deregister` and NOTHING else releases
    # it, so the release has to ride the lifetime that owns the child. For a
    # one-shot that lifetime IS the dispatch.
    it "releases a one-shot child's registration when its dispatch ends" do
      tool = asking_subagent(mock(asks, text_response("done")))

      result, item = answered(tool)

      expect(result).to be_ok
      unroutable!(item.digest)
    end

    # A question is listed until something in the record names it consumed, and
    # a stopped child's answering turn never comes. The spawn names it, on the
    # journal the live inbox surfaces fold.
    describe "a one-shot child stopped while its question is parked" do
      let(:feed_dir) { Dir.mktmpdir("subagent-stopped-question") }
      let(:feed) { Lain::StatusFeed.new(path: File.join(feed_dir, "state.json")) }
      let(:observed) do
        lambda do |event|
          feed << event
          record.call(event)
        end
      end
      let(:askers) { Lain::CLI::Wiring::Askers.new(observer: observed) }
      let(:telemetry) { Lain::Channel.new }

      after { FileUtils.rm_rf(feed_dir) }

      def stopped_while_parked
        seam = Lain::Tools::Subagent::Seam.new(provider: mock(asks, text_response("done")),
                                               context_factory: -> { child_context }, parent:, askers:,
                                               tool_middleware: ToolRegistry::UNGUARDED, observer: observed,
                                               telemetry:)
        tool = described_class.new(seam:, toolset: union, policy: spawn_policy(only: []), max_depth: 1)
        Sync { |task| spawning(task, tool) { arrival(task) } }
      end

      it "names the question set consumed, and the inbox count drops" do
        item = stopped_while_parked
        expect(feed.state.fetch("inbox_count")).to eq(1)

        retired = telemetry.drain.grep(Lain::Telemetry::QuestionsConsumed)
        retired.each { |consumed| feed << consumed }

        expect(retired.flat_map(&:digests)).to eq([item.digest])
        expect(feed.state.fetch("inbox_count")).to eq(0)
      end

      # Each ending write stands on its own: the completion refused, the
      # question is still named consumed, and the loss is on the record.
      it "still names the question consumed when the completion cannot be written" do
        refusing = lambda do |event|
          raise IOError, "the journal is closed" if event.kind == :message && event.body.key?("lifecycle")

          observed.call(event)
        end
        seam = Lain::Tools::Subagent::Seam.new(provider: mock(asks, text_response("done")),
                                               context_factory: -> { child_context }, parent:, askers:,
                                               tool_middleware: ToolRegistry::UNGUARDED, observer: refusing,
                                               telemetry:)
        tool = described_class.new(seam:, toolset: union, policy: spawn_policy(only: []), max_depth: 1)
        item = Sync { |task| spawning(task, tool) { arrival(task) } }

        written = telemetry.drain
        expect(written.grep(Lain::Telemetry::QuestionsConsumed).flat_map(&:digests)).to eq([item.digest])
        expect(written.grep(Lain::Tools::Subagent::Lineage::EndingNotRecorded).map(&:record)).to eq(["completion"])
      end

      it "journals the spawn's completion as stopped, naming the head the child parked at" do
        stopped_while_parked

        body = record.message.body
        expect(body.keys).to contain_exactly("lifecycle", "final")
        expect(body.fetch("lifecycle")).to eq(Lain::StatusFeed::SpawnLifecycle::STOPPED)
        expect(record.message.causal_parents).to contain_exactly(record.spawn.digest, body.fetch("final"))
        expect(feed.state.fetch("fleet")).to eq([])
      end
    end

    # And for an actor it is the lease that reaps the fiber. Both directions
    # are pinned: still routable while the actor runs (a second answer is
    # refused as ALREADY ANSWERED, by the registration's own tombstone), and
    # no longer routable once it has stopped (refused as unknown).
    it "releases a child's registration when its actor stops, so a late answer is refused not misrouted" do
      Sync do |task|
        launching(actor_tool) do |actor|
          item = arrival(task)
          askers.directory.reply("postgres", item.digest)
          actor.settle

          expect { askers.directory.reply("again", item.digest) }.to raise_error(Lain::Promise::AlreadyResolved)

          actor.stop

          unroutable!(item.digest)
          expect(parent_asker.last_answer).to be_nil
        end
      end
    end

    # The whole point of enrolling INSIDE the launch is that a launch which
    # never produced an actor must not leave an asker nothing will release:
    # the Actor reference goes with the raise, so nothing else could ever
    # `deregister` it. Driven through the seam's observer, which
    # {Event::ChainWriter#put} documents as raising OUT of the write.
    it "releases the child's registration when the launch itself raises" do
      seam = asking_seam(mock(text_response("unused"))).with(observer: ->(_e) { raise "the record is on fire" })
      tool = described_class.new(seam:, toolset: union, policy: spawn_policy(only: []),
                                 max_depth: 1, mode: :actor, log: Lain::Tools::Subagent::Log.new)

      Sync do
        expect { tool.launch_actor("go", worker_env: Lain::WorkerEnv.default) }.to raise_error(/the record is on fire/)
      end

      expect(registrations).to eq(0)
    end

    # The arrival note names what the child IS, not what the model calls the
    # tool. `research_subagent` is the one child path that ships today, and its
    # tool is named "subagent" because that is the model-facing name -- the
    # human must be told "researcher".
    it "announces under the spawn's own name, which need not be the model-facing tool name" do
      tool = asking_subagent(mock(asks, text_response("done")), name: "subagent", announces_as: "researcher")

      _result, item = answered(tool)

      expect(item.from).to eq("researcher")
    end

    it "falls back to the tool's own name when a spawn has no separate one" do
      tool = asking_subagent(mock(asks, text_response("done")), name: "subagent")

      _result, item = answered(tool)

      expect(item.from).to eq("subagent")
    end

    # ---- The `ensure` on Actor#stop, pinned --------------------------------
    #
    # That `ensure` is the entire reason this card touched `actor.rb`, and a
    # release written among the method's own lines would be skipped by BOTH of
    # its early exits -- silently, with every other example in this block
    # still green. Those two exits are also the shapes {Supervisor#stop}'s
    # rescue-less `each { farewell }` meets in a real teardown, so what is
    # pinned here is both halves: the release happens, and #stop stays
    # incapable of stranding the rows behind it.
    describe "the release on Actor#stop" do
      # A registered asker with a question outstanding, wearing an Actor that
      # has NOT been launched: the state a supervisor row is in when its
      # launch block raised, and the one `raise NotLaunched` returns from.
      def never_launched
        enrolled = askers.enrol(parent, agent: "orphan")
        digest = enrolled.asker.ask("who is stuck?").digest
        actor = Lain::Tools::Subagent::Actor.new(
          agent: instance_double(Lain::Agent), parent:, registration: enrolled.registration,
          lineage: Lain::Tools::Subagent::Lineage.new(policy: spawn_policy)
        )
        [actor, digest]
      end

      it "releases the registration of an actor that was never launched, and still refuses loudly" do
        Sync do
          actor, digest = never_launched

          expect { actor.stop }.to raise_error(Lain::Tools::Subagent::Actor::NotLaunched)

          unroutable!(digest)
        end
      end

      it "releases when stopped with the child's question still outstanding, and re-answers the same farewell" do
        Sync do |task|
          launching(actor_tool) do |actor|
            item = arrival(task)

            first = actor.stop
            second = actor.stop

            expect(second).to be(first)
            unroutable!(item.digest)
          end
        end
      end
    end
  end

  # ---- The staggered sibling fan-out ----------------------------------------
  #
  # The plumb this card adds: a REAL fan-out of sibling-template children
  # through {Stagger}, each child's {Agent} forwarding `on_stream_started` down
  # its own provider round trip. Sibling 1 dispatches alone; the provider's
  # first-token signal ({Provider::Mock}'s here, gated on `request.stream` just
  # as the live backends gate it) opens the gate and the rest release -- one
  # writable template prefix, N-1 byte-identical reuses. The stagger releases
  # land in the journal. The stagger POLICY in isolation is proven in
  # spec/lain/tools/subagent/stagger_spec.rb; these prove the wiring reaches it
  # THROUGH the provider signal.
  describe "the staggered sibling fan-out" do
    let(:template) { "You are one of a set of sibling workers over one shared brief. " * 20 }

    def sibling_template_policy(template)
      Lain::Tool::SpawnPolicy.new(
        prefix: Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate.new(template:),
        posture: :handler_union, only: %i[read_file]
      )
    end

    it "spawns each prompt as a sibling child, returning one final result per prompt in order" do
      provider = mock(text_response("a"), text_response("b"), text_response("c"))
      tool = build_subagent(provider:, policy: sibling_template_policy(template))

      results = tool.fan_out(%w[alpha beta gamma])

      expect(results.map(&:content)).to eq(%w[a b c])
      expect(results).to all(be_ok)
    end

    it "returns [] for an empty fan-out, spawning nothing" do
      tool = build_subagent(provider: mock(text_response("unused")))
      before = store.size

      expect(tool.fan_out([])).to eq([])
      expect(store.size).to eq(before)
    end

    # Sibling 1 begins streaming -> the rest release, journaled.
    it "releases the rest on sibling 1's stream-start, journaling the stagger with reason :stream_started" do
      journal = Lain::Channel.new
      provider = mock(text_response("a"), text_response("b"), text_response("c"))
      tool = build_subagent(provider:, policy: sibling_template_policy(template), journal:)

      tool.fan_out(%w[alpha beta gamma])

      events = journal.drain
      dispatched = events.grep(Lain::Tools::Subagent::Stagger::Dispatched)
      released = events.grep(Lain::Tools::Subagent::Stagger::Released)
      expect(dispatched.map(&:index)).to contain_exactly(0, 1, 2)
      expect(released.map(&:reason)).to eq([:stream_started])
    end

    # The first never streams -> the rest release on the degrade
    # path, journaled. A non-streaming child context is the honest analogue of a
    # provider that never signals: Mock gates its signal on `request.stream`, so
    # the whole fan-out falls through to Stagger's :degraded release rather than
    # hanging.
    it "degrades safely, releasing the rest journaled :degraded, when the first child never streams" do
      journal = Lain::Channel.new
      provider = mock(text_response("a"), text_response("b"))
      tool = described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider:, context_factory: -> { Lain::Context.new(model: "child-model", max_tokens: 256, stream: false) },
        toolset: union, policy: sibling_template_policy(template), parent:, journal:
      )

      results = nil
      expect { Timeout.timeout(2) { results = tool.fan_out(%w[alpha beta]) } }.not_to raise_error

      expect(results.map(&:content)).to eq(%w[a b])
      released = journal.drain.grep(Lain::Tools::Subagent::Stagger::Released)
      expect(released.map(&:reason)).to eq([:degraded])
    end
  end

  # ---- The Supervisor unrefuses the model-dispatched :actor ------------------
  #
  # The refusal reasoning stands for a BARE dispatch: Agent#ask's per-call
  # Sync owns any fiber a tool dispatch spawns, so a perform-launched actor
  # would park as ask's own child and wedge the loop. A running Supervisor is
  # the missing reactor above the Agent -- perform adopts the launch onto ITS
  # task, so the fiber outlives the ask and the dispatch returns the handle.
  describe "a model-dispatched :actor" do
    let(:actor_log) { Lain::Tools::Subagent::Log.new }

    def actor_mode_tool(*responses, supervisor:)
      described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider: mock(*responses), context_factory: -> { child_context },
        toolset: union, policy: spawn_policy, parent:,
        mode: :actor, log: actor_log, supervisor:
      )
    end

    # `supervisor.stop` is in an `ensure`, and that is not tidiness: the reactor
    # task it stops is a CHILD of this `Sync`, so a failed expectation that skips
    # the stop leaves `Sync` waiting on a task that never finishes -- the example
    # hangs instead of reporting, and with it every example after it in the file.
    # A mutation campaign found this the expensive way.
    it "launches under a running Supervisor: the spawn lands, the handle returns, no refusal" do
      supervisor = Lain::Supervisor.new
      Sync do |task|
        supervisor.run(task)
        tool = actor_mode_tool(text_response("actor ready"), supervisor:)

        result = tool.call({ "prompt" => "go" }, invocation)

        expect(result).to be_ok
        spawn = actor_log.to_a.find { |event| event.kind == :spawn }
        expect(spawn).not_to be_nil
        expect(result.content).to include(spawn.digest)
        expect(supervisor.map(&:address)).to eq([spawn.digest])
        expect(supervisor.map(&:role)).to eq(["subagent"])
      ensure
        supervisor.stop
      end
    end

    it "does not wedge the parent's ask: the loop settles while the actor persists" do
      supervisor = Lain::Supervisor.new
      Sync do |task|
        supervisor.run(task)
        tool = actor_mode_tool(text_response("actor ready"), supervisor:)
        parent_agent = Lain::Agent.new(
          provider: mock(tool_response(["a1", "subagent", { "prompt" => "go" }]), text_response("parent continues")),
          toolset: Lain::Toolset.new([tool]),
          context: Lain::Context.new(model: "parent", max_tokens: 256),
          timeline: Lain::Timeline.empty(store:)
        )

        response = parent_agent.ask("spawn an actor")

        expect(response.text).to eq("parent continues")
        actor = supervisor.first.actor
        expect(actor.settle).not_to be_dead
      ensure
        supervisor.stop
      end
    end

    # AC: no supervisor still refuses loudly -- today's message, no event, no
    # Store touch. The default is Supervisor::Null, so an unwired tool behaves
    # byte-identically to the refusal that stood before.
    it "still refuses with today's message when no supervisor is wired" do
      tool = described_class.new(
        tool_middleware: ToolRegistry::UNGUARDED,
        provider: mock(text_response("unused")), context_factory: -> { child_context },
        toolset: union, policy: spawn_policy, parent:, mode: :actor, log: actor_log
      )
      before = store.size

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_error
      expect(result.content).to match(/OM-6|supervisor|launch_actor/)
      expect(actor_log.to_a).to be_empty
      expect(store.size).to eq(before)
    end

    it "refuses the same way under a supervisor that is not running" do
      stopped = Lain::Supervisor.new
      tool = actor_mode_tool(text_response("unused"), supervisor: stopped)

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_error
      expect(result.content).to include("supervisor")
    end
  end

  # ---- The child-spawn collaborators travel as ONE Seam value ----------------
  #
  # The six a child spawn is always built over -- provider, child-Context
  # factory, live parent handle, journal, supervisor, lineage observer -- were
  # loose keywords on three signatures, bundled into a Hash at the one place
  # ({CLI::Wiring::ToolsetBuild#child_seam_kwargs}) that already knew they were
  # one thing. Naming the value is what makes "over the same seams" checkable,
  # and what makes a seventh member a one-place change.
  #
  # Every OTHER example in this file constructs with the loose keywords, so this
  # block's green plus theirs is the additive claim: both styles are valid.
  describe "the spawn Seam" do
    let(:seam) do
      Lain::Tools::Subagent::Seam.new(provider: mock(text_response("seamed")),
                                      context_factory: -> { child_context }, parent:,
                                      tool_middleware: ToolRegistry::UNGUARDED)
    end

    it "spawns over an injected seam, with no loose collaborator keywords" do
      tool = described_class.new(seam:, toolset: union, policy: spawn_policy, max_depth: 3)

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok
      expect(result.content).to eq("seamed")
      expect(tool.seam).to be(seam)
    end

    # The last three are Null-defaulted, so a caller who wires none of them gets
    # byte-identically what the pre-seam constructor's own defaults gave. All
    # three are the SAME object every time, which is what the next example needs.
    it "defaults journal, supervisor and observer to their Null objects" do
      expect(seam.journal).to be(Lain::Channel::Null.instance)
      expect(seam.supervisor).to be(Lain::Supervisor::Null)
      expect(seam.observer).to be(Lain::Tools::Subagent::NO_OBSERVER)
      expect(Lain::Tools::Subagent::NO_OBSERVER).to be_frozen
    end

    # The ask-the-human member. Its Null is a module rather than an instance for
    # the same reason the three above are singletons: a fresh object per default would
    # make two otherwise identical seams compare unequal.
    it "defaults the ask-the-human seam to the one wired to nothing" do
      expect(seam.askers).to be(Lain::Tools::Subagent::NoAskers)
    end

    # The isolation member, and the same singleton rule for the same reason: it
    # owns a worker-id sequence, so it cannot be frozen, but it must still be
    # the SAME object every time or two otherwise identical seams compare
    # unequal.
    it "defaults isolation to the shared unisolated lease source" do
      expect(seam.isolation).to be(Lain::Tools::Subagent::NO_ISOLATION)
    end

    # A value object whose `==` depends on WHICH member the caller let default is
    # a trap: `observer:` used to default to a FRESH ChainWriter::Null, so two
    # seams over identical collaborators compared unequal while their two
    # singleton neighbours compared equal.
    it "equates two seams built from the same collaborators, defaults included" do
      members = { provider: :p, context_factory: :cf, parent: :pa, tool_middleware: ToolRegistry::UNGUARDED }

      expect(Lain::Tools::Subagent::Seam.new(**members))
        .to eq(Lain::Tools::Subagent::Seam.new(**members))
    end

    it "requires the four that have no Null: provider, context factory, parent, and tool middleware" do
      expect { Lain::Tools::Subagent::Seam.new(provider: mock, context_factory: -> { child_context }) }
        .to raise_error(ArgumentError, /parent.*tool_middleware/)
    end

    # Nothing in lib/ may SAY "no guard": a named unguarded thunk there is one
    # a production caller could reach for. The specs keep theirs in support.
    it "defines no production constant meaning a spawn runs behind no guard" do
      expect(described_class.const_defined?(:UNGUARDED, false)).to be(false)
    end

    # The guard has no Null for the reason the other three have none: a
    # default is how a production spawn would run with no guard at all while
    # nothing anywhere said so.
    it "refuses a seam that names no tool middleware, so no child goes unguarded by omission" do
      expect { Lain::Tools::Subagent::Seam.new(provider: mock, context_factory: -> { child_context }, parent:) }
        .to raise_error(ArgumentError, /tool_middleware/)
    end

    it "runs every tool call a child makes through the seam's tool middleware" do
      guard = SubagentSpecToolGuard.new
      tool = build_subagent(provider: mock(tool_response(["r1", "read_file", { "path" => "/nowhere/at/all" }]),
                                           text_response("done")),
                            tool_middleware: ToolRegistry.guarded_by(guard))

      tool.call({ "prompt" => "go" }, invocation)

      expect(guard.seen).to eq(["read_file"])
    end

    # A THUNK, read when a child is built: a chat's board does not exist yet
    # when the seam does, so the guard over it cannot be built any earlier.
    it "asks the seam for the guard once per child, when that child is built" do
      built = 0
      tool = build_subagent(provider: mock(text_response("a"), text_response("b")),
                            tool_middleware: ->(env) { (built += 1) && ToolRegistry::UNGUARDED.call(env) })

      expect(built).to eq(0)
      2.times { tool.call({ "prompt" => "go" }, invocation) }

      expect(built).to eq(2)
    end

    # A child leased into a checkout of its own writes there, so its guard has
    # to know where it stands: the thunk is handed the child's environment.
    it "hands the guard the environment the child runs in, its leased checkout included" do
      Dir.mktmpdir do |dir|
        cwds = []
        tool = build_subagent(provider: mock(text_response("done")),
                              isolation: Lain::Isolation::Leases.new(backend: SubagentSpecIsolation.new(dir)),
                              tool_middleware: ->(env) { (cwds << env.cwd) && ToolRegistry::UNGUARDED.call(env) })

        tool.call({ "prompt" => "go" }, invocation)

        expect(cwds.size).to eq(1)
        expect(cwds.first).to start_with(dir)
      end
    end

    # Both styles are valid; holding both at once is the one thing that cannot
    # be honored, so it raises at construction rather than silently preferring
    # one and discarding the other.
    it "refuses a seam and its loose members together, naming the member" do
      expect { described_class.new(seam:, provider: mock, toolset: union, policy: spawn_policy) }
        .to raise_error(ArgumentError, "pass seam: or its members [:provider], not both")
    end

    # The loose path must stay as loud as Ruby's own keyword checking was: a
    # misspelled collaborator is a silent Null default if the splat swallows it.
    it "refuses a loose keyword that is not a seam member" do
      expect do
        described_class.new(provider: mock, context_factory: -> { child_context }, parent:,
                            tool_middleware: ToolRegistry::UNGUARDED,
                            observers: [], toolset: union, policy: spawn_policy)
      end.to raise_error(ArgumentError, /unknown keyword: :observers/)
    end

    # A typo BESIDE a seam is still a typo. Diagnosing it as a both-at-once
    # conflict sends the reader hunting for a member they never passed, so the
    # seam path says exactly what Data's own `new` says on the loose path.
    it "calls a misspelled keyword beside a seam a typo, not a conflict" do
      expect { described_class.new(seam:, toolset: union, policy: spawn_policy, max_dept: 3) }
        .to raise_error(ArgumentError, "unknown keyword: :max_dept")
    end

    it "names every stray keyword when several arrive beside a seam" do
      expect { described_class.new(seam:, toolset: union, policy: spawn_policy, max_dept: 3, nam: "x") }
        .to raise_error(ArgumentError, "unknown keywords: :max_dept, :nam")
    end

    # A descended copy re-injects the seam verbatim EXCEPT the parent handle
    # and the escalation road: a grandchild's lineage must name the CHILD's
    # head and a grandchild's question must relay through the CHILD rather
    # than skip it, while the observer and supervisor must stay the same
    # objects or a nested spawn's record vanishes one level up.
    it "descends the seam onto the child, rebinding only the parent and the escalation road" do
      wired = seam.with(observer: ->(_event) {}, supervisor: Lain::Supervisor.new, journal: Lain::Channel.new)
      tool = described_class.new(seam: wired, toolset: union, policy: spawn_policy, max_depth: 3)
      child_handle = -> { parent }

      copy = tool.descend(parent: child_handle, escalation: ["a-parent-correlation"], ceiling: 1)

      expect(copy.seam.parent).to be(child_handle)
      expect(copy.seam.escalation).to eq(["a-parent-correlation"])
      expect(copy.seam.to_h.except(:parent, :escalation)).to eq(wired.to_h.except(:parent, :escalation))
    end

    # The union a child attenuates FROM, published. It was reachable only by a
    # two-deep `instance_variable_get(:@builder).instance_variable_get(:@toolset)`
    # (toolset_build_spec's own reach-through), which pins the extraction's
    # private shape instead of the capability floor the bench wants to read.
    it "publishes the union a child attenuates from" do
      tool = described_class.new(seam:, toolset: union, policy: spawn_policy)

      expect(tool.attenuates_from).to be(union)
    end
  end

  # What a live fleet view is told while a child works, through the objects
  # that really carry it: a real one-shot spawn, the seam's telemetry leg, and
  # a real {Lain::StatusFeed} folding both the lineage events and the progress
  # records. Nothing here doubles the fold, because the thing under test is
  # the two halves agreeing about one spawn.
  describe "the fleet tree a spawn publishes" do
    let(:feed) { Lain::StatusFeed.new(path: File.join(state_dir, "state.json")) }
    let(:state_dir) { Dir.mktmpdir("lain-subagent-fleet") }

    let(:spawns) { [] }

    # The scribe's own split, in one line: the events reach the tee, the
    # child's turns stay record data. Feeding turns here would make this
    # example prove something no production wiring does.
    let(:tee) do
      lambda do |event|
        spawns << event if event.kind == :spawn
        feed << event unless event.kind == :turn
      end
    end

    after { FileUtils.remove_entry(state_dir) }

    def rows = feed.state["fleet_tree"]

    it "names the spawn, its role and its task line, and counts the turns the child committed" do
      tool = build_subagent(provider: mock(text_response("done")), announces_as: "dev",
                            observer: tee, telemetry: feed)

      tool.run("port the parser\nand then the lexer")

      expect(rows.map { |row| row.values_at("role", "task", "state") })
        .to eq([["dev", "port the parser and then the lexer", "done"]])
      expect(rows.first["turns"]).to be_positive
    end

    # The row is keyed on the spawn digest, which is the address a watcher
    # names -- so the tree and the roster cannot come to disagree about which
    # child they are describing.
    it "keys the row on the spawn digest the roster carries" do
      tool = build_subagent(provider: mock(text_response("done")), observer: tee, telemetry: feed)

      tool.run("look around")

      expect(rows.map { |row| row["spawn"] }).to eq(spawns.map(&:digest))
    end

    # The child asks for a tool it was never granted on every turn, so only
    # the ceiling ends it -- and its row must say so rather than sitting at
    # running for the rest of the session.
    it "reads failed for a child that hit its ceiling" do
      tool = described_class.new(provider: mock(tool_response(["e1", "echo", { "text" => "again" }])),
                                 context_factory: -> { child_context }, toolset: union, policy: spawn_policy,
                                 parent:, budget: Lain::Agent::Budget.new(max_iterations: 2), max_depth: 3,
                                 tool_middleware: ToolRegistry::UNGUARDED, observer: tee, telemetry: feed)

      expect { tool.run("keep going") }.to raise_error(StandardError)

      expect(rows.map { |row| row["state"] }).to eq(["failed"])
    end
  end
end
