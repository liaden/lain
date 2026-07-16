# frozen_string_literal: true

require "async"
require "async/queue"

# OM-3: the long-lived actor subagent. Unlike the one-shot (which runs
# synchronously inside one tool dispatch), an actor persists across the parent's
# turns on its own supervised fiber, exchanges messages as attributed Store
# events, and ends under structured cancellation on `stop`.
RSpec.describe "Lain::Tools::Subagent actor mode" do
  # One shared Store; the parent's two-turn chain establishes H and a correlation.
  let(:store) { Lain::Store.new }
  let(:log) { Lain::Tools::Subagent::Log.new }
  let(:parent_timeline) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end

  def actor_tool(*responses, policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []))
    Lain::Tools::Subagent.new(
      provider: Lain::Provider::Mock.new(responses:),
      context_factory: -> { Lain::Context.new(model: "child", max_tokens: 128) },
      toolset: Lain::Toolset.new([EchoTool.new]), policy:, parent: parent_timeline,
      journal: Lain::Channel::Null.instance, budget: Lain::Agent::Budget.new,
      max_depth: 1, mode: :actor, log:
    )
  end

  def parent_agent
    Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: [text_response("p1"), text_response("p2")]),
      toolset: Lain::Toolset.new([]), context: Lain::Context.new(model: "parent", max_tokens: 128),
      timeline: parent_timeline
    )
  end

  # Panel ruling (T23 #1): a model-dispatched `mode: :actor` tool call must be
  # REFUSED loudly, never launched -- Agent#ask's per-call Sync owns any fiber a
  # tool dispatch spawns, so a perform-launched actor parks as ask's own child
  # and structured concurrency never lets ask return. Until the OM-6 supervisor
  # provides an orchestration reactor above the Agent, the actor seam is
  # programmatic only (#launch_actor).
  describe "a model-dispatched :actor is refused" do
    it "returns an is_error tool_result naming the prerequisite, lets ask settle, and emits no event" do
      tool = actor_tool
      parent = Lain::Agent.new(
        provider: Lain::Provider::Mock.new(responses: [
                                             tool_response(["a1", "subagent", { "prompt" => "go" }]),
                                             text_response("parent continues")
                                           ]),
        toolset: Lain::Toolset.new([tool]),
        context: Lain::Context.new(model: "parent", max_tokens: 128),
        timeline: parent_timeline
      )

      response = parent.ask("spawn an actor")

      expect(response.text).to eq("parent continues")
      refusal = parent.timeline.to_a[-2].content.first
      expect(refusal["type"]).to eq("tool_result")
      expect(refusal["is_error"]).to be(true)
      expect(refusal["content"]).to match(/OM-6|supervisor|launch_actor/)
      expect(log.to_a).to be_empty
    end
  end

  # Scenario: an actor persists across parent turns.
  describe "persistence across parent turns" do
    it "retains its own Timeline while the parent runs, and meet(actor, parent) is empty" do
      Sync do
        actor = actor_tool(text_response("actor did the thing")).launch_actor("do work")
        actor.settle

        expect(actor.timeline).not_to be_empty
        expect(actor.timeline.meet(parent_timeline)).to be_empty
        saved = actor.timeline

        parent = parent_agent
        parent.ask("turn one")
        parent.ask("turn two")

        expect(actor.timeline).to eq(saved)
        expect(actor.timeline.meet(parent.timeline)).to be_empty
        actor.stop
      end
    end
  end

  # Scenario: the mailbox is a view, not a queue.
  describe "messages exchanged both directions" do
    it "projects each side's mailbox purely over the shared log, re-foldably" do
      Sync do
        actor = actor_tool(text_response("hello from actor")).launch_actor("start")
        actor.settle
        actor.tell("please continue")
        actor.stop

        projection = Lain::Event::Projection.new(log.to_a)
        inbound = projection.mailbox(actor.address).to_a # parent -> actor
        outbound = projection.mailbox(actor.parent_correlation).to_a # actor -> parent

        expect(inbound.map { |event| event.body["text"] }).to eq(["please continue"])
        expect(outbound.map { |event| event.body["text"] }).to include("hello from actor")

        # Re-foldable, and the log is append-only -- folding consumed nothing.
        expect(projection.mailbox(actor.address).to_a).to eq(inbound)
        expect(log.to_a).to eq(log.to_a)
      end
    end

    it "records the actor's address on a :spawn event with a causal edge to H" do
      Sync do
        actor = actor_tool(text_response("ok")).launch_actor("start")
        actor.settle
        spawn = log.to_a.find { |event| event.kind == :spawn }
        expect(spawn.digest).to eq(actor.address)
        expect(spawn.causal_parents).to include(parent_timeline.head_digest)
        actor.stop
      end
    end
  end

  # Scenario: explicit stop.
  describe "explicit stop" do
    it "lands a final attributed event and ends the fiber under structured cancellation" do
      Sync do
        actor = actor_tool(text_response("working")).launch_actor("start")
        actor.settle
        before = log.to_a.size

        actor.stop

        farewell = Lain::Event::Projection.new(log.to_a).mailbox(actor.parent_correlation).to_a.last
        expect(farewell.kind).to eq(:message)
        expect(log.to_a.size).to be > before
        expect(actor).to be_stopped
      end
    end

    # Panel #4: a tell after stop would append to a mailbox nobody will ever
    # fold -- a silently lost message. Loud failure instead.
    it "refuses tell after stop, loudly, emitting nothing" do
      Sync do
        actor = actor_tool(text_response("ok")).launch_actor("start")
        actor.settle
        actor.stop
        before = log.to_a.size

        expect { actor.tell("anyone home?") }
          .to raise_error(Lain::Tools::Subagent::Actor::Stopped, /stopped/)
        expect(log.to_a.size).to eq(before)
      end
    end
  end

  # Panel #2: a child that raises mid-initial-turn must still resolve settle --
  # and surface the error -- rather than parking the awaiting caller forever.
  describe "a child that fails its initial turn" do
    it "resolves settle by raising the child's error rather than hanging" do
      Sync do
        # Zero scripted responses: the Mock provider raises on the first call.
        actor = actor_tool.launch_actor("start")
        expect { actor.settle }.to raise_error(Lain::Error, /ran out of responses/)
      end
    end

    it "can still be stopped cleanly after the failure" do
      Sync do
        actor = actor_tool.launch_actor("start")
        expect { actor.settle }.to raise_error(Lain::Error)
        farewell = actor.stop
        expect(farewell.kind).to eq(:message)
      end
    end

    # T3 fix round (Metz/Torvalds): `stopped?` stays false after a failure (the
    # fiber ended normally; probe 6 pins that), so the honest "do not message
    # me" answer a supervisor consults is a SEPARATE terminal predicate.
    it "answers dead? true after a failure, true after a stop, false while healthy" do
      Sync do
        failed = actor_tool.launch_actor("start")
        expect { failed.settle }.to raise_error(Lain::Error)
        expect(failed).to be_dead
        expect(failed).not_to be_stopped

        healthy = actor_tool(text_response("ok")).launch_actor("start")
        healthy.settle
        expect(healthy).not_to be_dead
        healthy.stop
        expect(healthy).to be_dead
      end
    end

    # T3 panel #2: a child whose turn raised ends its fiber NORMALLY, so neither
    # the @stopped flag nor @task.stopped? reads true -- yet a tell would append
    # to a mailbox no fold will ever visit. Refuse it as loudly as a stopped one.
    it "refuses tell after the initial turn raised, and the mailbox does not grow" do
      Sync do
        actor = actor_tool.launch_actor("start")
        expect { actor.settle }.to raise_error(Lain::Error)
        before = log.to_a.size

        expect { actor.tell("still there?") }
          .to raise_error(Lain::Tools::Subagent::Actor::Stopped)
        expect(log.to_a.size).to eq(before)
      end
    end
  end

  # T3 scenario: settle never parks forever after an early stop. The child's
  # initial turn is parked in-flight (inside the provider) when stop lands; the
  # cancellation is Async::Stop, not a StandardError, so a rescue-only #run would
  # leave @ready unresolved and a later settle would hang.
  describe "settle after an early stop" do
    before do
      stub_const("ParkingChildProvider", Class.new(Lain::Provider) do
        def initialize(entered:)
          super()
          @entered = entered
          @release = Async::Queue.new
        end

        # Announce arrival, then block on a queue nothing feeds: the fiber is
        # deterministically parked inside the model call when the test stops it.
        def complete(_request)
          @entered.enqueue(true)
          @release.dequeue
          Lain::Response.new(content: [{ "type" => "text", "text" => "unreachable" }], stop_reason: :end_turn)
        end
      end)
    end

    def parking_actor_tool(entered:)
      Lain::Tools::Subagent.new(
        provider: ParkingChildProvider.new(entered:),
        context_factory: -> { Lain::Context.new(model: "child", max_tokens: 128) },
        toolset: Lain::Toolset.new([EchoTool.new]),
        policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []),
        parent: parent_timeline, journal: Lain::Channel::Null.instance,
        budget: Lain::Agent::Budget.new, max_depth: 1, mode: :actor, log:
      )
    end

    it "returns within the reactor tick rather than parking forever" do
      Sync do |task|
        entered = Async::Queue.new
        actor = parking_actor_tool(entered:).launch_actor("start")
        entered.dequeue # the child's initial turn is now parked in the provider
        actor.stop

        # with_timeout makes a regression fail loudly (Async::TimeoutError) rather
        # than hang the suite: settle must resolve well within this window.
        settled = task.with_timeout(2) { actor.settle }
        expect(settled).to eq(actor)
        expect(actor).to be_stopped
      end
    end
  end

  # T3 scenario: stop before launch fails loudly without side effects. Before
  # #launch there is no fiber to cancel and no address to attribute a farewell
  # to; emitting one would put a nil-addressed event into the Store and then
  # crash on the nil task. Refuse first, touch nothing.
  describe "a lifecycle op before launch" do
    def unlaunched_actor
      lineage = Lain::Tools::Subagent::Lineage.new(
        policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []), log:
      )
      Lain::Tools::Subagent::Actor.new(agent: Object.new, lineage:, parent: parent_timeline)
    end

    it "stop raises NotLaunched and no farewell event enters the Store" do
      actor = unlaunched_actor

      expect { actor.stop }.to raise_error(Lain::Tools::Subagent::Actor::NotLaunched, /launch/)
      expect(log.to_a).to be_empty
    end

    it "tell and settle also refuse before launch" do
      actor = unlaunched_actor

      expect { actor.tell("hello?") }.to raise_error(Lain::Tools::Subagent::Actor::NotLaunched)
      expect { actor.settle }.to raise_error(Lain::Tools::Subagent::Actor::NotLaunched)
      expect(log.to_a).to be_empty
    end
  end

  # Panel #5: the one-shot default log is a genuine Null Object -- foldable to
  # empty, never a missing-method surprise.
  describe "Log::Null" do
    it "enumerates as empty and swallows appends" do
      null = Lain::Tools::Subagent::Log::Null
      expect(null << :event).to eq(null)
      expect(null.to_a).to eq([])
    end
  end
end
