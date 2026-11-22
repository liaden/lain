# frozen_string_literal: true

require "async"
require "json"
require "stringio"

# An actor's lifecycle is a chain of :message events, and the session record gets
# each one through the seam's observer, which is the scribe. The seam's journal is
# that same session file, so a second write of the event onto the journal would
# put every transition in the record twice.
RSpec.describe Lain::Tools::Subagent::Actor do
  let(:session_io) { StringIO.new }
  let(:session_file) { Lain::Journal.new(io: session_io) }
  let(:scribe) { CoreGraph.scribe(journal: session_file) }
  let(:store) { CoreGraph.store }
  let(:parent) do
    CoreGraph.timeline(store:)
             .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
             .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end
  let(:tool) do
    CoreGraph.subagent(provider: CoreGraph.provider(text_response("actor ready")), parent:,
                       journal: session_file, observer: scribe, mode: :actor)
  end

  def stops
    journal_records(session_io).select do |record|
      record["type"] == "message" && record.dig("payload", "lifecycle") == "stopped"
    end
  end

  describe "#stop" do
    it "leaves exactly one message record carrying the stop in the session file" do
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
        actor.settle
        supervisor.stop
      ensure
        supervisor&.stop
      end

      expect(stops.size).to eq(1)
    end
  end

  describe "an orchestrator's record" do
    let(:usage) { Lain::Usage.new(input_tokens: 10) }
    let(:tool) do
      rounds = Array.new(2) { |index| tool_response(["e#{index}", "echo", { "text" => "pass #{index}" }], usage:) }
      CoreGraph.subagent(provider: CoreGraph.provider(*rounds, text_response("landed", usage:)), parent:,
                         journal: session_file, telemetry: session_file, observer: scribe, mode: :actor,
                         toolset: Lain::Toolset.new([EchoTool.new]), policy: CoreGraph.spawn_policy(only: %i[echo]),
                         announces_as: "issue_orchestrator")
    end

    def orchestrated
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        supervisor.adopt(role: "issue_orchestrator") { |worker_env| tool.launch_actor("land it", worker_env:) }.settle
      ensure
        supervisor&.stop
      end
      journal_records(session_io).find { |record| record["kind"] == "spawn" }.fetch("digest")
    end

    it "journals a turn_usage per request, each naming its spawn" do
      spawn = orchestrated

      expect(journal_records(session_io).count { |record| record["kind"] == "spawn" }).to eq(1)
      expect(journal_records(session_io, "turn_usage").map { |record| record["spawn"] }).to eq([spawn] * 3)
    end

    it "journals its progress under its role, a row per turn the session record holds" do
      spawn = orchestrated
      progress = journal_records(session_io, "child_progress")
      turns = journal_records(session_io, "child_turn")

      expect(progress.map { |record| record["spawn"] }.uniq).to eq([spawn])
      expect(progress.first).to include("role" => "issue_orchestrator", "turns" => 0)
      expect(progress.select { |record| record["head"] }.map { |record| record["turns"] }).to eq((1..turns.size).to_a)
      expect(turns.size).to be >= 3
    end
  end

  describe "the spend an actor's child reports" do
    let(:spend) { Lain::Budget::Shared.new }
    let(:tool) do
      CoreGraph.subagent(provider: CoreGraph.provider(text_response("ready", usage: Lain::Usage.new(input_tokens: 40))),
                         parent:, journal: session_file, observer: scribe, mode: :actor, spend:,
                         holder: Lain::Budget.ceilings(tokens: 1000).with(depth: 1))
    end

    it "rolls into its spawner once, at its reply, however often it is stopped" do
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
        actor.settle
        actor.stop
        actor.stop
      ensure
        supervisor&.stop
      end

      expect([spend.spent.usage.total_tokens, spend.reserved]).to eq([40, 0])
    end
  end

  describe "the spend of a live actor's child" do
    let(:spend) { Lain::Budget::Shared.new }
    let(:tool) do
      CoreGraph.subagent(provider: CoreGraph.provider(text_response("ready", usage: Lain::Usage.new(input_tokens: 40))),
                         parent:, journal: session_file, observer: scribe, mode: :actor, spend:,
                         holder: Lain::Budget.ceilings(tokens: 1000).with(depth: 1))
    end

    it "settles into its spawner at its first answer, while the actor still lives" do
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
        actor.settle

        expect([spend.spent.usage.total_tokens, spend.reserved, actor.dead?]).to eq([40, 0, false])
      ensure
        supervisor&.stop
      end
    end
  end

  describe "the spend of an actor's child its ceiling stopped" do
    let(:spend) { Lain::Budget::Shared.new }
    let(:tool) do
      looping = tool_response(["e1", "echo", { "text" => "again" }], usage: Lain::Usage.new(input_tokens: 30))
      CoreGraph.subagent(provider: CoreGraph.provider(looping), parent:, journal: session_file, observer: scribe,
                         mode: :actor, spend:, toolset: Lain::Toolset.new([EchoTool.new]),
                         policy: CoreGraph.spawn_policy(only: %i[echo]), budget: Lain::Budget.ceilings(iterations: 2),
                         holder: Lain::Budget.ceilings(tokens: 1000).with(depth: 1))
    end

    it "settles into its spawner, and frees its reservation, before anyone stops it" do
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
        expect { actor.settle }.to raise_error(Lain::Budget::Exceeded)

        expect([spend.spent.usage.total_tokens, spend.reserved]).to eq([60, 0])
      ensure
        supervisor&.stop
      end
    end
  end

  describe "the messages ceiling" do
    let(:tool) do
      CoreGraph.subagent(provider: CoreGraph.provider(text_response("first"), text_response("second")), parent:,
                         journal: session_file, observer: scribe, mode: :actor,
                         budget: Lain::Budget.ceilings(messages:),
                         holder: Lain::Budget::Ceilings::UNLIMITED.with(depth: 1))
    end

    def lifecycles = journal_records(session_io).filter_map { |record| record.dig("payload", "lifecycle") }

    def with_actor
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
        yield actor
      ensure
        supervisor&.stop
      end
    end

    def exceeded_messages = raise_error(Lain::Budget::Exceeded) { |error| expect(error.kind).to eq(:messages) }

    context "when the parent tells an actor launched under 2, before its first reply" do
      let(:messages) { 2 }
      let(:gate) { Lain::Promise.new }
      let(:tool) do
        gate = self.gate
        parked = Class.new(Lain::Provider::Mock) do
          define_method(:complete) do |request, **opts|
            gate.await
            super(request, **opts)
          end
        end.new(responses: [text_response("first")])
        CoreGraph.subagent(provider: parked, parent:, journal: session_file, observer: scribe, mode: :actor,
                           budget: Lain::Budget.ceilings(messages:),
                           holder: Lain::Budget::Ceilings::UNLIMITED.with(depth: 1))
      end

      it "refuses the third tell as messages and notes nothing for it" do
        with_actor do |actor|
          2.times { |n| actor.tell("note #{n}") }
          before = journal_records(session_io).size

          expect { actor.tell("one too many") }.to exceeded_messages
          expect(journal_records(session_io).size).to eq(before)
          gate.resolve(true)
        end
      end
    end

    context "when a tell and the first reply have used up 2" do
      let(:messages) { 2 }
      let(:tool) do
        CoreGraph.subagent(provider: CoreGraph.provider(text_response("first")), parent:, journal: session_file,
                           observer: scribe, mode: :actor, budget: Lain::Budget.ceilings(messages:),
                           holder: Lain::Budget::Ceilings::UNLIMITED.with(depth: 1))
      end

      it "refuses the next tell, since tells and replies share one count" do
        with_actor do |actor|
          actor.tell("one")
          actor.settle

          expect { actor.tell("two") }.to exceeded_messages
        end
      end
    end

    context "when an actor under 1 has already replied once" do
      let(:messages) { 1 }

      it "refuses the next reply as messages and tells the parent it failed" do
        with_actor do |actor|
          actor.settle
          expect { actor.process("again") }.to exceeded_messages
        end

        expect(lifecycles).to eq(%w[launched settled failed])
      end
    end

    context "when an actor under 0 is asked for its first reply" do
      let(:messages) { 0 }

      it "fails as messages, tells the parent so, and is never read as stopped" do
        with_actor do |actor|
          expect { actor.settle }.to exceeded_messages
          expect(actor).to be_dead
          expect { actor.stop }.not_to raise_error
        end

        expect(lifecycles).to eq(%w[launched failed])
      end
    end

    context "when an actor under 1 is stopped after its reply" do
      let(:messages) { 1 }

      it "still lands the farewell, outside the count" do
        with_actor do |actor|
          actor.settle
          actor.stop
        end

        expect(lifecycles).to eq(%w[launched settled stopped])
      end
    end

    context "when an actor under 0 fails its turn" do
      let(:messages) { 0 }
      let(:tool) do
        prose = Lain::Response.new(content: [{ "type" => "text", "text" => "<tool_call>\n<function=bash>" }],
                                   stop_reason: :malformed)
        CoreGraph.subagent(provider: CoreGraph.provider(prose), parent:, journal: session_file, observer: scribe,
                           mode: :actor, budget: Lain::Budget.ceilings(messages:),
                           holder: Lain::Budget::Ceilings::UNLIMITED.with(depth: 1))
      end

      it "still tells the parent why, since a failure is a lifecycle note outside the count" do
        with_actor { |actor| expect { actor.settle }.to raise_error(Lain::Response::Failed) }

        expect(lifecycles).to eq(%w[launched failed])
      end
    end
  end

  describe "#settle" do
    let(:gate) { Lain::Promise.new }
    let(:blocked_provider) do
      gate = self.gate
      Class.new(Lain::Provider::Mock) do
        define_method(:complete) do |request, **opts|
          gate.await
          super(request, **opts)
        end
      end.new(responses: [text_response("actor ready")])
    end
    let(:tool) do
      CoreGraph.subagent(provider: blocked_provider, parent:, journal: session_file, observer: scribe, mode: :actor)
    end

    it "parks each waiting fiber until the child signals ready, then resumes it exactly once" do
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
        resumed = []
        waiters = Array.new(2) { |i| task.async { resumed << [i, actor.settle] } }
        task.yield

        expect(resumed).to be_empty
        gate.resolve(:go)
        waiters.each(&:wait)

        expect(resumed.map(&:first).sort).to eq([0, 1])
        expect(resumed.map(&:last)).to all(be(actor))
      ensure
        supervisor&.stop
      end
    end
  end

  # The actor keeps its adoption ordinal for twins on the same work, and names
  # the work beside it, so its address is derived from what it was given as a
  # one-shot's is.
  describe "#launch" do
    it "records the digest of the prompt it was launched with in its :spawn" do
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("watch the build", worker_env:) }
        supervisor.stop
      ensure
        supervisor&.stop
      end

      spawn = journal_records(session_io).find { |record| record["type"] == "message" && record["kind"] == "spawn" }
      expect(spawn.fetch("payload")).to include("task" => Lain::Canonical.digest("watch the build"), "adoption" => 1)
    end
  end

  # A tool call written as prose is the provider's envelope, not the child's
  # findings, so it must never reach the parent as a settled answer.
  describe "a child whose answer is a prose tool call" do
    let(:envelope) { "<tool_call>\n<function=bash>\n<parameter=command>ls" }
    let(:tool) do
      prose = Lain::Response.new(content: [{ "type" => "text", "text" => envelope }], stop_reason: :malformed)
      CoreGraph.subagent(provider: CoreGraph.provider(prose), parent:,
                         journal: session_file, observer: scribe, mode: :actor)
    end

    def lifecycles
      journal_records(session_io).filter_map do |record|
        record.dig("payload", "lifecycle") if record["type"] == "message"
      end
    end

    def failed_note = journal_records(session_io).find { |record| record.dig("payload", "lifecycle") == "failed" }

    def run_to_failure
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
        expect { actor.settle }.to raise_error(Lain::Response::Failed, /malformed/)
        expect(actor).to be_dead
      ensure
        supervisor&.stop
      end
    end

    it "tells the parent a failure naming malformed, and the child's completion reads failed" do
      run_to_failure

      expect(failed_note.dig("payload", "text")).to include("malformed")
      expect(lifecycles).not_to include("settled")
    end

    it "tells the parent the failure's words alone, never the envelope or the child's chain" do
      run_to_failure

      expect(failed_note.dig("payload", "text")).to eq(Lain::Response::Failure::PROSE_CALL)
    end

    # A farewell after the failure would mark the spawn stopped, and the fleet
    # row would read stopped for a child that failed.
    it "ends its trail at failed, through the supervisor's teardown" do
      run_to_failure

      expect(lifecycles).to eq(%w[launched failed])
    end
  end

  describe "a child whose provider fails" do
    let(:failure) { RuntimeError.new("socket closed") }
    let(:tool) do
      error = failure
      provider = Class.new(Lain::Provider::Mock) { define_method(:complete) { |*, **| raise error } }.new(responses: [])
      CoreGraph.subagent(provider:, parent:, journal: session_file, observer: scribe, mode: :actor)
    end

    def failed_text
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
        expect { actor.settle }.to raise_error(failure.class)
      ensure
        supervisor&.stop
      end
      journal_records(session_io).find { |record| record.dig("payload", "lifecycle") == "failed" }
                                 &.dig("payload", "text")
    end

    it "tells the parent a failed note naming the error class and message" do
      expect(failed_text).to eq("RuntimeError: socket closed")
    end

    context "with a usage limit" do
      let(:failure) do
        response = Struct.new(:status, :body, :headers).new(429, "", { "retry-after" => "3600" })
        Lain::Provider::HTTP::QuotaError.new(response, "limit reached")
      end

      it "tells the parent it was stopped by the limit, and when it resets" do
        expect(failed_text).to match(/\Astopped by the provider's usage limit; resets at \d{4}-\d\d-\d\dT/)
      end
    end

    context "when telling the parent fails too" do
      let(:tool) do
        error = failure
        armed = false
        provider = Class.new(Lain::Provider::Mock) do
          define_method(:complete) do |*, **|
            armed = true
            raise error
          end
        end.new(responses: [])
        once = [IOError.new("journal closed")]
        observer = lambda do |event|
          raise once.pop if armed && !once.empty?

          scribe.call(event)
        end
        CoreGraph.subagent(provider:, parent:, journal: session_file, observer:, mode: :actor)
      end

      def run_to_failure
        Sync do |task|
          supervisor = Lain::Supervisor.new(journal: session_file).run(task)
          actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
          expect { actor.settle }.to raise_error(RuntimeError, "socket closed")
        ensure
          supervisor&.stop
        end
      end

      it "surfaces the turn's own error from settle and records that the parent was not told" do
        run_to_failure

        failed = journal_records(session_io).select { |record| record["type"] == "observer_failed" }
        expect(failed.map { |record| record["message"] }).to eq(["journal closed"])
      end

      it "never sends a stopped note for a child that failed" do
        run_to_failure

        stopped = journal_records(session_io).select { |record| record.dig("payload", "lifecycle") == "stopped" }
        expect(stopped).to be_empty
      end
    end
  end
end
