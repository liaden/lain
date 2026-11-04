# frozen_string_literal: true

require "bigdecimal"
require "stringio"

# Every record a reader can claim reads back from the bytes the Journal wrote as the value it
# was written from: the envelope, the JSON and every String-versus-Symbol field are under the law.
RSpec.describe Lain::Telemetry, ".read over every journaled record" do
  d = "blake3:#{"a" * 64}"

  # One instance per claimed record, by its constructor's keywords, each field off its default so a
  # dropped one shows. A record is keyed by its constant path under Telemetry.
  arguments = {
    AdmissionNarrowed: { endpoint: "http://127.0.0.1:11434", from_width: 4, to_width: 2, max_concurrent: 2, active: 1,
                         queue_limit: 8, queued: 3 },
    AskSettled: { head: d, stop_reason: "end_turn", turns: 2, seconds: 1.5 },
    AssistantText: { text: "hello" },
    AwaitingHuman: { kind: "approval", ref: "tu_1", deadline: "2026-11-02T09:05:00Z", summary: "bash",
                     requester: "agent", tool: "bash", tool_use_id: "tu_1", humans_only: true, notes: ["a note"],
                     input_digest: d, deferred: true, epic_slug: "e", stage: "review", issue_id: "i1", sha: "abc",
                     question_key: d },
    BudgetOvershoot: { ceiling: BigDecimal("1.5"), spent: BigDecimal("1.75"), overshoot: BigDecimal("0.25"),
                       model: "m", complete: true },
    CapabilityDegraded: { capability: "thinking", requirer: "agent", provider: "ollama" },
    ChildProgress: { spawn: d, turns: 3, label: "l", role: "r", skill: "s", task_line: "t", worker: "w", head: d },
    ChildStopped: { spawn: d, label: "l", role: "r", head: d, lease_path: "/w/c", ceiling: 20, reason: "transport",
                    snapshot: "abc", task: "t", parent: d, kept: true },
    ChildTurn: { digest: d, kind: :turn, from: "a", to: "b", render_parent: d, payload: { "role" => "user" },
                 causal_parents: [d], correlation: { "ask" => d } },
    ClaimDemoted: { strategy: "summarize", count: 2 },
    ClosureRecord: { closure_digest: d, step_id: "s1", plan_digest: d, size: "S", chunk_turn_digests: [d] },
    CommandRedacted: { tool_use_id: "tu_1", regions: 2, prior: 1 },
    Compaction: { trigger: %i[token_threshold], cache_state: :warm, bytes_before: 100, bytes_after: 50,
                  cost_saved: BigDecimal("0.002"), cost_spent: BigDecimal("0.0005"), model: "m",
                  collapse_strategy: "summarize" },
    CompactionCut: { digest: d, head: d, strategy: "s", kind: "advance", parent: d, supersedes: [],
                     collapses: [{ "span" => [d, d], "content" => [{ "type" => "text", "text" => "x" }] }],
                     plan_step_completions: 0 },
    ConsolidationLineage: { spawn: d, spawned_from: d, turn_count: 2, wrote: false,
                            failure: { "stop_reason" => "error", "message" => "boom" } },
    ContextDerived: { source_head: d, derived_head: d, strategy: "S", spans: [[d, d]], cut: :offered, moved: 1,
                      keep_last: 2, compaction_cut: d, mid_task: true },
    Dropped: { count: 3 },
    EditApplied: { path: "lib/a.rb", removed: ["old"], added: ["new"], hidden: 0 },
    EgressRefused: { host: "example.com", count: 2, turn: 1 },
    "EgressRefused::Flagged": { host: "example.com", regions: 2, values: 3 },
    ExecImage: { image: "/bin/ls", id: "sha256:abc", listed: true, reason: "listed" },
    ExecRecord: { tool_use_id: "tu_1", profile: :traced, execs: [{ "path" => "/bin/ls", "argv0" => "ls", "rc" => 0 }],
                  refusals: [], fd_execs: [], truncated: false, incomplete: true,
                  connects: [{ "host" => "example.com", "port" => 443 }], connects_dropped: 1 },
    ExecResolution: { tool_use_id: "tu_1", stages: [{ "program" => "ls" }] },
    FileWritten: { tool_use_id: "tu_1", path: "/r/a.rb", device: 1, inode: 2, ctime: 3 },
    FilesWritten: { role: "coder", paths: ["a.rb"] },
    FixtureTampered: { arm: "confine", paths: ["spec/fixtures/a"] },
    GradeRecord: { grader: "G", score: 0.5, pass: true, why: "fine", subject_digest: d, criteria_digest: d, arm: "a",
                   grader_digest: d },
    Handback: { worker_key: "w-1", outcome: :merged, ref: "refs/x", strategy: "s", fast_forward: true, sha: "abc",
                sync: :current, attempts: ["fast_forward"], dirty: true, path: "/p", detail: "d",
                checks: { "outcome" => "passed" } },
    IsolationLease: { kind: :acquired, worker_key: "w-1", backend: "B", service: "postgres", path: "/p", base: "abc",
                      branch: "feat" },
    JudgeBreakerTripped: { requester: "agent", count: 3, because: "timeouts" },
    JudgeRuled: { call: "tu_1", verdict: "approved" },
    LandingBatch: { branch: "main", desk: :parent, verifier: "rake spec", worker_keys: %w[w-1], landed: %w[w-1],
                    ejected: [], declined: [], verifies: 1, rebuilds: 0, verify_wall_s: 1.5,
                    queue_wait_s: { "w-1" => 0.2 },
                    outcome: :landed },
    MalformedResponse: { kind: :prose_tool_call, tool_name: "bash", excerpt: "x", model: "m" },
    MemoryLoaded: { version: "v1", items: [{ "key" => "k" }] },
    MemoryRoot: { turn_digest: d, root: d },
    Message: { digest: d, kind: :message, from: "a", to: "b", payload: { "text" => "hi" }, causal_parents: [d],
               correlation: { "ask" => d } },
    ModeSwitch: { from_scope: "checkout", to_scope: "plan", from_approval: "ask", to_approval: "auto", from_layers: [],
                  to_layers: [], surface: "slash" },
    ModelSwitch: { from: "a", to: "b", surface: "slash" },
    ObserverFailed: { hook: :after_commit, digest: d, message: "boom" },
    OracleAnswer: { oracle_digest: d, question: "q", answer: "a", model: "m", usage: { "input_tokens" => 1 },
                    wall_clock: 0.5 },
    OracleFailed: { tier: :local, oracle_digest: d, error_class: "Timeout" },
    OracleDeclined: { tier: :local, oracle_digest: d, reason: "busy" },
    PolicySwitch: { from: "a", to: "b", surface: "slash" },
    PriceTierCrossed: { model: "m", prompt_tokens: 200_001, boundary: 200_000, standard_cost: BigDecimal("1"),
                        tier_cost: BigDecimal("2"), decision: :approve },
    ProviderRetry: { attempt: 2, will_retry_in: 1.5, status: 529, reason: "overloaded", path: "/v1/messages" },
    ProviderWait: { kind: :waited, endpoint: "http://x", resolution_seconds: 0.1, in_flight: 1, waited_seconds: 0.25 },
    ReadRefused: { tool_use_id: "tu_1", tool: "read_file", path: ".env", reason: "secret", requester: "agent" },
    ReadReleased: { tool_use_id: "tu_1", path: ".env", regions: 1, requester: "agent", surface: "nvim" },
    RecordingFailed: { error_class: "IOError", message: "closed" },
    RequestSent: { digest: d, payload: { "messages" => [{ "role" => "user", "content" => "hi" }] }, stream: true,
                   extra: { "temperature" => 0.5 }, prefix_digests: [d], prefix_chain_version: 2,
                   requester: "summarizer" },
    ResendDispatched: { digest: d },
    RoundBounded: { head: d, basis: "tokens", budget: 100, delivered: ["tu_1"], deduplicated: [], withheld: ["tu_2"] },
    RunAllowance: { iterations: 103 },
    RunArms: { arms: { "confine" => "reader", "judge" => true } },
    RunInterrupted: { head: d, reason: :quota, status: 130, detail: "quota exceeded",
                      reset_at: "2026-11-01T18:00:00Z" },
    Salvaged: { request_digest: d, head_before: d, head_after: d },
    Sandbox: { tool_use_id: "tu_1", profile: :reader, trace: false, refused: [], created_sealed: ["/r/.git/x"],
               kept_tmpdir: "/t", granted: ["/g"] },
    SeamDecision: { size: "S", estimated_turns: 3, calibrated: true, bytes_removed: 10, bytes_after: 5,
                    rewrite_cost: BigDecimal("0.1"), payback: BigDecimal("0.2"), verdict: :defer },
    SearchRedacted: { tool_use_id: "tu_1", path: ".env", regions: 2, released: 1 },
    SessionClosed: { head: d, reason: :crashed, error: "RuntimeError" },
    SessionPin: { digest: d, pinned: true },
    SessionRead: { path: "lib/a.rb", lines: [1, 10],
                   identity: { "device" => 1, "inode" => 2, "mtime" => 3, "size" => 4 }, tool_use_id: "tu_1", head: d },
    SessionReadWithheld: { rounds: [[d, "tu_1"]] },
    SessionShared: { url: "https://gist.github.com/u/abc", format: :html, masked: 3 },
    ShellArm: { tool_use_id: "tu_1", verdict: :allow, arm: :term, reason: "literal",
                term: Lain::Shell::Term.of(%w[ls -la]) },
    SourceMasked: { tool_use_id: "tu_1", kind: :file, key: ".env", regions: 2, released: 1 },
    StreamStarted: { digest: d },
    SupersessionRecord: { supersession_digest: d, step_id: "s1", superseded_digest: d, superseding_digest: d,
                          plan_digest: d },
    TestLayoutAbsent: { root: "/r" },
    TestLayoutDeferred: { tool_use_id: "tu_1", tool: "write_file", path: "spec/a_spec.rb", reason: "later" },
    TestLayoutRefused: { tool_use_id: "tu_1", tool: "write_file", path: "spec/a_spec.rb", rule: :stray,
                         expected: "spec/lain/a_spec.rb", reason: "stray" },
    TestsRan: { issue_id: "i1", sha: "abc", ran: true, passed: 3, failed: 1, errors: 2 },
    ToolCalled: { tool_use_id: "tu_1", tool: "bash", summary: "ls", phase: "end", outcome: "ok", seconds: 0.5 },
    ToolCancelled: { head: d, cancelled: %w[tu_2 tu_3], running: %w[tu_2], never_ran: %w[tu_3], completed: %w[tu_1] },
    ToolOutput: { tool_use_id: "tu_1", stream: :stdout, bytes: "out\n" },
    Tripwire: { requester: "dev-1", signal: "refused_exec", weight: "high", score: 5, stop: "would_stop",
                evidence: [{ "signal" => "refused_exec" }] },
    TripwireStop: { requester: "dev-1", signal: "refused_exec", outcome: "stopped", unseeded: ["x"] },
    TruncatedStream: { kind: :unterminated, request_digest: d, frames: 3, accumulated_bytes: 100, tool_calls: 1,
                       model: "m" },
    TurnLabeled: { digest: d, label: "start" },
    TurnUsage: { digest: d, model: "m", stop_reason: :end_turn, usage: { "input_tokens" => 10 }, spawn: d },
    Verdict: { digest: d, survived: true, score: 0.5, why: "held", scale: "0-1", refuter: "r" },
    WindowPressure: { kind: :over_window, source: "ollama", request_digest: d, prompt_tokens: 9000,
                      window_tokens: 8192, stands_on: d, model: "m", spawn: d },
    WorktreeReap: { action: :reaped, subject: :worktree, name: "w-1", reason: "stale", anchors: ["refs/lain/anchor"] },
    WriteRefused: { tool_use_id: "tu_1", pattern: "aws key" }
  }.freeze
  population = arguments.to_h do |name, keywords|
    build = lambda do
      described_class.const_get(name.to_s).new(**keywords)
    rescue StandardError => e
      raise e.class, "#{name}: #{e.message}"
    end
    [name, build]
  end

  render = lambda do |record|
    io = StringIO.new
    Lain::Journal.new(io:, chain: Lain::Journal::Line::ORIGIN).record(record)
    io.string
  end
  parse = ->(line) { described_class.read(Lain::Journal.parse(line)) }

  include_examples "a round trip", render:, parse:, population: -> { population.values.map(&:call) }

  # Journalable records with no carrier: each reads back whole, as Untyped.
  unclaimed = %i[Escalation QuestionAnswered QuestionsConsumed RequestResent SlotFills TodoSnapshot].freeze
  journalable = lambda do
    ObjectSpace.each_object(Class).select do |klass|
      klass.name&.start_with?("Lain::Telemetry::") && klass.include?(described_class::Journalable) &&
        klass.name.safe_constantize.equal?(klass)
    end
  end

  it "draws one instance of every journaled record under Telemetry, counted by a walk of its own" do
    found = journalable.call.map { |klass| klass.name.delete_prefix("Lain::Telemetry::").to_sym }

    expect(population.keys).to match_array(found - unclaimed)
  end

  it "reads each record with no carrier back whole" do
    types = unclaimed.map { |name| described_class.const_get(name).allocate.journal_type }

    expect(types.map { |type| described_class.read({ "type" => type }) }).to all(be_a(described_class::Untyped))
  end

  it "declares in each carrier every member its record journals" do
    undeclared = population.keys.to_h do |name|
      klass = described_class.const_get(name.to_s)
      declared = described_class::Carriers.const_get(klass.allocate.journal_type.camelize).attribute_names
      [name, klass.members - declared.map(&:to_sym)]
    end

    # A carrier attribute named `errors` would replace ActiveModel's own, so that one count is cast by hand.
    expect(undeclared.reject { |_, members| members.empty? }).to eq(TestsRan: [:errors])
  end

  it "reads a ShellArm's term back through the class's own from_journal" do
    record = population.fetch(:ShellArm).call

    expect(parse.call(render.call(record)).term).to eq(record.term)
  end

  describe AlgebraLaws::RoundTrip do
    it "reads the law as failing, without raising, for a render that drops a field" do
      lossy = lambda do |record|
        io = StringIO.new
        Lain::Journal.new(io:).record(record.to_journal.except("seconds"))
        io.string
      end
      lenient = ->(line) { Lain::Telemetry.read(Lain::Journal.parse(line), strict: false) }
      battery = described_class.from(render: lossy, parse: lenient, population: -> { [population[:AskSettled].call] })

      expect(AlgebraLaws.outcomes(battery).values).to eq([:fails])
    end
  end
end
