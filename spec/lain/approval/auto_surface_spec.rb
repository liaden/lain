# frozen_string_literal: true

require "async"
require "fileutils"
require "stringio"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module AutoSurfaceSpecSupport
  # The minimal effect a {Approval::Queue::Pending} reads: a name, an input, and
  # the tool_use_id the park's journal record correlates on.
  Effect = Struct.new(:name, :input, :tool_use_id)

  # A {Skill::RoleSpawn} stand-in: records every spawn and answers each prompt
  # through the injected block, returning a {Tool::Result}. Injecting the seam
  # (rather than assembling a real RoleSpawn's provider/context/toolset set)
  # keeps the surface's contract -- observe, ask a role, route the verdict --
  # the thing under test.
  class ScriptedRoleSpawn
    attr_reader :calls

    def initialize(&answer)
      @answer = answer
      @calls = []
    end

    def call(role, context_mode, prompt)
      @calls << { role:, context_mode:, prompt: }
      @answer.call(prompt)
    end
  end
end

RSpec.describe Lain::Approval::AutoSurface do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def effect(name = "bash", input = { "command" => "ls" }, tool_use_id = "tu_#{name}")
    AutoSurfaceSpecSupport::Effect.new(name, input, tool_use_id)
  end

  def decisions
    Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a
  end

  # Drive one gated call through the surface and return the pending's FINAL
  # surface. Captured after the gated call resolves: a confident verdict has
  # already settled it; a defer leaves it for the clock, whose denial lands here.
  def surface_after(spawn)
    queue = Lain::Approval::Queue.new(journal:, timeout: 0.05)
    Sync do |task|
      gated = task.async { queue.call(effect, nil) }
      pending = task.with_timeout(1) { queue.dequeue }
      described_class.new(role_spawn: spawn).sweep(queue)
      gated.wait
      pending.surface
    ensure
      gated&.stop
    end
  end

  describe "the verdict parse (deny-when-unsure doctrine)" do
    def verdict_for(answer)
      surface_after(AutoSurfaceSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.ok(answer) })
    end

    it "approves only on a lone approve token, with an optional trailing period" do
      ["APPROVE", "approve", "  Approve.  "].each do |answer|
        expect(verdict_for(answer)).to eq("auto_approver")
        expect(decisions.last["verdict"]).to eq("approve")
      end
    end

    it "denies on a lone deny token, attributed to the auto surface" do
      ["DENY", "Deny."].each do |answer|
        expect(verdict_for(answer)).to eq("auto_approver")
        expect(decisions.last["verdict"]).to eq("deny")
      end
    end

    it "defers on defer, gibberish, empty, a hedged answer, or any trailing prose" do
      # The template contract is ONE word: the whole stripped answer must be a
      # verdict token. Anything else -- hedging, prose after the word -- is
      # defer, so the pending falls to the timeout, never signed auto_approver.
      ["DEFER", "defer.", "I am not sure what to do here", "", "  ",
       "approve the read but deny the write", # hedged: two verdicts, one answer
       "APPROVE. This command is safe to run.", # a confident word, then prose
       "approve please"].each do |answer|
        expect(verdict_for(answer)).to eq(Lain::Approval::Queue::TIMEOUT_SURFACE)
      end
    end

    it "never signs an error result -- even one whose content reads deny or approve" do
      # Fix #1: BOTH branches gate on ok?. An error Result is never the auto
      # surface's decision, whatever its content leads with.
      ["deny", "approve", "spawn failed"].each do |content|
        spawn = AutoSurfaceSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.error(content) }
        expect(surface_after(spawn)).to eq(Lain::Approval::Queue::TIMEOUT_SURFACE)
      end
    end
  end

  it "carries the effect's tool name and input into the spawned prompt" do
    spawn = AutoSurfaceSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.ok("DEFER") }
    queue = Lain::Approval::Queue.new(journal:, timeout: 0.05)
    Sync do |task|
      gated = task.async { queue.call(effect("edit_file", { "path" => "/etc/passwd" }), nil) }
      task.with_timeout(1) { queue.dequeue }
      described_class.new(role_spawn: spawn).sweep(queue)
      gated.wait
    end

    prompt = spawn.calls.first[:prompt]
    expect(spawn.calls.first).to include(role: :auto_approver, context_mode: :fresh)
    expect(prompt).to include("edit_file").and include("/etc/passwd")
  end

  # AC1
  it "attributes an approval to the auto surface while the human surface still sees the arrival" do
    spawn = AutoSurfaceSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.ok("APPROVE") }
    queue = Lain::Approval::Queue.new(journal:, timeout: 5)

    approved, arrival = Sync do |task|
      gated = task.async { queue.call(effect, nil) }
      # The human surface draws the arrival first -- but does not decide.
      human_arrival = task.with_timeout(1) { queue.dequeue }
      described_class.new(role_spawn: spawn).sweep(queue)
      [gated.wait, human_arrival]
    end

    expect(approved).to be(true)
    expect(arrival.tool).to eq("bash")
    expect(decisions.map { |d| d.values_at("surface", "verdict") })
      .to eq([%w[auto_approver approve]])
  end

  # AC2
  it "leaves the human in charge on defer and on an unparseable answer, both denied by the clock" do
    spawn = AutoSurfaceSpecSupport::ScriptedRoleSpawn.new do |prompt|
      Lain::Tool::Result.ok(prompt.include?("gated_a") ? "DEFER" : "what even is this")
    end
    queue = Lain::Approval::Queue.new(journal:, timeout: 0.05)

    Sync do |task|
      a = task.async { queue.call(effect("gated_a", {}), nil) }
      b = task.async { queue.call(effect("gated_b", {}), nil) }
      task.with_timeout(1) { [queue.dequeue, queue.dequeue] }
      described_class.new(role_spawn: spawn).sweep(queue)
      a.wait
      b.wait
    end

    expect(decisions.map { |d| d.values_at("tool", "surface", "verdict", "timed_out") })
      .to contain_exactly(
        ["gated_a", Lain::Approval::Queue::TIMEOUT_SURFACE, "deny", true],
        ["gated_b", Lain::Approval::Queue::TIMEOUT_SURFACE, "deny", true]
      )
  end

  # AC3
  it "loses the race safely: a human decision that lands during the spawn stands, with no second journal write" do
    queue = Lain::Approval::Queue.new(journal:, timeout: 5)

    Sync do |task|
      gated = task.async { queue.call(effect, nil) }
      pending = task.with_timeout(1) { queue.dequeue }
      # The human decides WHILE the auto surface is mid-spawn: sweep collects
      # the still-undecided pending, asks the role, and the human's answer lands
      # during that call -- so the auto surface's approve is a first-answer-wins
      # no-op. (A plain `task.async { decide }` would run eagerly to its first
      # yield -- and decide never yields -- settling before sweep even looked.)
      spawn = AutoSurfaceSpecSupport::ScriptedRoleSpawn.new do
        pending.decide(true, surface: "tty")
        Lain::Tool::Result.ok("APPROVE")
      end
      described_class.new(role_spawn: spawn).sweep(queue)
      gated.wait
      # The auto surface DID answer, afterwards -- and lost.
      expect(spawn.calls.size).to eq(1)
    end

    expect(decisions.map { |d| d.values_at("surface", "verdict") })
      .to eq([%w[tty approve]])
  end

  it "adjudicates each pending once -- a deferred pending is not re-spawned on the next sweep" do
    spawn = AutoSurfaceSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.ok("DEFER") }
    queue = Lain::Approval::Queue.new(journal:, timeout: 0.05)

    Sync do |task|
      gated = task.async { queue.call(effect, nil) }
      task.with_timeout(1) { queue.dequeue }
      surface = described_class.new(role_spawn: spawn)
      surface.sweep(queue)
      surface.sweep(queue)
      gated.wait
    end

    expect(spawn.calls.size).to eq(1)
  end

  # AC2 (seen-set growth): sweep delegates eviction to the injected pruning
  # seam every pass, over the SAME @adjudicated hash it just grew -- the
  # release itself is {Pruning}'s own spec (pruning_spec.rb); this pins only
  # that AutoSurface actually calls the seam it was handed, each sweep.
  it "prunes the seen-set through the injected pruning seam, once per sweep" do
    spawn = AutoSurfaceSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.ok("DEFER") }
    queue = Lain::Approval::Queue.new(journal:, timeout: 0.05)
    pruning = instance_double(Lain::Approval::QueueSurface::Pruning)
    allow(pruning).to receive(:call)

    Sync do |task|
      gated = task.async { queue.call(effect, nil) }
      task.with_timeout(1) { queue.dequeue }
      surface = described_class.new(role_spawn: spawn, pruning:)
      surface.sweep(queue)
      surface.sweep(queue)
      gated.wait
    end

    expect(pruning).to have_received(:call).twice
  end

  # Fix #3: a pending decided by a sibling surface DURING a sweep (after the
  # parked snapshot was collected, before its turn to adjudicate) skips the
  # wasted spawn -- the `decided?` guard at the top of adjudicate.
  it "skips the spawn for a pending a sibling surface decided mid-sweep" do
    queue = Lain::Approval::Queue.new(journal:, timeout: 0.05)

    Sync do |task|
      a = task.async { queue.call(effect("tool_a", {}), nil) }
      b = task.async { queue.call(effect("tool_b", {}), nil) }
      # Parked order is admit order [tool_a, tool_b], so tool_a adjudicates
      # first; keyed by prompt, not by that order, to keep the intent explicit.
      pendings = task.with_timeout(1) { [queue.dequeue, queue.dequeue] }
      tool_b = pendings.find { |pending| pending.tool == "tool_b" }
      spawn = AutoSurfaceSpecSupport::ScriptedRoleSpawn.new do |prompt|
        # While adjudicating tool_a, a human surface decides tool_b.
        tool_b.decide(false, surface: "tty") if prompt.include?("tool_a")
        Lain::Tool::Result.ok("DEFER")
      end
      described_class.new(role_spawn: spawn).sweep(queue)
      a.wait
      b.wait
      expect(spawn.calls.map { |call| call[:prompt] }.grep(/tool_b/)).to be_empty
      expect(spawn.calls.size).to eq(1)
    end
  end

  # T17 ruling. This surface prunes ORDINARY approvals: its role catalog and
  # its one-word prompt were built for those, and neither is told that a file's
  # sensitive regions are what a yes would release. So an approve on a
  # region-carrying pending would release secrets with NO human in the loop at
  # all, on a judgement that was never asked the question --
  # {Approval::SecretSurface} is the surface that is. The abstention is
  # structural, not a threshold that happened to fall, and these examples say so
  # by pinning that the role is never spawned at all.
  describe "a pending carrying outstanding sensitive regions" do
    let(:regions) { Lain::Sensitivity::Regions.detect("API_KEY=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n") }
    let(:outstanding) { Lain::Approval::Queue::Outstanding.new(path: "/repo/.env", regions:) }

    let(:spawn) { AutoSurfaceSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.ok("APPROVE") } }

    def sweep_over(outstanding)
      queue = Lain::Approval::Queue.new(journal:, timeout: 0.05)
      Sync do |task|
        gated = task.async { queue.adjudicate(effect, nil, outstanding:) }
        task.with_timeout(1) { queue.dequeue }
        described_class.new(role_spawn: spawn).sweep(queue)
        task.with_timeout(2) { gated.wait }
      ensure
        gated&.stop
      end
    end

    it "never asks its role about one, so no auto approval can release a secret" do
      settled = sweep_over(outstanding)

      expect(spawn.calls).to be_empty
      expect(settled.surface).to eq(Lain::Approval::Queue::TIMEOUT_SURFACE)
    end

    it "still adjudicates a pending carrying none, so the abstention is narrow" do
      settled = sweep_over(Lain::Approval::Queue::Outstanding::NONE)

      expect(spawn.calls.size).to eq(1)
      expect(settled.surface).to eq(described_class::SURFACE)
    end
  end

  # T13/F63. What this surface will and will not judge, over a `bash` argv --
  # pinned from both sides, because the two halves mean nothing apart.
  #
  # {#judges?} asks about a pending's outstanding sensitive REGIONS, and regions
  # are a `read_file`/{Middleware::RedactSecretReads} concept: a gated `bash`
  # carries {Queue::Outstanding::NONE} whatever its argv names. So this surface's
  # own filter answers TRUE for a command reading an ssh key and WOULD approve
  # it -- the region partition was never meant to cover an argv, and does not.
  # Nothing about the tool NAME is consulted anywhere on the path from
  # {#judges?} through {QueueSurface#mine?}.
  #
  # What stands between the two is ORDER, and only for one spelling.
  # {Approval::Escalation.for} puts {Escalation::Triage} ahead of
  # {Escalation::Surfaces}, so where the rung denies, nothing ever parks and
  # this surface has no pending to see. That is the first example.
  #
  # == The rung's reach is NARROW, and under --auto-approve that is a hole
  #
  # {Triage#literal} -- the only branch that reads an argv at all -- runs solely
  # on {Shell::Verdict}'s ALLOW, because `term` is `NO_TERM` on a deny and on
  # every abstention. {Shell::Verdict} abstains on quotes and escapes
  # ({Verdict::ESCAPING}), on a tilde or a glob ({Verdict::EXPANDING}), on `$`
  # expansion, and on `;`/`&&`/`||`/`&`. So the deny needs the WHOLE command to
  # be literal AND the path written with a separator, and everything else
  # abstains without ever looking at the path.
  #
  # {Triage}'s own docstring prices that abstention as safe -- "the call still
  # reaches a human because Triage downgrades every allow anyway". THAT PRICE IS
  # WRONG UNDER `--auto-approve`: the abstention reaches THIS surface, whose
  # one-word prompt is never told a protected path is in the argv, and whose
  # 50ms poll beats any human racing it on the same queue. The examples below
  # pin that as it stands, one per spelling. They are `OPEN:` rather than
  # aspirational on this card's own rule -- record what the code does, do not
  # assert a hypothesis it refutes. Closing it belongs to a later card, beside
  # the `/mode auto` hole in the plan doc's Open decisions.
  #
  # The `&&` example is the sharpest of them: the path there is bare, unquoted
  # and absolute -- the exact spelling the first example denies -- and it is
  # approved anyway, because a SECOND command elsewhere in the string cost the
  # rung its allow. The hole is not about how the path is spelled.
  describe "a bash argv naming a path no approval may lift" do
    let(:spawn) { AutoSurfaceSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.ok("APPROVE") } }
    let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
    # A REAL Toolset, on board_build_spec's terms: the ladder's rungs read the
    # tier off the live capability set, so a call that is not gated at all never
    # reaches a rung and every example here would pass vacuously.
    let(:toolset) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }

    def in_tree
      Dir.mktmpdir("lain-auto-surface") do |dir|
        base = File.realpath(dir)
        root = File.join(base, "repo")
        FileUtils.mkdir_p(File.join(root, ".lain"))
        yield(root, File.join(base, "home"))
      end
    end

    def project_at(root) = Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag)

    def paths_at(home) = Lain::Paths.new(env: { "HOME" => home })

    # The real construction path, nothing injected: {CLI::Wiring::BoardBuild} is
    # what hands the triage rung a classifier at all.
    #
    # `--auto-approve` is deliberately NOT in `options:`, because the board does
    # not read it -- {Switchboard.for} reads `:non_interactive` and nothing
    # else, and the flag is wired one module over at
    # {Wiring::ToolsetBuild#build}. Passing it here would read as the variable
    # under test while changing nothing. The live {AutoSurface} watching
    # `board.approvals` below IS `--auto-approve`, faithfully: it is the same
    # object {Repl::ApprovalSurfaces#watch} spawns when the flag is set.
    def armed_board(root, home)
      Lain::CLI::Wiring::BoardBuild.for(chronicle:, options: {}, model: "m", toolset:,
                                        project: project_at(root), paths: paths_at(home))
    end

    # The SAME board with `classifiers:` -- and only `classifiers:` -- dropped,
    # so the contrast discriminates one variable rather than three.
    # {BoardBuild.for} is a thin adapter that compiles the `[sensitivity]` table
    # once, derives `rules:`/`sensitivity:`/`classifiers:` from it and delegates
    # to {Switchboard.for}; this composes the first two exactly as it does and
    # lets the third default to {Triage::AnyPath}, which protects nothing and is
    # what every board had before F63 was wired. Same entry point, one layer
    # down, one argument changed.
    def disarmed_board(root, home)
      project = project_at(root)
      table = Lain::CLI::Wiring::BoardBuild.rules(project:)
      Lain::CLI::Switchboard.for(chronicle:, options: {}, model: "m", toolset:,
                                 rules: Lain::Project::Consent.for(project:).rules,
                                 sensitivity: Lain::CLI::Wiring::BoardBuild.policy(project:, paths: paths_at(home),
                                                                                   table:))
    end

    def key_under(home) = File.join(home, ".ssh", "id_rsa")

    def bash_of(command)
      Lain::Effect::ToolCall.new(tool_use_id: "tu_bash", name: "bash", input: { "command" => command })
    end

    def rulings = Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a

    def rungs = rulings.map { |ruling| ruling.values_at("rung", "verdict") }

    def signatures = decisions.map { |decision| decision.values_at("surface", "verdict") }

    # Watching the way {Repl::ApprovalSurfaces} does -- a fiber over the live
    # queue -- rather than a direct `sweep`, because the assertion is that this
    # surface never gets a pending, and a hand-driven sweep could only say that
    # about the moment it was called.
    def while_watching(board, &block)
      surface = described_class.new(role_spawn: spawn, poll_interval: 0.005)
      Sync do |task|
        watcher = task.async { surface.watch(board.approvals) }
        task.with_timeout(2, &block)
      ensure
        watcher&.stop
      end
    end

    # The one spelling the rung actually reaches: every word literal, the path
    # written with separators.
    def answered_for(board, command)
      while_watching(board) do
        answer = board.policy_switch.call(bash_of(command), nil)
        # Many polls at 5ms: the surface had every chance to see a pending.
        Async::Task.current.sleep(0.05)
        answer
      end
    end

    it "is denied at triage, so nothing parks and the auto-approver is never asked" do
      in_tree do |root, home|
        board = armed_board(root, home)
        allowed = answered_for(board, "cat #{key_under(home)}")

        expect(allowed).to be(false)
        expect(spawn.calls).to be_empty
        expect(board.approvals.count).to eq(0)
        expect(rulings.map { |ruling| ruling.values_at("rung", "verdict", "faulted") })
          .to eq([["triage", "deny", false]])
      end
    end

    it "reaches this surface and is APPROVED when the triage rung is the inert AnyPath" do
      in_tree do |root, home|
        board = disarmed_board(root, home)
        allowed = answered_for(board, "cat #{key_under(home)}")

        expect(allowed).to be(true)
        expect(spawn.calls.size).to eq(1)
        expect(signatures).to eq([%w[auto_approver approve]])
      end
    end

    # One example per spelling rather than a loop inside one, so a later card
    # that closes ONE of these turns exactly one example red and names it.
    {
      "a double-quoted path" => ->(key) { %(cat "#{key}") },
      "a single-quoted path" => ->(key) { "cat '#{key}'" },
      "a tilde" => ->(_key) { "cat ~/.ssh/id_rsa" },
      "a $HOME expansion" => ->(_key) { "cat $HOME/.ssh/id_rsa" },
      "a bare path beside a second command" => ->(key) { "cat #{key} && echo hi" }
    }.each do |spelling, command|
      it "OPEN: #{spelling} abstains at triage, reaches this surface, and is approved with no human" do
        in_tree do |root, home|
          board = armed_board(root, home)
          allowed = answered_for(board, command.call(key_under(home)))

          expect(allowed).to be(true)
          expect(spawn.calls.size).to eq(1)
          expect(rungs).to eq([%w[triage abstain], %w[rules abstain], %w[surfaces allow]])
          expect(signatures).to eq([%w[auto_approver approve]])
        end
      end
    end
  end

  # T11 gated subagents, which put this surface one step from a stall that
  # would corrupt its own record. {#sweep} blocks INSIDE `@role_spawn.call`:
  # one fiber, sequential. So if the adjudicating child ever parked on a gated
  # call, it would park on the SAME queue this surface is sweeping -- and the
  # only surface that could answer it is the one waiting for it. Not permanent
  # (the fail-closed clock breaks it) but it stalls for
  # {Approval::Queue::DEFAULT_TIMEOUT} = 300s, and the pending is then denied
  # BY THE CLOCK rather than judged, which is a lie in the transcript: the
  # record would read `timeout` for a call an adjudicator was mid-way through
  # answering.
  #
  # The only thing preventing it is that {ROLE}'s catalog set is read-only, so
  # it is pinned HERE, beside the constant, rather than only in the subagent
  # spec: a reader who changes `ROLE` -- or widens `auto_approver`'s tools --
  # will not go looking in spec/lain/tools for the reason they must not.
  describe "the role it adjudicates as" do
    it "holds no tier-3 tool, so a gated child can never park on the queue this surface sweeps" do
      tools = Lain::Role::Catalog[described_class::ROLE].only.map { |name| ToolRegistry.build(name.to_s) }

      expect(tools.select(&:requires_approval?)).to be_empty
    end
  end
end
