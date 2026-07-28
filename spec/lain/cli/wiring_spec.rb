# frozen_string_literal: true

# Stands in for the eager tier's local model (A8 wires an Ollama-backed
# {Lain::Oracle::Model}), answering the REAL {Lain::Oracle::Summarize}
# definition so the schema, the Promise, and `#summary` are the production ones
# -- only the network edge is stubbed, exactly as {Lain::Provider::Mock} stubs
# the chat provider.
class WiringSpecSummarizer
  def initialize(text)
    @definition = Lain::Oracle::Summarize.definition
    @text = text
  end

  def ask(_inputs = {}) = @definition.answer("summary" => @text)
end

# The launch block's stand-in for an adopted actor (D2): it builds the child's
# Session from the LEASED WorkerEnv exactly as
# {Lain::Tools::Subagent::ChildBuilder#spawn_agent} does, so what a spec reads
# back is the object the real spawn path constructs. Only `#stop` is owed of the
# actor duck -- {Lain::Supervisor#stop} farewells each registration before it
# releases the lease.
class WiringSpecWorker
  attr_reader :session, :checkout

  # `checkout` is snapshotted HERE, inside the launch block, while the lease is
  # still live: {Lain::Supervisor#stop} releases it and a worktree release
  # removes the tree, so a spec that looked afterwards could only ever do string
  # math over `#cwd` -- which passes whether or not a checkout was ever created.
  def initialize(worker_env)
    @session = Lain::Session.new(worker_env:)
    @checkout = { exists: Dir.exist?(worker_env.cwd),
                  repo: File.exist?(worker_env.resolve(".git")),
                  seeded: File.exist?(worker_env.resolve("README")) }
  end

  def stop = self
end

RSpec.describe Lain::CLI::Wiring do
  # Provider resolution, context, slots, and spawn policies stay the real
  # Backend's; only the network edge swaps for Provider::Mock, so the whole
  # chat assembly is exercised offline exactly as the exe wires it (T1 AC:
  # the extracted Repl is constructible without the exe).
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:)
        super(options)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend) { offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider) }
  let(:channel) { Lain::Channel.new }
  let(:chronicle) { Lain::CLI::Chronicle::Null.new }
  # status_feed: is required, not defaulted (the Null placeholder is gone); the
  # direct-Wiring path only threads it into the Command::Env's status reader.
  let(:status_feed) { instance_double(Lain::StatusFeed) }
  let(:wiring) { described_class.new(options: { grace: 5 }, chronicle:, status_feed:) }

  def wire_agent
    recorder, session = wiring.run_state(nil)
    wiring.wire_agent(channel:, recorder:, session:, backend:)
  end

  describe "#wire_agent" do
    it "builds the Agent over the injected backend's provider, no exe involved" do
      agent = wire_agent
      expect(agent).to be_a(Lain::Agent)
      expect(agent.ask("ping").text).to eq("settled")
      expect(mock_provider.call_count).to eq(1)
    end

    it "exposes the reply seam and fleet supervisor it wired, as its own accessors" do
      wire_agent
      expect(wiring.ask_human).to be_a(Lain::Tools::AskHuman::Notifying)
      expect(wiring.questions).to be_a(Async::Queue)
      expect(wiring.supervisor).to be_a(Lain::Supervisor)
      expect(wiring.approvals).to be_a(Lain::Approval::Queue)
    end

    # T12 AC1: no --auto-approve, no third surface -- unchanged wiring.
    it "wires no auto surface without --auto-approve" do
      wire_agent
      expect(wiring.auto_surface).to be_nil
    end

    # T12 AC1: --auto-approve constructs the surface over the SAME role_spawn
    # seam a `@role/skill` line folds through.
    it "wires an AutoSurface over its own role_spawn seam under --auto-approve" do
      wiring = described_class.new(options: { grace: 5, auto_approve: true }, chronicle:, status_feed:)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)

      expect(wiring.auto_surface).to be_a(Lain::Approval::AutoSurface)
    end
  end

  # B1: the tool-phase guard was constructed bare (`RefuseSecretWrites.new`
  # with no `journal:`), so a live credential-shaped refusal journaled to
  # `Channel::Null` and left no record while every other mount of this
  # middleware (consolidation.rb, improve.rb, run_recorder.rb) passes one.
  describe "the secret-write guard's journal wiring" do
    def credential_tool_use
      { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
        "input" => { "id" => "creds", "description" => "oops", "body" => "sk-#{"a" * 20}" } }
    end

    let(:credential_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [credential_tool_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end
    let(:backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: credential_provider)
    end

    def build_agent_and_recorder
      recorder, session = wiring.run_state(nil)
      [wiring.wire_agent(channel:, recorder:, session:, backend:), recorder]
    end

    context "a wired chat whose journal is capturing" do
      let(:journal) { RecordingChannel.new }
      # journal_path: a bogus-but-harmless NDJSON name -- Chronicle#spool
      # derives the WAL path from it via pure string manipulation
      # (Paths.wal_for) and ResponseWal opens its file lazily on the first
      # frame, which a Provider::Mock-backed run never writes.
      let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "b1-spec-fake-session.ndjson") }

      it "records a WriteRefused naming the matched pattern when a credential-shaped memory_write is refused" do
        agent, = build_agent_and_recorder
        agent.ask("please remember this credential")

        refusal = journal.events.find { |event| event.is_a?(Lain::Telemetry::WriteRefused) }
        expect(refusal).not_to be_nil
        expect(refusal.pattern).to eq("openai-style api key")
      end
    end

    context "a wired chat started with --no-journal" do
      let(:chronicle) { Lain::CLI::Chronicle::Null.new }

      it "still refuses a credential-shaped memory_write, and nothing raises" do
        agent, recorder = build_agent_and_recorder

        expect { agent.ask("please remember this credential") }.not_to raise_error
        expect { recorder.fetch("creds") }.to raise_error(Lain::Memory::Index::UnknownId)
      end
    end
  end

  # B4: the guard's `oracle:` seam sat on its NullOracle in the live chat, so
  # the memory-save gate judged nothing there. Wiring it in composes the two
  # findings B2 separated: a credential is a PATTERN hit, a contentless save is
  # the oracle's DECLINE, and they must stay distinguishable in the journal.
  describe "the secret-write guard's oracle wiring" do
    let(:journal) { RecordingChannel.new }
    # See B1's note above on journal_path: pure string manipulation derives the
    # WAL path, and a Provider::Mock run never writes a frame.
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "b4-spec-fake-session.ndjson") }
    let(:backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: dispatching_provider)
    end
    let(:dispatching_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [tool_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end

    def dispatch
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
      agent.ask("do the thing")
      [agent, recorder]
    end

    def refusals = journal.events.grep(Lain::Telemetry::WriteRefused)

    # The dispatched tool's own answer, read back off the committed timeline --
    # the only place a middleware-withheld call and a downstream one can be told
    # apart without reaching inside the stack.
    def tool_results(agent)
      agent.timeline.to_a.map(&:content).grep(Array).flatten.grep(Hash)
           .select { |block| block["type"] == "tool_result" }.map { |block| block["content"] }.join("\n")
    end

    context "a memory_write whose body is a git commit SHA" do
      let(:sha) { "9a1b2c3d4e5f60718293a4b5c6d7e8f901234567" }
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
          "input" => { "id" => "head-sha", "description" => "the commit under test", "body" => sha } }
      end

      it "is not refused, and the item lands in the recorder" do
        _agent, recorder = dispatch

        expect(refusals).to be_empty
        expect(recorder.fetch("head-sha").body).to eq(sha)
      end
    end

    context "a memory_write carrying an API-key-shaped body" do
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
          "input" => { "id" => "creds", "description" => "oops", "body" => "sk-#{"a" * 20}" } }
      end

      it "is refused under the pattern's name, never as the oracle's decline" do
        _agent, recorder = dispatch

        expect(refusals.map(&:pattern)).to eq(["openai-style api key"])
        expect(Lain::Middleware::RefuseSecretWrites.decline?(refusals.first.pattern)).to be(false)
        expect { recorder.fetch("creds") }.to raise_error(Lain::Memory::Index::UnknownId)
      end
    end

    context "a memory_write with a blank body" do
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
          "input" => { "id" => "nothing", "description" => "empty", "body" => "  \n\t " } }
      end

      it "is refused as the oracle's decline, under no pattern name" do
        agent, recorder = dispatch

        expect(refusals.map(&:pattern)).to eq([Lain::Middleware::RefuseSecretWrites::ORACLE_DECLINE])
        expect(Lain::Middleware::RefuseSecretWrites.decline?(refusals.first.pattern)).to be(true)
        expect(Lain::Middleware::RefuseSecretWrites::PATTERNS).not_to have_key(refusals.first.pattern)
        expect { recorder.fetch("nothing") }.to raise_error(Lain::Memory::Index::UnknownId)
        # B2's model-facing half: a decline must make no credential claim.
        expect(tool_results(agent)).to include("not worth writing")
        expect(tool_results(agent)).not_to include("pattern")
      end
    end

    # GUARDED_TOOLS holds improvement_write too, and its input is
    # {note, kind, evidence_digests} -- no `body`. The gate abstains there
    # (MemorySave::Gate::JUDGED_FIELD), and if it ever stops abstaining this
    # wiring refuses EVERY improvement note. The chat toolset does not carry the
    # tool, so reaching Handler::Live's unknown-tool answer is the proof the
    # guard let it through rather than withholding it.
    context "an improvement_write, which carries no body for the gate to judge" do
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "improvement_write",
          "input" => { "note" => "the guard should not judge this", "kind" => "insight",
                       "evidence_digests" => [] } }
      end

      it "reaches downstream rather than being declined" do
        agent, = dispatch

        expect(refusals).to be_empty
        expect(tool_results(agent)).to include('no tool named "improvement_write"')
      end
    end
  end

  # T1: a streamed tool's bytes are a VIEW, not a record. Wiring hands
  # Handler::Live a fan-out over the run's TTY Channel AND the editor's, so
  # nvim's lain://journal sees what the terminal sees -- while the durable
  # NDJSON keeps only the turn's tool_result (Tools::Bash.render_output),
  # which is where those same bytes already are.
  describe "streamed tool output on the live views" do
    let(:bash_use) do
      { "type" => "tool_use", "id" => "tu_bash", "name" => "bash", "input" => { "command" => "printf hello" } }
    end
    let(:streaming_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [bash_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end
    let(:backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: streaming_provider)
    end
    # The TTY leg, recorded rather than a real SizedQueue: nothing drains it here.
    let(:channel) { RecordingChannel.new }
    let(:view_channel) { Lain::Channel::DropOldest.new }
    let(:journal) { RecordingChannel.new }
    # See B1's note on journal_path: Chronicle#spool derives the WAL path by
    # pure string manipulation, and a Provider::Mock run never writes a frame.
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "t1-spec-fake-session.ndjson") }
    let(:views) { { channel: view_channel, socket_path: "/tmp/lain-t1-spec.sock", journal: } }
    # --yolo, because bash is tier 3 and would otherwise park on the approval
    # gate; this block is about where the bytes go, not who let them run.
    let(:wiring) { described_class.new(options: { grace: 5, yolo: true }, chronicle:, status_feed:) }

    def dispatch(attached)
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:, views: attached)
      agent.ask("run it")
      agent
    end

    def streamed(events) = events.grep(Lain::Telemetry::ToolOutput)

    # The tool's own answer off the committed timeline -- proof the call
    # completed rather than dying inside the fan-out.
    def tool_results(agent)
      agent.timeline.to_a.map(&:content).grep(Array).flatten.grep(Hash)
           .select { |block| block["type"] == "tool_result" }.map { |block| block["content"] }.join("\n")
    end

    it "fans a bash tool's stdout onto the editor's Channel as well as the TTY's" do
      dispatch(views)

      expect(streamed(channel.events).map(&:bytes).join).to include("hello")
      expect(streamed(view_channel.drain).map { |event| [event.tool_use_id, event.stream, event.bytes] })
        .to eq([["tu_bash", :stdout, "hello"]])
    end

    it "keeps the streamed bytes off the durable record, which already carries them in the tool_result" do
      agent = dispatch(views)

      expect(streamed(journal.events)).to be_empty
      expect(tool_results(agent)).to include("hello")
    end

    it "completes the tool, and still renders to the TTY, when the editor quit and closed its Channel" do
      view_channel.close
      agent = dispatch(views)

      expect(streamed(channel.events).map(&:bytes).join).to include("hello")
      expect(tool_results(agent)).to include("hello")
    end

    it "renders to the TTY and raises nothing when no editor is attached" do
      agent = dispatch(nil)

      expect(streamed(channel.events).map(&:bytes).join).to include("hello")
      expect(tool_results(agent)).to include("hello")
    end
  end

  # A8: the assembly, and the point the whole chunk converges on. A plain `lain
  # chat` compacts, which means the Agent gets three things Wiring never passed
  # before: the run's per-turn Context source, the eager-summary observer its
  # ToolRunner fires through, and a journal that TEES turn_usage to that source
  # -- `context_for`'s `usage:` is A2's Integer, while {Lain::Compaction::Cold}
  # needs a {Lain::Telemetry::TurnUsage}'s cache-read count and the render seam
  # has no route to it.
  describe "the compaction mount" do
    require "tmpdir"

    let(:summary_text) { "EAGER-SUMMARY-OF-THE-BIG-RESULT" }
    let(:big_file) { File.join(@dir, "big.txt") }

    # Only the two network edges are doubled: the chat provider and the eager
    # tier. The Eager itself, the observer, the snapshot, the scheduler and the
    # render are the real wiring under test.
    let(:summarizing_backend_class) do
      Class.new(Lain::CLI::Backend) do
        def initialize(options, mock:, oracle:)
          super(options)
          @mock = mock
          @oracle = oracle
        end

        def provider(**) = @mock

        def eager = @eager ||= Lain::Oracle::Eager.new(oracle: @oracle)
      end
    end

    let(:reading_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [read_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end

    let(:read_use) do
      { "type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => { "path" => big_file } }
    end

    # compact_keep 1 + compact_bytes 1 puts every turn past the byte threshold,
    # so what decides is TIMING -- and Provider::Mock's NO_CACHING profile makes
    # the first turn_usage confirm the cache cold, which is only true if the
    # source is actually on the journal's sink list.
    let(:compaction_options) { { provider: "ollama", model: nil, max_tokens: 64, compact_keep: 1, compact_bytes: 1 } }

    let(:backend) do
      summarizing_backend_class.new(compaction_options, mock: reading_provider,
                                                        oracle: WiringSpecSummarizer.new(summary_text))
    end

    let(:journal) { RecordingChannel.new }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "a8-spec-fake-session.ndjson") }

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        File.write(File.join(dir, "big.txt"), "the quick brown fox jumped over the lazy dog. " * 140)
        example.run
      end
    end

    # A bounded spin, never a synchronization: the fire resolves on its own
    # fiber and the timeout turns "it never did" into a report instead of a hang.
    def settle(task, eager, digest)
      task.with_timeout(1) { task.sleep(0.001) while eager.held(digest).nil? }
    end

    # Read off the Agent rather than re-asked of the Backend: `#pipeline_source`
    # binds its journal on the FIRST call and now refuses a differing second
    # one, so a spec that re-asked with different arguments would be exercising
    # a wiring the run never performs.
    def source_of(agent) = agent.instance_variable_get(:@pipeline_source)

    def decisions = journal.events.grep(Lain::Compaction::Source::CompactionDecision)

    # Two asks, because the head a compaction can profitably drop only exists
    # once the first turn's big tool_result is behind the trailing window: the
    # opening exchange alone is small enough that Source#shrinks? refuses the
    # rewrite. The settle between them is what makes the eager fire observable.
    def converse(agent)
      Sync do |task|
        agent.ask("read it")
        settle(task, backend.eager, Lain::Canonical.digest(File.read(big_file)))
        agent.ask("now summarize what you saw")
      end
    end

    # ONE Eager, reached from both ends: the observer fires into it and the
    # source snapshots it. Two instances would mean every fire landed somewhere
    # no render reads, with `hits` reporting an honest, useless zero.
    it "hands the Agent the run's ONE source and its ONE summary observer" do
      agent = wire_agent

      expect(source_of(agent)).to be_a(Lain::Compaction::Source)
      expect(agent.instance_variable_get(:@tool_runner).instance_variable_get(:@observer)).to be(backend.tool_observer)
      expect(backend.tool_observer.instance_variable_get(:@eager)).to be(backend.eager)
      expect(source_of(agent).instance_variable_get(:@eager)).to be(backend.eager)
    end

    # Without the tee `Cold` is never fed, the `:cold` decision path is dead on
    # the live path, and every compaction journals `cache_state: forced` -- a
    # bench arm that measures nothing.
    it "tees turn_usage to the source, so a zero cache-read confirms the cache cold" do
      agent = wire_agent
      cold = source_of(agent).instance_variable_get(:@cold)
      expect(cold).not_to be_cold

      Sync { agent.ask("read it") }

      expect(cold).to be_cold
      # Provider::Mock carries NO_CACHING, so there is no TTL for an idle mark
      # to compare against and each zero cache-read confirms on its own -- one
      # per model round trip, and a tool-use turn makes two.
      confirmations = journal.events.grep(Lain::Compaction::Cold::CacheColdConfirmed)
      expect(confirmations.map(&:reason).uniq).to eq([:signal_only])
    end

    # The live chat Context is deliberately NOT Ractor-shareable -- /model's
    # slot is mutable by design (model_switch.rb:20-22) -- so the composed
    # per-turn pipeline has to be built from a flattened twin. Without that,
    # EVERY compacting turn of every real chat raises Ractor::IsolationError out
    # of Scheduler::COMPOSE, and no spec holding a plain Context can see it.
    it "compacts a Context carrying the live /model slot, which is not shareable" do
      agent = wire_agent
      expect(Ractor.shareable?(agent.context)).to be(false)

      expect { converse(agent) }.not_to raise_error

      expect(decisions.map(&:compacted)).to include(true)
    end

    # AC3, end to end: the tool result crosses Summarizing's threshold, the
    # post-dispatch observer fires a summary into the run's Eager, and the next
    # render -- which compacts, because the cache is cold -- carries the FIRED
    # TEXT where an unwired run would carry an elision line.
    it "renders the summary a tool dispatch fired, not an elision line" do
      converse(wire_agent)

      rendered = Lain::Canonical.dump(reading_provider.last_request.messages)

      expect(rendered).to include(summary_text)
      # The dropped bytes are really gone -- the summary replaced them rather
      # than riding alongside. (The turn's other blocks -- a plain text turn, a
      # tool_use -- still carry ELIDED lines: nothing is summarizable there, and
      # attesting them is the invariant, not a miss.)
      expect(rendered).not_to include("the quick brown fox jumped over the lazy dog. " * 5)
      expect(decisions.map(&:compacted)).to include(true)
      expect(decisions.map(&:summary_hits).max).to be >= 1
    end

    # The live half of the review's cost-honesty fix. This run's model is
    # Ollama's local default, which Backend::COMPACTION_PRICES prices at zero
    # -- so the accounting reads "$0.0", and WITHOUT the model beside it that
    # is indistinguishable on the record from a compaction that genuinely cost
    # nothing. It is also what a reader needs to spot a `/model` switch: this
    # names the tier the estimate was priced against, TurnUsage names the tier
    # that answered, and after a switch they differ.
    it "journals the model its zero cost figures are quoted in" do
      converse(wire_agent)

      accounting = journal.events.grep(Lain::Telemetry::Compaction)
      expect(accounting).not_to be_empty
      expect(accounting.map(&:model).uniq).to eq([Lain::Provider::Ollama::DEFAULT_MODEL])
      expect(accounting.map(&:cost_saved).uniq).to eq(["0.0"])
    end

    context "--no-compact" do
      let(:compaction_options) { super().merge(compact: false) }

      it "leaves the Agent on the Null source, rendering exactly as an unwired chat would" do
        agent = wire_agent

        Sync { agent.ask("read it") }

        expect(source_of(agent)).to be(Lain::Agent::PipelineSource::Null)
        expect(Lain::Canonical.dump(reading_provider.last_request.messages)).not_to include(summary_text)
        expect(decisions).to be_empty
      end
    end
  end

  # D2: `--isolation`, wired at the ONE seam the fleet leases through. The main
  # chat is deliberately NOT leased -- #run_state builds its Session on
  # {Lain::WorkerEnv.default}, because the user's own edits belong in the user's
  # own tree -- so what a leased environment reaches is an ACTOR-mode subagent,
  # adopted through this Supervisor.
  describe "the fleet's isolation backend" do
    require "fileutils"
    require "mixlib/shellout"
    require "tmpdir"

    # The journal Wiring hands the Supervisor is the run's live Channel; a
    # recording stand-in is what lets the lease records be read back (and never
    # blocks, unlike a SizedQueue nobody drains).
    let(:channel) { RecordingChannel.new }

    def wiring_with(isolation)
      described_class.new(options: { grace: 5, isolation: }, chronicle:, status_feed:)
    end

    # Adoption is what leases: the Supervisor acquires the worker's environment
    # and hands it to the launch block, exactly as {Lain::Tools::Subagent}'s
    # `mode: :actor` dispatch does. The supervisor's own reactor task is what an
    # actor outlives, so the adoption runs under a Sync the spec holds.
    def adopt_worker(wiring)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)
      Sync do |task|
        wiring.supervisor.run(task)
        wiring.supervisor.adopt(role: "researcher") { |worker_env| WiringSpecWorker.new(worker_env) }
      ensure
        wiring.supervisor.stop
      end
    end

    def leases = channel.events.grep(Lain::Telemetry::IsolationLease)

    # A chat started somewhere OTHER than the repo this suite runs in, so "the
    # lease names the chat's own cwd" is an assertion and not a coincidence --
    # and so no `.lain/services.rb` of the host project can decorate the backend.
    def in_throwaway_chat_dir(&block)
      Dir.mktmpdir("lain-d2-chat") { |dir| Dir.chdir(File.realpath(dir), &block) }
    end

    context "wired with no isolation option" do
      it "leases the chat's own process environment -- the shared-process default" do
        chat_cwd = nil
        worker = in_throwaway_chat_dir do |dir|
          chat_cwd = dir
          adopt_worker(wiring_with(nil))
        end

        expect(worker.session.worker_env.cwd).to eq(chat_cwd)
        expect(worker.session.worker_env.env).to eq(ENV.to_h)
      end

      # The resolver decorates BY NEED, so a run whose journal records anything
      # never holds a bare Null -- what a spec can see is the concrete backend
      # NAMED on the lease record the Journal decorator emits.
      it "resolves the shared-process backend, journalled, so the lease is on the record" do
        in_throwaway_chat_dir { adopt_worker(wiring_with(nil)) }

        expect(leases.map { |lease| [lease.kind, lease.backend] })
          .to eq([[:acquired, "Lain::Isolation::Null"], [:released, "Lain::Isolation::Null"]])
      end
    end

    context "wired with the worktree isolation option" do
      # The spec's own git calls reuse the backend's pinned scrub set, so the
      # throwaway repo is built hermetically under a GIT_*-polluted env (a
      # pre-commit hook) exactly as the backend runs.
      def run_git(dir, *args)
        Mixlib::ShellOut.new("git", "-C", dir, *args,
                             environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.error!
      end

      def seed_repo(dir)
        run_git(dir, "init", "-q")
        run_git(dir, "config", "user.email", "test@example.com")
        run_git(dir, "config", "user.name", "Test")
        File.write(File.join(dir, "README"), "seed\n")
        run_git(dir, "add", "README")
        run_git(dir, "commit", "-q", "-m", "seed")
      end

      # A throwaway repo AND a throwaway XDG_RUNTIME_DIR: the leased checkouts
      # land under the tmpdir, never the machine's real runtime dir and never the
      # lain repo this suite runs in.
      def in_throwaway_repo
        Dir.mktmpdir("lain-d2-project") do |project|
          Dir.mktmpdir("lain-d2-runtime") do |runtime|
            repo = File.realpath(project)
            seed_repo(repo)
            Dir.chdir(repo) { with_env("XDG_RUNTIME_DIR" => File.realpath(runtime)) { yield repo } }
          end
        end
      end

      it "hands the supervisor the resolved worktree backend" do
        in_throwaway_repo { adopt_worker(wiring_with("worktree")) }

        expect(leases.map(&:backend).uniq).to eq(["Lain::Isolation::Worktree"])
      end

      it "runs the adopted actor's session against the leased checkout, not the chat's cwd" do
        chat_cwd = nil
        worker = in_throwaway_repo do |repo|
          chat_cwd = repo
          adopt_worker(wiring_with("worktree"))
        end
        leased = worker.session.worker_env.cwd

        expect(leased).not_to eq(chat_cwd)
        # A REAL checkout, not a path the lease merely named: it exists, git
        # knows it (`.git` is a file inside a linked worktree), and it carries
        # the repo's seeded content -- so the cwd below is somewhere a child's
        # tools can actually work, which `#resolve`'s string math cannot show.
        expect(worker.checkout).to eq({ exists: true, repo: true, seeded: true })
        expect(worker.session.worker_env.resolve("notes.md")).to eq(File.join(leased, "notes.md"))
      end
    end

    # Resolved BEFORE {Lain::CLI::Chronicle#start} pins the header, so the
    # refusal lands while the session record is still empty -- the same
    # refusal-before-journal ordering --resume and --fork already keep.
    context "wired with an unrecognized isolation option" do
      it "raises a Lain::Error and leaves no session record behind" do
        Dir.mktmpdir("lain-d2-state") do |state|
          paths = Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => state })
          journaled = Lain::CLI::Chronicle.for(enabled: true, paths:)
          wiring = described_class.new(options: { grace: 5, isolation: "docker" }, chronicle: journaled, status_feed:)
          recorder, session = wiring.run_state(nil)

          expect { wiring.wire_agent(channel:, recorder:, session:, backend:) }
            .to raise_error(Lain::Error, /unknown isolation backend "docker".*none.*worktree/m)

          journaled.close(reason: :exit)
          # T3: "no session record behind" is now literal. A journal that
          # closes with nothing ever recorded into it removes its own file, so
          # the zero-byte artifact never reaches the readers that pick the
          # newest session (--resume, --fork, watch, sessions).
          expect(File).not_to exist(journaled.journal_path)
        end
      end
    end
  end

  describe "#run" do
    require "stringio"
    require "tmpdir"

    # The T9 injection seams: a spec assembles and runs the whole conversation
    # through #run's own path -- no send(:build_repl), no instance_variable_set
    # -- by handing in a StringIO-backed TTY factory and a recording conductor
    # opener instead of the real-terminal defaults.
    let(:opened) { [] }
    let(:conductor_opener) { ->(**kwargs) { Lain::CLI::Conductor.open(**kwargs).tap { |c| opened << c } } }

    def tty_factory(input, dir)
      lambda do |channel:|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, input: StringIO.new(input),
                                history_path: File.join(dir, "history"))
      end
    end

    def run_wiring(input: "quit\n", options: { grace: 5 })
      Dir.mktmpdir do |dir|
        wiring = described_class.new(options:, chronicle:, status_feed:,
                                     tty_factory: tty_factory(input, dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        wiring
      end
    end

    it "threads the injected tty/conductor seams -- the conductor the opener built is the one exposed" do
      wiring = run_wiring

      expect(opened).to eq([wiring.conductor])
    end

    # T7: the Conductor is the ONE place a user prompt is answered, so it is
    # where RunClock#record_input is called -- and the clock it records on has
    # to be the one the StatusFeed publishes, or the published idle never
    # resets. ChatLaunch builds it; this class only has to pass it on.
    it "passes the run's RunClock on to the conductor it opens" do
      run_clock = Lain::RunClock.new
      seen = []
      opener = ->(**kwargs) { Lain::CLI::Conductor.open(**kwargs).tap { seen << kwargs[:run_clock] } }

      Dir.mktmpdir do |dir|
        wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:, run_clock:,
                                     tty_factory: tty_factory("quit\n", dir), conductor_opener: opener)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      expect(seen).to eq([run_clock])
    end

    it "assembles the frozen Command::Env once, nil-free, from the collaborators it wired" do
      wiring = run_wiring
      env = wiring.command_env

      expect(env).to be_frozen
      expect(env.sessions).to be_a(Lain::CLI::Sessions)
      expect(env.tmux_surface).to be_a(Lain::CLI::TmuxSurface)
      expect(env.approvals).to be(wiring.approvals)
      expect(env.supervisor).to be(wiring.supervisor)
      expect(env.replies).to be_a(Lain::CLI::HumanReplies)
      expect(env.agent).to be_a(Lain::Agent)
      expect(env.status).to be(status_feed)
      expect(env.fork_point).to be_a(Lain::CLI::ForkPoint)
      expect(env.chronicle).to be(chronicle)
    end

    # The load-bearing identity AC1/AC3 stand on (T14 panel probe 7): a dropped
    # surface_kwargs would leave these readers on their Nulls and silently
    # disconnect /yolo from the Gate and /model from the Agent's Context.
    it "hands the Env the SAME switches the Gate and the Agent's context hold" do
      wiring = run_wiring
      env = wiring.command_env

      expect(env.policy_switch).to be_a(Lain::Approval::PolicySwitch)
      expect(env.policy_switch.current).to be(wiring.approvals)

      expect(env.model_switch).to be_a(Lain::Context::ModelSwitch)
      expect(env.agent.context.model).to eq(env.model_switch.current)
      env.model_switch.switch("probe-model-x", surface: "probe")
      expect(env.agent.context.model).to eq("probe-model-x")
    end

    it "wires the queue-shaped YoloApprovals under --yolo, so the env reader stays nil-free" do
      wiring = run_wiring(options: { grace: 5, yolo: true })

      expect(wiring.command_env.approvals).to be(Lain::CLI::Command::Env::YoloApprovals)
    end
  end
end
