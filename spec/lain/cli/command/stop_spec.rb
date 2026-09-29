# frozen_string_literal: true

# `/stop` at `you>`. The prompt only ever opens between asks -- the repl
# dispatches a line and the ask it starts completes inside that dispatch -- so
# there is never a RUN to stop here. What there can be is a FLEET: an adopted
# actor is a sibling of every ask, not a captive of one (Supervisor), so it
# keeps going with nothing parked at `you>` to answer for it. This command is
# the one place that reaches it, and it stops exactly the workers
# `Supervisor#live` names -- never the reactor those workers run under, which
# stays adoptable so a later actor-mode ask can still spawn. Whether a
# `:failed` or `:stopped` row is excluded from `live` is `Supervisor#live`'s
# own question (spec/lain/supervisor_spec.rb); this file only checks that
# Stop acts on, and names, exactly what `live` hands it.
RSpec.describe Lain::CLI::Command::Stop do
  subject(:command) { described_class.new }

  # A fleet-less env by default -- `Lain::Supervisor::Null` enumerates empty --
  # so a test that does not care about the fleet does not have to build one.
  def env(supervisor: Lain::Supervisor::Null, **overrides) = build_command_env(supervisor:, **overrides)

  it "registers as /stop with a usage naming where a stop does reach an ask" do
    expect(command.name).to eq("stop")
    expect(command.usage).to include("/stop").and include("s")
  end

  it "says no ask is running, whatever follows the verb, when the fleet is empty too" do
    ["", "  ", "now"].each do |args|
      expect(command.call(args, env)).to eq(described_class::NOTHING_RUNNING)
    end
  end

  it "says it in words a human can act on" do
    expect(described_class::NOTHING_RUNNING).to include("no ask is running")
  end

  describe "with a running child" do
    def registration(role: "coder", worker_id: "coder-1",
                     actor: instance_double(Lain::Tools::Subagent::Actor, stop: nil))
      instance_double(Lain::Supervisor::Registration, role:, worker_id:, actor:)
    end

    # The blocker fix: an actor is stopped by hand, one at a time. Nothing
    # here ever calls `supervisor.stop` -- the double below stubs no such
    # method, so a regression back to the whole-fleet call fails this example
    # with "received unexpected message :stop" rather than passing quietly.
    it "stops the actor -- never the reactor -- and names what was stopped" do
      actor = instance_double(Lain::Tools::Subagent::Actor, stop: nil)
      worker = registration(actor:)
      supervisor = instance_double(Lain::Supervisor, live: [worker])

      answer = command.call("", env(supervisor:))

      expect(actor).to have_received(:stop)
      expect(answer).to include("coder").and include("coder-1")
    end

    it "stops and names every worker Supervisor#live hands it, and nothing it did not" do
      one_actor = instance_double(Lain::Tools::Subagent::Actor, stop: nil)
      two_actor = instance_double(Lain::Tools::Subagent::Actor, stop: nil)
      one = registration(role: "coder", worker_id: "coder-1", actor: one_actor)
      two = registration(role: "reviewer", worker_id: "reviewer-1", actor: two_actor)
      supervisor = instance_double(Lain::Supervisor, live: [one, two])

      answer = command.call("", env(supervisor:))

      expect([one_actor, two_actor]).to all(have_received(:stop))
      expect(answer).to include("coder-1").and include("reviewer-1")
    end

    it "leaves an idle fleet alone -- an empty Supervisor#live means nothing to stop" do
      supervisor = instance_double(Lain::Supervisor, live: [])

      expect(command.call("", env(supervisor:))).to eq(described_class::NOTHING_RUNNING)
    end

    describe "a label that is absent or hostile" do
      it "does not render an empty parenthesis for a nil role and worker_id" do
        actor = instance_double(Lain::Tools::Subagent::Actor, stop: nil)
        worker = registration(role: nil, worker_id: nil, actor:)
        supervisor = instance_double(Lain::Supervisor, live: [worker])

        answer = command.call("", env(supervisor:))

        expect(answer).not_to include("  ()")
      end

      it "does not carry a newline from a role into the answer" do
        actor = instance_double(Lain::Tools::Subagent::Actor, stop: nil)
        hostile = registration(role: "coder\nyou> rm -rf /", worker_id: "w-1", actor:)
        supervisor = instance_double(Lain::Supervisor, live: [hostile])

        answer = command.call("", env(supervisor:))

        expect(answer).not_to include("\n")
      end
    end

    it "names a whole fleet on one line" do
      fleet = Array.new(12) do |i|
        registration(role: "coder", worker_id: "coder-#{i}",
                     actor: instance_double(Lain::Tools::Subagent::Actor, stop: nil))
      end
      supervisor = instance_double(Lain::Supervisor, live: fleet)

      answer = command.call("", env(supervisor:))

      expect(fleet.size.times.all? { |i| answer.include?("coder-#{i}") }).to be(true)
    end
  end

  describe "against a real fleet", :seam do
    def running_actor(task, supervisor, role: "coder")
      parent = CoreGraph.timeline.commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
      tool = CoreGraph.subagent(provider: CoreGraph.provider(text_response("actor ready")), parent:, mode: :actor)
      task.async { supervisor.adopt(role:) { tool.launch_actor("go", worker_env: Lain::WorkerEnv.default) } }.wait
    end

    it "stops a genuinely running child and the parent's own plain ask still runs afterward" do
      Sync do |task|
        supervisor = Lain::Supervisor.new.run(task)
        actor = running_actor(task, supervisor)
        live = supervisor.each.first
        expect(live.state).to eq(:running)

        agent = CoreGraph.agent(provider: CoreGraph.provider(text_response("still here")))
        answer = command.call("", env(supervisor:, agent:))

        expect(answer).to include("coder").and include(live.worker_id)
        expect(actor).to be_stopped
        expect(agent.ask("go again").text).to eq("still here")
      ensure
        supervisor.stop
      end
    end

    it "is idempotent: a second /stop answers NOTHING_RUNNING rather than raising" do
      Sync do |task|
        supervisor = Lain::Supervisor.new.run(task)
        running_actor(task, supervisor)

        first = command.call("", env(supervisor:))
        second = command.call("", env(supervisor:))

        expect(first).to include("coder")
        expect(second).to eq(described_class::NOTHING_RUNNING)
      ensure
        supervisor.stop
      end
    end

    it "the whole running fleet goes -- a second actor is stopped too" do
      Sync do |task|
        supervisor = Lain::Supervisor.new.run(task)
        one = running_actor(task, supervisor, role: "coder")
        two = running_actor(task, supervisor, role: "reviewer")

        command.call("", env(supervisor:))

        expect(one).to be_stopped
        expect(two).to be_stopped
      ensure
        supervisor.stop
      end
    end

    # THE FIX'S WHOLE POINT: the reactor survives, so an actor-mode ask
    # dispatched AFTER `/stop` really spawns, rather than being silently
    # refused (Subagent#actor_refused) because Supervisor#stop already ended
    # the reactor's life -- the failure the plain-ask assertion above cannot
    # see, since a plain ask never touches the supervisor at all.
    it "lets a later actor-mode ask spawn for real, because the reactor was never stopped" do
      Sync do |task|
        supervisor = Lain::Supervisor.new.run(task)
        running_actor(task, supervisor)

        command.call("", env(supervisor:))
        expect(supervisor).to be_running

        parent = CoreGraph.timeline.commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
        spawner = CoreGraph.subagent(provider: CoreGraph.provider(text_response("child done")), parent:,
                                     mode: :actor, supervisor:)
        agent = CoreGraph.agent(
          toolset: CoreGraph.toolset([spawner]),
          provider: CoreGraph.provider(tool_response(["tu_1", "subagent", { "prompt" => "go" }]),
                                       text_response("spawned"))
        )

        agent.ask("spawn one")

        expect(supervisor.map(&:role)).to include("subagent")
      ensure
        supervisor.stop
      end
    end
  end

  describe "with a real supervisor tracking a one-shot" do
    it "stops the task, lets its completion run, and names it" do
      completed = []
      answer = nil

      Sync do |task|
        supervisor = Lain::Supervisor.new.run(task)
        one_shot = task.async(transient: true) do
          Async::Notification.new.wait
        ensure
          completed << :journaled
        end
        supervisor.track(one_shot, role: "diff_docent")

        answer = command.call("", env(supervisor:))
      ensure
        supervisor.stop
      end

      expect(completed).to eq([:journaled])
      expect(answer).to include("stopped").and include("diff_docent")
    end
  end
end
