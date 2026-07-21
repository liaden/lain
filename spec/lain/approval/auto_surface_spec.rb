# frozen_string_literal: true

require "async"
require "stringio"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module AutoSurfaceSpecSupport
  # The minimal effect a {Approval::Queue::Pending} reads: a name and an input.
  Effect = Struct.new(:name, :input)

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

  def effect(name = "bash", input = { "command" => "ls" })
    AutoSurfaceSpecSupport::Effect.new(name, input)
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
end
