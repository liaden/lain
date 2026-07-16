# frozen_string_literal: true

require "async"
require "async/queue"

# 5-0.3 / OM-0: the loop runs under async's fiber scheduler so that a user
# interrupt (Ctrl-C, a supervising timeout) is *structured* cancellation --
# Async::Task#stop raises Async::Stop at the task's next scheduler yield, not
# at an arbitrary bytecode boundary the way Thread#kill would. Two properties
# are asserted here, and both are load-bearing (see docs/concurrency.md):
#
#   1. Outside a reactor, behaviour is unchanged -- Agent#run wraps its loop in
#      `Sync`, which spins up a reactor transparently for non-reactor callers
#      and joins the caller's reactor otherwise. The rest of the suite (every
#      agent spec, gate 7) proves the "unchanged" half; the reactor-asserting
#      provider below proves the bridge actually establishes the reactor.
#
#   2. A stop mid-turn leaves the state machine in a LEGAL state and the
#      Timeline holding either the committed turn or no partial turn -- never a
#      torn commit. The immutable, content-addressed Timeline is what makes this
#      free: `@timeline = @timeline.commit(...)` is an atomic reference swap, and
#      a fiber only yields at an IO boundary the scheduler controls, so a stop
#      can only ever land *between* whole commits.
RSpec.describe "Lain::Agent cancellation" do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

  # A Provider::Mock that parks inside `complete` on its `park_on`-th call: it
  # announces arrival on `entered` and then blocks on an internal queue nothing
  # ever feeds, so the reactor is deterministically inside a model call -- no
  # `sleep`, no timing race -- when the test stops the task. `Async::Queue` is
  # buffered, so the arrival signal is never lost even though the child fiber
  # runs synchronously up to the park before the parent waits on it.
  before do
    stub_const("ParkingProvider", Class.new(Lain::Provider::Mock) do
      def initialize(park_on:, entered:, **rest)
        super(**rest)
        @park_on = park_on
        @entered = entered
        @release = Async::Queue.new
      end

      def complete(request)
        if call_count + 1 == @park_on
          @entered.enqueue(true)
          @release.dequeue
        end
        super
      end
    end)

    # The red-first probe for the Sync bridge: with no bridge and no caller
    # reactor, `Async::Task.current?` is nil and this raises.
    stub_const("ReactorAssertingProvider", Class.new(Lain::Provider::Mock) do
      def complete(request)
        raise "Provider::Mock#complete ran outside a reactor" unless Async::Task.current?

        super
      end
    end)
  end

  # Builds an agent whose provider parks on its `park_on`-th model call, then
  # returns [agent, returned] after the run is cancelled mid-park. `returned`
  # stays :never_returned iff the stop landed before `ask` produced a Response.
  def cancel_mid_turn(park_on:, responses:)
    entered = Async::Queue.new
    provider = ParkingProvider.new(park_on:, entered:, responses:)
    agent = Lain::Agent.new(provider:, toolset:, context:)
    [agent, run_until_stopped(agent, entered)]
  end

  # Drives `ask` on a child task, waits until the provider has parked mid-call,
  # then cancels through the Budget seam. Everything happens inside the one
  # `Sync` reactor -- no cross-reactor wait -- so the helper cannot itself hang.
  def run_until_stopped(agent, entered)
    returned = :never_returned
    Sync do |task|
      child = task.async { returned = agent.ask("hi") }
      entered.dequeue
      agent.budget.interrupt(child)
      child.wait
    end
    returned
  end

  describe "the Sync bridge (non-reactor callers)" do
    it "establishes a reactor so the loop's IO can yield, transparently to the caller" do
      expect(Async::Task.current?).to be_nil

      agent = Lain::Agent.new(
        provider: ReactorAssertingProvider.new(responses: [text_response("done")]),
        toolset:, context:
      )
      response = agent.ask("hi")

      expect(response.text).to eq("done")
      expect(agent).to be_done
    end
  end

  describe "a stop raised during the first model call" do
    it "settles in a legal state with no partial turn committed" do
      agent, returned = cancel_mid_turn(park_on: 1, responses: [text_response])

      expect(Lain::Agent::STATES).to include(agent.state)
      expect(returned).to eq(:never_returned)
      # The user turn is committed by #ask before the loop runs; the model call
      # never returned, so no assistant turn exists -- not a torn one, none.
      expect(agent.timeline.to_a.map(&:role)).to eq(%w[user])
    end
  end

  describe "a stop raised during a later model call" do
    it "leaves the committed prefix intact and adds no partial turn" do
      agent, returned = cancel_mid_turn(
        park_on: 2,
        responses: [tool_response(%w[tu_1 echo] << { "text" => "x" }), text_response]
      )

      expect(Lain::Agent::STATES).to include(agent.state)
      expect(returned).to eq(:never_returned)
      # user -> assistant(tool_use) -> user(tool_result) all committed before the
      # second model call parked; the stop adds nothing after them.
      turns = agent.timeline.to_a
      expect(turns.map(&:role)).to eq(%w[user assistant user])
      expect(turns.last.content.map { |block| block["type"] }).to eq(%w[tool_result])
    end
  end

  describe "the Timeline after a torn-commit attempt" do
    it "stays deeply frozen and shareable -- the interrupt left no mutable half-state" do
      agent, = cancel_mid_turn(park_on: 1, responses: [text_response])

      expect(agent.timeline.to_a).to all(satisfy { |turn| Ractor.shareable?(turn) })
    end
  end

  # The commit->journal pair is one atom, not two steps a stop can land between.
  # Bench cost accounting reads the Journal (never turn.meta), so a committed
  # assistant turn whose TurnUsage record vanished with an interrupt would price
  # as free -- a silent loss in the experiment record. The Timeline commit itself
  # is a pure reference swap with no yield point, so the only tearable seam is
  # the journal write; this parks a stop exactly there and asserts the pair
  # stayed whole.
  describe "a stop raised during the journal write" do
    before do
      stub_const("ParkingJournal", Class.new do
        def initialize(entered:, release:)
          @entered = entered
          @release = release
          @records = []
        end

        attr_reader :records

        def <<(record)
          @entered.enqueue(true)
          @release.dequeue
          @records << record
          self
        end
      end)
    end

    it "never splits a committed turn from its TurnUsage record" do
      entered = Async::Queue.new
      release = Async::Queue.new
      journal = ParkingJournal.new(entered:, release:)
      provider = Lain::Provider::Mock.new(responses: [text_response])
      agent = Lain::Agent.new(provider:, toolset:, context:, journal:)
      returned = :never_returned

      Sync do |task|
        child = task.async { returned = agent.ask("hi") }
        entered.dequeue # journal.<< is parked; the assistant turn is committed
        agent.budget.interrupt(child)
        release.enqueue(true) # the shielded write may now finish
        child.wait
      end

      expect(agent.timeline.to_a.map(&:role)).to eq(%w[user assistant])
      expect(journal.records.map(&:digest)).to eq([agent.timeline.head_digest])
      # The stop is deferred across the pair, not dropped: it lands at the
      # region's exit, so the run still never produces a Response.
      expect(returned).to eq(:never_returned)
    end
  end
end
