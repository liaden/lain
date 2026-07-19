# frozen_string_literal: true

require "async"
require "json"
require "open3"
require "stringio"
require "tmpdir"

# W4, the chunk's flagship: supervision-as-replay. A killed actor's session
# record -- the SAME NDJSON file M2 resume loads -- replays through
# Bench::Session::Loader's verified re-commit (never a second replay
# implementation), its file bytes come back from the journal's own
# workspace_blob sidecar records, the last :snapshot restores through W2's
# Workspace::Restore, and the revived actor is adopted under the Supervisor.
RSpec.describe Lain::Supervisor::Restart do
  around do |example|
    Dir.mktmpdir("restart-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  # A structured mutating tool (edit_file's posture without its read-first
  # contract): writes `content` under the workspace root and records the
  # write, so the Agent's snapshot_writer has a write-set to capture.
  before do
    stub_const("ScribbleTool", Class.new(Lain::Tool) do
      def initialize(root:)
        super()
        @root = root
      end

      def name = "scribble"
      def description = "Writes content to a file under the workspace."

      def input_schema
        { type: :object, properties: { name: { type: :string }, content: { type: :string } },
          required: %i[name content] }
      end

      def perform(input, invocation)
        path = File.join(@root, input.fetch("name"))
        File.write(path, input.fetch("content"))
        session_of(invocation).record_write(path)
        Lain::Tool::Result.ok("wrote #{input.fetch("name")}")
      end
    end)
  end

  let(:store) { Lain::Store.new }
  let(:parent_timeline) do
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "keep notes" }])
  end
  let(:context) { Lain::Context.new(model: "actor", max_tokens: 128) }
  let(:toolset) { Lain::Toolset.new([ScribbleTool.new(root: dir)]) }
  let(:record_io) { StringIO.new }
  let(:record_journal) { Lain::Journal.new(io: record_io) }
  let(:restart_journal) { Lain::Channel.new }
  let(:revive_provider) { Lain::Provider::Mock.new(responses: []) }

  # Three assistant turns, two of them mutating: notes.md lands as v1, then v2
  # beside log.md -- so the record carries two :snapshot events, three blobs.
  let(:life_responses) do
    [
      tool_response(["t1", "scribble", { "name" => "notes.md", "content" => "v1" }]),
      tool_response(["t2", "scribble", { "name" => "notes.md", "content" => "v2" }],
                    ["t3", "scribble", { "name" => "log.md", "content" => "one restart survived" }]),
      text_response("notes kept")
    ]
  end

  def spawn_policy = Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: [])

  # The recording wiring under test: the snapshot writer's observer chain runs
  # JournalBlobs (the sidecar) into the session scribe, exactly the seam a
  # production exe would wrap.
  def scribed_agent(provider, observer)
    Lain::Agent.new(provider:, toolset:, context:, timeline: Lain::Timeline.empty(store:),
                    snapshot_writer: Lain::Workspace::Snapshot.new(observer:, root: dir))
  end

  def scribed_actor(provider)
    scribe = Lain::SessionRecord::Scribe.new(journal: record_journal, context:, toolset:)
    observer = described_class::JournalBlobs.new(journal: record_journal, store:, observer: scribe)
    actor = Lain::Tools::Subagent::Actor.new(agent: scribed_agent(provider, observer), parent: parent_timeline,
                                             lineage: Lain::Tools::Subagent::Lineage.new(policy: spawn_policy))
    [actor, scribe]
  end

  # Life 1: a real Actor over a scribed Agent, launched under a host task we
  # hold so the kill is abrupt -- host.stop cancels the parked fiber the way a
  # dying process would, landing no farewell and no session_closed record.
  def record_killed_actor(task, provider:)
    actor, scribe = scribed_actor(provider)
    host = task.async { actor.launch("keep the notes current") }
    # The initial turn does real file IO, so the launch's synchronous prefix
    # suspends before @task is assigned and a bare settle races NotLaunched --
    # await the launch block itself first, {Supervisor#adopt}'s own `.wait`
    # discipline.
    host.wait
    actor.settle
    scribe.catch_up(actor.timeline)
    host.stop
    host.wait
    actor
  end

  def restart_over(entries, supervisor:, force: false)
    described_class.new(entries:, supervisor:, journal: restart_journal, root: dir, force:)
                   .call(role: "researcher") do |recording|
      Lain::Agent.new(provider: revive_provider, toolset:, context:, timeline: recording.timeline)
    end
  end

  def journal_records(type)
    record_io.string.each_line.filter_map { |line| JSON.parse(line) }.select { |r| r["type"] == type }
  end

  def workspace_file(name) = File.join(dir, name)

  # ---- Scenario: crash and resume --------------------------------------------

  it "resumes a killed actor: head equals the last committed turn, workspace matches " \
     "the last snapshot, and the restart journals both digests" do
    killed_head = nil
    result = nil
    provider = Lain::Provider::Mock.new(responses: life_responses)

    Sync do |task|
      actor = record_killed_actor(task, provider:)
      expect(actor).to be_stopped # the kill landed: the fiber is gone
      killed_head = actor.timeline.head_digest
      # The crash took the process; the workspace died with the machine -- the
      # restored files must come from the RECORD, not the ruins.
      File.delete(workspace_file("notes.md"), workspace_file("log.md"))

      supervisor = Lain::Supervisor.new.run(task)
      result = restart_over(record_io.string.each_line, supervisor:)

      expect(result.actor.timeline.head_digest).to eq(killed_head)
      expect(supervisor.map(&:role)).to eq(["researcher"])
      expect(supervisor.map(&:state)).to eq([:running])
      expect(supervisor.map(&:head_digest)).to eq([killed_head])
      supervisor.stop
    end

    expect(File.read(workspace_file("notes.md"))).to eq("v2")
    expect(File.read(workspace_file("log.md"))).to eq("one restart survived")
    expect(result.notices.join).to include("not gracefully closed")

    restarted = restart_journal.drain.map(&:to_journal).find { |r| r["type"] == "restarted" }
    expect(restarted).not_to be_nil
    expect(restarted["head"]).to eq(killed_head)
    expect(restarted["snapshot"]).to eq(result.snapshot)
    expect(result.snapshot).to be_a(String)
  end

  # ---- Scenario: restart is replay, not re-spend -----------------------------

  it "makes zero provider calls during replay -- the same no-respend property as resume" do
    provider = Lain::Provider::Mock.new(responses: life_responses)

    Sync do |task|
      record_killed_actor(task, provider:)
      supervisor = Lain::Supervisor.new.run(task)
      restart_over(record_io.string.each_line, supervisor:)
      supervisor.stop
    end

    expect(provider.requests.size).to eq(3) # life 1's spend, unchanged
    expect(revive_provider.requests).to be_empty
  end

  # ---- Scenario: the demo driver runs it end-to-end --------------------------

  it "bin/demo-supervision prints the kill, the restart, and matching head digests, exit 0" do
    root = File.expand_path("../../..", __dir__)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.join(root, "lib"),
      "-r", File.join(root, "spec", "bootsnap_setup"),
      File.join(root, "bin", "demo-supervision")
    )

    expect(status).to be_success, "demo failed (status #{status.exitstatus}): #{stderr}\n#{stdout}"
    expect(stdout).to match(/kill/i)
    expect(stdout).to match(/restart/i)
    heads = stdout.scan(/blake3:\h+/)
    expect(heads.size).to be >= 2
    expect(heads.last(2).uniq.size).to eq(1) # the printed head digests match
  end

  # ---- The workspace-blob sidecar (closing W1's stated persistence gap) ------

  describe "the workspace_blob sidecar records" do
    it "journals each blob once, content-addressed: an unchanged file's bytes are never re-journaled" do
      # a.txt is unchanged at snapshot 2, so its digest rides BOTH snapshot
      # maps while its bytes land exactly once.
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(["t1", "scribble",
                                                           { "name" => "a.txt", "content" => "alpha" }]),
                                            tool_response(["t2", "scribble",
                                                           { "name" => "b.txt", "content" => "beta" }]),
                                            text_response("done")
                                          ])
      Sync { |task| record_killed_actor(task, provider:) }

      snapshots = journal_records("message").select { |r| r["kind"] == "snapshot" }
      expect(snapshots.size).to eq(2)
      expect(snapshots.last["payload"].fetch("files").keys).to contain_exactly("a.txt", "b.txt")

      blobs = journal_records("workspace_blob")
      expect(blobs.size).to eq(2)
      expect(blobs.map { |r| r["digest"] }).to match_array(snapshots.last["payload"].fetch("files").values)
    end

    it "still replays a journal WITHOUT blob records (pre-W4): the head restores, " \
       "the files honestly do not, and the gap is a loud notice" do
      killed_head = nil
      result = nil
      provider = Lain::Provider::Mock.new(responses: life_responses)

      Sync do |task|
        killed_head = record_killed_actor(task, provider:).timeline.head_digest
        File.delete(workspace_file("notes.md"), workspace_file("log.md"))
        stripped = record_io.string.each_line.reject { |line| JSON.parse(line)["type"] == "workspace_blob" }

        supervisor = Lain::Supervisor.new.run(task)
        result = restart_over(stripped, supervisor:)
        supervisor.stop
      end

      expect(result.actor.timeline.head_digest).to eq(killed_head)
      expect(result.notices.join).to match(/blob/i)
      expect(result.restored.written).to be_empty
      expect(File.exist?(workspace_file("notes.md"))).to be(false)
    end

    it "refuses a blob whose bytes no longer match their content address" do
      provider = Lain::Provider::Mock.new(responses: life_responses)
      Sync { |task| record_killed_actor(task, provider:) }

      tampered_yet = false
      tampered = record_io.string.each_line.map do |line|
        record = JSON.parse(line)
        if record["type"] == "workspace_blob" && !tampered_yet
          tampered_yet = true
          JSON.generate(record.merge("bytes_b64" => ["evil"].pack("m0")))
        else
          line
        end
      end

      expect { restart_over(tampered, supervisor: Lain::Supervisor.new) }
        .to raise_error(Lain::Bench::Session::Corrupt, /content address/)
    end
  end

  # ---- Reuse of W2's restore semantics ---------------------------------------

  it "refuses to clobber post-crash out-of-band bytes (W2's Dirty), waived by force:" do
    provider = Lain::Provider::Mock.new(responses: life_responses)

    Sync do |task|
      record_killed_actor(task, provider:)
      File.write(workspace_file("notes.md"), "post-crash meddling")

      supervisor = Lain::Supervisor.new.run(task)
      expect { restart_over(record_io.string.each_line, supervisor:) }
        .to raise_error(Lain::Workspace::Restore::Dirty)
      expect(supervisor.to_a).to be_empty # a refused restore registers nothing

      restart_over(record_io.string.each_line, supervisor:, force: true)
      supervisor.stop
    end

    expect(File.read(workspace_file("notes.md"))).to eq("v2")
  end

  # ---- Edges -----------------------------------------------------------------

  it "restarts a read-only life: no snapshot in the record, nothing restored, snapshot rides nil" do
    provider = Lain::Provider::Mock.new(responses: [text_response("pondered, wrote nothing")])
    result = nil

    Sync do |task|
      record_killed_actor(task, provider:)
      supervisor = Lain::Supervisor.new.run(task)
      result = restart_over(record_io.string.each_line, supervisor:)
      supervisor.stop
    end

    expect(result.snapshot).to be_nil
    expect(result.restored.written).to be_empty
    restarted = restart_journal.drain.map(&:to_journal).find { |r| r["type"] == "restarted" }
    expect(restarted["snapshot"]).to be_nil
  end

  it "refuses a revival that does not stand at the replayed head, registering nothing" do
    provider = Lain::Provider::Mock.new(responses: life_responses)

    Sync do |task|
      record_killed_actor(task, provider:)
      supervisor = Lain::Supervisor.new.run(task)

      expect do
        described_class.new(entries: record_io.string.each_line, supervisor:,
                            journal: restart_journal, root: dir)
                       .call(role: "researcher") do |_recording|
          Lain::Agent.new(provider: revive_provider, toolset:, context:,
                          timeline: Lain::Timeline.empty(store: Lain::Store.new))
        end
      end.to raise_error(described_class::Diverged, /replayed head/)

      expect(supervisor.to_a).to be_empty
      supervisor.stop
    end
  end

  # ---- Scenario: restart re-acquires an equivalent lease (B5) ----------------
  #
  # The killed worker's lease died with its process; the restart RE-ACQUIRES a
  # fresh one via the supervisor's isolation backend and hands its WorkerEnv to
  # the revive block, so the revived worker runs under an equivalent isolated
  # environment. Released on the supervisor's #stop, like any adoption.

  # RecordingIsolation is the Isolation duck: real {Isolation::Lease}s over a
  # fixed WorkerEnv, recording every acquire/release by worker key.
  before do
    stub_const("RecordingIsolation", Class.new do
      attr_reader :acquired, :released

      def initialize(env)
        @env = env
        @acquired = []
        @released = []
      end

      def acquire(worker_id)
        @acquired << worker_id
        recorder = self
        Lain::Isolation::Lease.new(worker_env: @env, on_release: -> { recorder.released << worker_id })
      end
    end)
  end

  let(:leased_env) { Lain::WorkerEnv.new(cwd: File.join(dir, "worker-checkout"), env: { "REDIS_URL" => "redis://1" }) }

  it "re-acquires a fresh equivalent lease and the revived worker runs under it" do
    backend = RecordingIsolation.new(leased_env)
    seen = nil
    provider = Lain::Provider::Mock.new(responses: life_responses)

    Sync do |task|
      record_killed_actor(task, provider:)
      supervisor = Lain::Supervisor.new(isolation: backend).run(task)

      Lain::Supervisor::Restart.new(entries: record_io.string.each_line, supervisor:,
                                    journal: restart_journal, root: dir)
                               .call(role: "researcher") do |recording, worker_env|
        seen = worker_env
        Lain::Agent.new(provider: revive_provider, toolset:, context:,
                        timeline: recording.timeline, session: Lain::Session.new(worker_env:))
      end

      expect(backend.acquired.size).to eq(1)   # re-acquired on Restart#call
      expect(seen).to eq(leased_env)           # the revived worker's Session runs under it
      expect(supervisor.map(&:role)).to eq(["researcher"])
      supervisor.stop
    end

    expect(backend.released.size).to eq(1)     # released on teardown, like any adoption
  end

  # The escalation trigger: adding a side effect (re-acquire) to the pure-replay
  # restart path must fail the restart LOUDLY, never revive a worker with a
  # shared/leaked environment.
  it "fails the restart loudly when the lease cannot be re-acquired, reviving nothing" do
    failing = Class.new do
      def acquire(_worker_id) = raise(Lain::Error, "no isolation available")
    end.new
    provider = Lain::Provider::Mock.new(responses: life_responses)

    Sync do |task|
      record_killed_actor(task, provider:)
      supervisor = Lain::Supervisor.new(isolation: failing).run(task)

      expect { restart_over(record_io.string.each_line, supervisor:) }
        .to raise_error(Lain::Error, /no isolation/)
      expect(supervisor.to_a).to be_empty # no worker revived on a failed acquire
      supervisor.stop
    end
  end

  describe Lain::Supervisor::Restart::Revived do
    let(:agent) do
      Lain::Agent.new(provider: revive_provider, toolset:, context:, timeline: parent_timeline)
    end

    subject(:revived) { described_class.new(agent:, address: parent_timeline.head_digest) }

    it "answers the registration duck: settled at the checkpoint, stoppable, addressed by its head" do
      expect(revived.address).to eq(parent_timeline.head_digest)
      expect(revived.timeline).to eq(agent.timeline)
      expect(revived.settle).to eq(revived)
      expect(revived).not_to be_stopped
      expect(revived).not_to be_dead
      revived.stop
      expect(revived).to be_stopped
      expect(revived).to be_dead
    end

    it "refuses tell loudly: it holds no lineage to attribute a message through" do
      expect { revived.tell("hi") }.to raise_error(described_class::Unaddressed, /agent/)
    end
  end
end
