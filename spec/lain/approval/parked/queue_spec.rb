# frozen_string_literal: true

require "json"
require "stringio"

# Kept out of the RSpec block (Lint/ConstantDefinitionInBlock), the same shape
# queue_concurrency_spec's fixture uses.
module ApprovalSpecSupport
  # A Journal that fails for ONE entry class and forwards everything else -- a
  # full disk, an EPIPE, a Journal closed under a still-running turn. The queue
  # writes evidence on both the pre-park and the settle path, and neither may
  # cost the turn it describes: Gate sits ABOVE Handler::Live, so an exception
  # from either write unwinds through the agent loop with nothing left to turn
  # it into a Tool::Result.
  class BrittleJournal
    def initialize(journal, fails_on:)
      @journal = journal
      @fails_on = fails_on
    end

    def record(entry)
      raise IOError, "no space left on device" if entry.is_a?(@fails_on)

      @journal.record(entry)
    end
  end
end

# The approval queue behind Middleware::Gate: a gated tool call enqueues a
# Pending approval and parks its fiber on Gate's synchronous policy seam; a
# surface fiber answers, first answer wins, every decision journals, and an
# unanswered window denies (the fail-closed doctrine gate.rb pins).
RSpec.describe Lain::Approval::Parked::Queue do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:queue) { described_class.new(journal:) }

  def tool_call(name = "dangerous", input = { "text" => "boom" })
    Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)
  end

  def decision_records
    journal_records(journal_io, "approval_decision")
  end

  def pending_records
    journal_records(journal_io, "awaiting_human")
  end

  # The approval records in the order they were written, so "announced before
  # decided" is read off the journal itself rather than inferred.
  def approval_types
    approval = %w[awaiting_human approval_decision]
    Lain::Journal.records(journal_io.string.lines)
                 .map { |record| record["type"] }
                 .select { |type| approval.include?(type) }
                 .to_a
  end

  def error_records
    journal_records(journal_io, "journal_error")
  end

  # The same tool-builder shape gate_spec uses: a tier-3 tool is one that
  # answers requires_approval? true about itself.
  def gated_tool(runs)
    Class.new(Lain::Tool) do
      def name = "dangerous"
      def description = "the dangerous tool"
      def requires_approval? = true
      def input_schema = { type: :object, properties: { text: { type: :string } }, required: [] }
      define_method(:perform) do |input, _invocation|
        runs << input
        Lain::Tool::Result.ok(input.fetch("text", "ran"))
      end
    end.new
  end

  # The ask ladder over the queue, in front of the one gated tool, driven the
  # way a turn drives a call: through the runner, into a real Live.
  def gate_over(runs)
    toolset = Lain::Toolset.new([gated_tool(runs)])
    gate = Lain::Middleware::Gate.new(policy: asking_ladder(queue))
    ->(effect) { dispatch_call(effect.name, effect.input, id: effect.tool_use_id, toolset:, layers: [gate]) }
  end

  describe "a gated call parks on the queue" do
    it "enqueues, parks the calling fiber, and an approval resolves it into the tool run" do
      runs = []
      gate = gate_over(runs)

      Sync do |task|
        run = task.async { gate.call(tool_call("dangerous", { "text" => "went through" })) }

        # The gated fiber ran up to its await: the effect is enqueued, parked,
        # and the tool has NOT run.
        expect(queue.count).to eq(1)
        expect(runs).to be_empty

        pending = queue.dequeue
        expect(pending).to have_attributes(requester: "agent", tool: "dangerous")

        pending.approve(surface: "spec")
        expect(run.wait).to eq(Lain::Tool::Result.ok("went through"))
      end

      expect(runs.length).to eq(1)
    end

    # A surface judging the parked call's path must land it where the gate did.
    it "records the cwd of the session the call was made in" do
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "/srv/worker", env: {}))

      Sync do |task|
        task.async { queue.call(tool_call, session) }
        pending = queue.dequeue
        expect(pending.cwd).to eq("/srv/worker")
        pending.deny(surface: "spec")
      end
    end

    # A checkout may mirror a subdirectory, so where directory names start
    # counting is the checkout and not the cwd below it.
    it "records the session's checkout as the base, and its cwd when it has none" do
      leased = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "/w/co/sub", env: {}, checkout: "/w/co"))
      plain = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "/srv/worker", env: {}))

      within = [leased, plain].map do |session|
        Sync do |task|
          task.async { queue.call(tool_call, session) }
          pending = queue.dequeue
          pending.deny(surface: "spec")
          pending.respond_to?(:within) ? pending.within : nil
        end
      end

      expect(within).to eq(["/w/co", "/srv/worker"])
    end

    it "parks the fiber, not the reactor: a sibling fiber proceeds while the call waits" do
      log = []
      gate = gate_over([])

      Sync do |task|
        run = task.async do
          log << :gated
          gate.call(tool_call)
          log << :resolved
        end
        task.async { log << :worker_ran }

        expect(log).to eq(%i[gated worker_ran])
        queue.dequeue.approve(surface: "spec")
        run.wait
        expect(log).to eq(%i[gated worker_ran resolved])
      end
    end

    it "returns the refusal Result on deny, and the tool never runs" do
      runs = []
      gate = gate_over(runs)

      Sync do |task|
        run = task.async { gate.call(tool_call) }
        queue.dequeue.deny(surface: "spec")

        result = run.wait
        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("denied")
      end

      expect(runs).to be_empty
    end

    # A refusal through the queue is never final: a surface answering no this
    # time could answer yes the next.
    it "rules through the asking rung with the surface's answer, never a final one" do
      asking = Lain::Approval::Escalation::Surfaces.new(queue)
      Sync do |task|
        denied = task.async { asking.call(tool_call, nil) }
        queue.dequeue.deny(surface: "tty", authority: :human)
        approved = task.async { asking.call(tool_call, nil) }
        queue.dequeue.approve(surface: "tty", authority: :human)

        expect(denied.wait).to have_attributes(verdict: :deny, authority: :human, final?: false)
        expect(approved.wait).to be_allow
      end
    end

    it "keeps a human's refusal in the gate's own sentence" do
      gate = gate_over([])

      Sync do |task|
        run = task.async { gate.call(tool_call) }
        queue.dequeue.deny(surface: "tty")

        expect(run.wait).to eq(Lain::Tool::Result.error('approval denied for tool "dangerous"'))
      end
    end

    it "tells the model the words a human denied the call in" do
      gate = gate_over([])

      Sync do |task|
        run = task.async { gate.call(tool_call) }
        queue.dequeue.deny(surface: "tty", reason: "stay inside ~/dev/frugirl")

        expect(run.wait.content).to eq('approval denied for tool "dangerous": stay inside ~/dev/frugirl')
      end
    end

    it "empties its pending list once the decision settles" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.approve(surface: "spec")
        run.wait
      end

      expect(queue.count).to eq(0)
    end
  end

  describe "how long a parked call has left" do
    def pending_at(now, timeout: 300)
      effect = tool_call
      described_class::Pending.new(effect:, identity: Lain::Requester.main, clock: -> { now.call }, timeout:)
    end

    it "counts the window from the park until a surface draws it" do
      now = 100.0
      pending = pending_at(-> { now })
      now = 160.0

      expect(pending.remaining).to eq(240.0)
      expect(pending.remaining_face).to eq("4:00")
    end

    it "restarts the window at the draw, as the queue's own timer does" do
      now = 100.0
      pending = pending_at(-> { now })
      now = 160.0
      pending.drawn
      now = 190.0

      expect(pending.remaining_face).to eq("4:30")
    end

    it "never reads below nothing" do
      now = 0.0
      pending = pending_at(-> { now })
      now = 999.0

      expect(pending.remaining).to eq(0)
      expect(pending.remaining_face).to eq("0:00")
    end

    it "names the wall-clock moment it fires, so a render that goes stale stays true" do
      now = 100.0
      wall = Time.new(2026, 10, 8, 13, 15, 0, "+00:00")
      effect = tool_call
      pending = described_class::Pending.new(effect:, identity: Lain::Requester.main, clock: -> { now }, timeout: 300,
                                             wall: -> { wall + (now - 100.0) })
      now = 160.0
      first = pending.fires_at_face
      now = 220.0

      expect(first).to eq("13:20:00")
      expect(pending.fires_at_face).to eq(first)
    end

    it "rounds a part second up, so the face never says a call is out of time while it is not" do
      expect(pending_at(-> { 0.0 }, timeout: 299.2).remaining_face).to eq("5:00")
    end

    it "names the whole window and the sentence a lapse is reported in" do
      pending = pending_at(-> { 0.0 }, timeout: 125)

      expect(pending.window_face).to eq("2:05")
      expect(pending.lapse).to eq("denied after 2:05 with no answer")
    end

    it "reads a clock denial as unanswered, with the lapse sentence as its closure" do
      lapsed = pending_at(-> { 0.0 }, timeout: 125)
      lapsed.deny(surface: described_class::TIMEOUT_SURFACE)

      expect(lapsed).to have_attributes(abandoned?: false, unanswered?: true,
                                        closure: "denied after 2:05 with no answer")
    end

    it "reads a stopped requester as unanswered, closed in its own words" do
      stopped = pending_at(-> { 0.0 }, timeout: 125)
      stopped.deny(surface: described_class::ABANDONED_SURFACE)

      expect(stopped).to have_attributes(abandoned?: true, unanswered?: true,
                                         closure: "closed: its requester was stopped")
    end

    it "reads a surface's decision as answered" do
      answered = pending_at(-> { 0.0 }, timeout: 125)
      answered.deny(surface: "tty")

      expect(answered).to have_attributes(abandoned?: false, unanswered?: false)
    end

    it "is given the queue's timeout by the queue that admits it" do
      timed = described_class.new(journal:, timeout: 90)
      seen = nil

      Sync do |task|
        run = task.async { timed.call(tool_call, nil) }
        seen = timed.dequeue.tap { |pending| pending.deny(surface: "tty") }
        run.wait
      end

      expect(seen.window_face).to eq("1:30")
    end
  end

  # Scenario: a surface's authority travels with its answer
  # Scenario: the queue no longer names the ladder
  describe "who decided a parked call" do
    def ruled(surface:, **answered)
      asking = Lain::Approval::Escalation::Surfaces.new(queue)
      Sync do |task|
        ruling = task.async { asking.call(tool_call, nil) }
        queue.dequeue.approve(surface:, **answered)
        ruling.wait
      end
    end

    it "names the authority each surface declared, not one read off its name" do
      machine = ruled(surface: "tty", authority: :automatic)
      person = ruled(surface: Lain::Approval::Parked::SecretSurface::SURFACE, authority: :human)

      expect([machine.authority, person.authority]).to eq(%i[automatic human])
    end

    it "counts a surface that declares nothing as automatic" do
      expect(ruled(surface: "tty")).not_to be_human
    end

    it "refuses an authority no ruling knows" do
      pending = described_class::Pending.new(effect: tool_call, identity: Lain::Requester.main, clock: -> { 0.0 })

      expect { pending.decide(Lain::Approval::Verdict::Approve.new, surface: "tty", authority: :person) }
        .to raise_error(ArgumentError, /person/)
      expect(pending).not_to be_decided
    end

    it "decides as automatic when the surface names no authority" do
      pending = described_class::Pending.new(effect: tool_call, identity: Lain::Requester.main, clock: -> { 0.0 })
      pending.decide(Lain::Approval::Verdict::Approve.new, surface: "tty")

      expect(pending.authority).to eq(:automatic)
    end

    it "references no Escalation constant in its own source" do
      source = File.read(described_class.instance_method(:adjudicate).source_location.first)

      expect(source.scan(/Escalation\S*/)).to be_empty
    end
  end

  describe "decisions are journaled evidence" do
    it "journals surface, verdict, and decision latency" do
      now = 100.0
      queue = described_class.new(journal:, requester: "the-agent", clock: -> { now })

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        now = 102.5
        queue.dequeue.approve(surface: "tty")
        expect(run.wait).to be(true)
      end

      expect(decision_records).to contain_exactly(
        a_hash_including("type" => "approval_decision", "requester" => "the-agent",
                         "tool" => "dangerous", "surface" => "tty", "verdict" => "approve",
                         "latency" => 2.5, "timed_out" => false)
      )
    end

    it "journals a denial under the same record type" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.deny(surface: "tty")
        expect(run.wait).to be(false)
      end

      expect(decision_records).to contain_exactly(a_hash_including("verdict" => "deny", "timed_out" => false))
      expect(decision_records.first).not_to have_key("reason")
    end

    it "journals the words a human denied the call in" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.deny(surface: "tty", reason: "stay inside ~/dev/frugirl")
        run.wait
      end

      expect(decision_records).to contain_exactly(a_hash_including("verdict" => "deny",
                                                                   "reason" => "stay inside ~/dev/frugirl"))
    end

    it "pairs the pending and the decision with the digest of the input approved, never the input" do
      call = tool_call("bash", { "command" => "rm -rf build" })

      Sync do |task|
        run = task.async { queue.call(call, nil) }
        queue.dequeue.approve(surface: "tty", authority: :human)
        run.wait
      end

      records = pending_records.to_a + decision_records.to_a
      expect(records.map { _1["input_digest"] }).to eq([Lain::Canonical.digest(call.input)] * 2)
      expect(records.map(&:to_json)).to all(satisfy { !_1.include?("rm -rf build") })
    end
  end

  describe "the words a denial is given in" do
    def pending = described_class::Pending.new(effect: tool_call, identity: Lain::Requester.main, clock: -> { 0.0 })

    it "keeps them on one line with no control bytes, so they stay one clause of the tool result" do
      denied = pending
      denied.deny(surface: "tty", reason: "stay\ninside\e[2K  ~/dev/frugirl\r")

      expect(denied.reason).to eq("stay inside [2K ~/dev/frugirl")
    end

    it "holds none for blank words or for an approval" do
      blank = pending
      blank.deny(surface: "tty", reason: "  \n")
      approved = pending
      approved.decide(Lain::Approval::Verdict::Approve.new(note: "fine"), surface: "tty")

      expect([blank.reason, approved.reason]).to eq([nil, nil])
    end
  end

  # Scenario: decide takes only a verdict
  describe "what decides a pending" do
    let(:verdict) { Lain::Approval::Verdict }

    def pending = described_class::Pending.new(effect: tool_call, identity: Lain::Requester.main, clock: -> { 0.0 })

    [true, false, "approve", :approve, nil].each do |answer|
      it "refuses #{answer.inspect}, and nothing is approved" do
        asked = pending

        expect { asked.decide(answer, surface: "tty") }.to raise_error(ArgumentError, /not a verdict/)
        expect(asked).not_to be_decided
      end
    end

    it "settles approve, hold and deny as approve, postpone and deny" do
      answers = [verdict::Approve.new, verdict::Hold.new(note: "after lunch"), verdict::Deny.new(note: "no")]

      expect(answers.map { |answer| pending.tap { _1.decide(answer, surface: "tty") }.decision })
        .to eq(%i[approve postpone deny])
    end

    it "keeps a hold's words as its reason, on one line, and approves nothing" do
      held = pending.tap { _1.decide(verdict::Hold.new(note: "after\nlunch"), surface: "tty", authority: :human) }

      expect(held).to have_attributes(reason: "after lunch", approved?: false, postponed?: true)
    end

    it "journals a hold as a postpone, with the words it was given" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.decide(verdict::Hold.new(note: "after lunch"), surface: "tty", authority: :human)
        expect(run.wait).to be(false)
      end

      expect(decision_records).to contain_exactly(a_hash_including("verdict" => "postpone", "reason" => "after lunch"))
    end
  end

  # Parking is itself evidence. Before this, the only observable moment in
  # an approval's life was the post-hoc decision, so nothing could render "a
  # call is waiting on you" -- the state a human is actually asked to act on.
  describe "parking announces itself" do
    it "journals an awaiting_human approval naming the requester and the tool" do
      queue = described_class.new(journal:, requester: "the-agent")

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.approve(surface: "tty")
        run.wait
      end

      expect(pending_records).to contain_exactly(
        a_hash_including("type" => "awaiting_human", "kind" => "approval", "requester" => "the-agent",
                         "tool" => "dangerous")
      )
    end

    it "names the child's spawn when the asking context carries one, and no spawn key otherwise" do
      queue = described_class.new(journal:)
      child = Lain::Approval::Parked::PolicySwitch::Requested.new(Lain::Session.new, "researcher",
                                                                  spawn: "blake3:child")

      Sync do |task|
        runs = [child, nil].map { |context| task.async { queue.call(tool_call, context) } }
        2.times { queue.dequeue.approve(surface: "tty") }
        runs.each(&:wait)
      end

      expect(pending_records.map { _1["spawn"] }).to eq(["blake3:child", nil])
      expect(pending_records.last).not_to have_key("spawn")
    end

    it "names the moment the queue denies the call unasked" do
      queue = described_class.new(journal:, timeout: 300, wall: -> { Time.utc(2026, 11, 2, 9, 0, 0) })

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.approve(surface: "tty")
        run.wait
      end

      expect(pending_records)
        .to contain_exactly(a_hash_including("ref" => "tu_1", "deadline" => "2026-11-02T09:05:00Z"))
    end

    it "announces the park BEFORE any decision is made" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        expect(approval_types).to eq(%w[awaiting_human])

        queue.dequeue.approve(surface: "tty")
        run.wait
      end

      expect(approval_types).to eq(%w[awaiting_human approval_decision])
    end

    it "leaves the decision record exactly as it was" do
      now = 100.0
      queue = described_class.new(journal:, requester: "the-agent", clock: -> { now })

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        now = 102.5
        queue.dequeue.approve(surface: "tty")
        run.wait
      end

      expect(decision_records).to contain_exactly(
        a_hash_including("type" => "approval_decision", "requester" => "the-agent",
                         "tool" => "dangerous", "surface" => "tty", "verdict" => "approve",
                         "latency" => 2.5, "timed_out" => false)
      )
    end

    # The correlation id the decision record does not carry. Without it the
    # announcement can only be counted, never matched to the call it belongs to
    # -- and a journal discriminator's fields get replayed against, so a
    # consumer built on a count-only contract turns adding the key later into a
    # format migration.
    it "names the tool_use_id of the exact call that parked" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.approve(surface: "tty")
        run.wait
      end

      expect(pending_records).to contain_exactly(a_hash_including("tool_use_id" => "tu_1", "tool" => "dangerous"))
    end

    # Parallel calls park together and are answered in whatever order a person
    # gets to them, so a reader counting parks against decisions pairs the
    # wrong ones. The id pairs them.
    it "pairs each decision with its own announcement by the call's id, whatever order they are decided in" do
      first = Lain::Effect::ToolCall.new(tool_use_id: "tu_first", name: "dangerous", input: {})
      second = Lain::Effect::ToolCall.new(tool_use_id: "tu_second", name: "dangerous", input: {})

      Sync do |task|
        runs = [first, second].map { |call| task.async { queue.call(call, nil) } }
        parked = [queue.dequeue, queue.dequeue]
        parked.last.deny(surface: "tty")
        parked.first.approve(surface: "tty")
        runs.each(&:wait)
      end

      expect(pending_records.map { |record| record.fetch("tool_use_id") }).to eq(%w[tu_first tu_second])
      expect(decision_records.to_h { |record| [record.fetch("tool_use_id"), record.fetch("verdict")] })
        .to eq("tu_second" => "deny", "tu_first" => "approve")
      expect(decision_records.map { |record| record.fetch("tool_use_id") }).to eq(%w[tu_second tu_first])
    end

    it "says on the announcement whether only a person may decide the call" do
      Sync do |task|
        barred = Lain::Middleware::WithholdAutomaticOutput::Carried.new(nil, barred: true)
        runs = [barred, nil].map { |context| task.async { queue.call(tool_call, context) } }
        2.times { queue.dequeue.deny(surface: "tty") }
        runs.each(&:wait)
      end

      expect(pending_records.map { |record| record.fetch("humans_only", false) }).to eq([true, false])
    end

    it "keeps the announcement when the requester is abandoned before deciding" do
      Sync do |task|
        task.async { queue.call(tool_call, nil) }.stop
      end

      expect(pending_records).to contain_exactly(a_hash_including("tool" => "dangerous"))
      expect(decision_records).to contain_exactly(a_hash_including("surface" => "abandoned", "verdict" => "deny"))
      expect(approval_types).to eq(%w[awaiting_human approval_decision])
    end
  end

  # Who is asking is a property of the CALL, not of the queue. ONE queue
  # serves the whole fleet -- the parent and every child park in it -- so a
  # queue-level constant journals and renders every pending identically, and in
  # QA a researcher subagent's `bash` approval was indistinguishable from the
  # human's own agent's until the spawn's `only`-set was read out of the
  # journal. `ask_human` has long named its actor; this is the same
  # identity one rail over.
  #
  # It rides the `context` the policy seam already threads untouched
  # ({Approval::Parked::PolicySwitch::Requested}), which is why nothing between a
  # child's gate and this queue had to widen its `call(effect, context)` duck.
  # That value's OWN behaviour -- its delegation, and the names it refuses --
  # is spec'd at its mirrored path, `spec/lain/approval/parked/policy_switch_spec.rb`;
  # what belongs here is what the QUEUE does with it.
  describe "who a parked call is asked on behalf of" do
    def asked_by(requester) = Lain::Approval::Parked::PolicySwitch::Requested.new(nil, requester)

    def parked(context)
      Sync do |task|
        run = task.async { queue.call(tool_call, context) }
        queue.dequeue.approve(surface: "spec")
        run.wait
      end
    end

    it "names the role a spawn announces as, on both halves of the record" do
      parked(asked_by("researcher"))

      expect(pending_records).to contain_exactly(a_hash_including("requester" => "researcher"))
      expect(decision_records).to contain_exactly(a_hash_including("requester" => "researcher"))
    end

    # The separation, in one session and one queue: a parent's own turn parks
    # against a context that names nobody, so it cannot be mistaken for the
    # child that parked a moment earlier.
    it "does not name the child when the parent's own turn parks in the same queue" do
      parked(asked_by("researcher"))
      parked(nil)

      expect(pending_records.map { |record| record.fetch("requester") }).to eq(%w[researcher agent])
    end

    it "keeps the key on the record and the label a surface shows on the pending" do
      child = Lain::Requester.new(name: "dev", role: "dev", skill: "gherkin-tests")
      Sync do |task|
        run = task.async { queue.call(tool_call, asked_by(child)) }
        @pending = queue.dequeue
        @pending.approve(surface: "spec")
        run.wait
      end

      expect([@pending.requester, @pending.label]).to eq(["dev", "dev (gherkin-tests)"])
      expect(@pending.identity).to eq(child)
      expect(pending_records).to contain_exactly(a_hash_including("requester" => "dev"))
    end

    it "resolves a context to the identity it carries, and to the fallback when it names nobody" do
      child = Lain::Requester.new(name: "dev", role: "dev", skill: "gherkin-tests")

      expect([described_class.identity_for(asked_by(child)), described_class.identity_for(nil)])
        .to eq([child, Lain::Requester.main])
    end

    it "labels a context that names nobody as the queue's own requester" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        @pending = queue.dequeue
        @pending.approve(surface: "spec")
        run.wait
      end

      expect(@pending.label).to eq("agent")
    end

    it "carries the queue's default requester when the context names nobody" do
      parked(nil)

      expect(pending_records).to contain_exactly(a_hash_including("requester" => "agent"))
    end
  end

  # A human's no on a path holds for whoever asked it, so the queue keeps what
  # it was told and a later call on that path can be refused without parking.
  describe "a human's deny on a path is remembered" do
    def lists(path) = tool_call("list_files", { "path" => path })

    def in_dir(cwd, requester: nil)
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd:, env: {}))
      requester ? Lain::Approval::Parked::PolicySwitch::Requested.new(session, requester) : session
    end

    def settled(effect, context = nil)
      Sync do |task|
        run = task.async { queue.adjudicate(effect, context) }
        yield queue.dequeue
        run.wait
      end
    end

    def denied_by_human(effect, context = nil, reason: "not your business")
      settled(effect, context) do |pending|
        yield pending if block_given?
        pending.deny(surface: "spec", authority: :human, reason:)
      end
    end

    it "answers the human's reason for the denied path and anything under it, for the same requester" do
      denied_by_human(lists("/home"), in_dir("/", requester: "researcher"))

      expect(%w[/home /home/joel /home/joel/a.md].map { |path| queue.denied(requester: "researcher", path:) })
        .to all(eq("not your business"))
    end

    it "does not treat a sibling name as under the denied path" do
      denied_by_human(lists("/home/jo"), in_dir("/", requester: "researcher"))

      expect(queue.denied(requester: "researcher", path: "/home/joel")).to be_nil
    end

    it "does not answer for another requester" do
      denied_by_human(lists("/home"), in_dir("/", requester: "researcher"))

      expect(queue.denied(requester: "agent", path: "/home")).to be_nil
    end

    it "keys a context that names nobody under the main agent" do
      denied_by_human(lists("/home"))

      expect(queue.denied(requester: described_class::REQUESTER.name, path: "/home")).to eq("not your business")
    end

    it "holds a denial for a requester that asks again under a role, keyed by its name" do
      denied_by_human(lists("/home"), in_dir("/", requester: "researcher"))
      again = Lain::Requester.new(name: "researcher", role: "researcher", skill: "gherkin-tests")
      context = in_dir("/", requester: again)

      expect(queue.denied(requester: described_class.identity_for(context).name, path: "/home"))
        .to eq("not your business")
    end

    it "journals a requester with a role under its name, a String" do
      denied_by_human(lists("/home"), in_dir("/", requester: Lain::Requester.new(name: "dev-2", role: "dev")))

      expect(decision_records).to contain_exactly(a_hash_including("requester" => "dev-2"))
    end

    it "resolves a relative path against the call's own cwd, cleaned" do
      denied_by_human(lists("../secret/./x"), in_dir("/srv/project"))

      expect(queue.denied(requester: "agent", path: "/srv/secret/x")).to eq("not your business")
    end

    it "reads ~ as the home it was built with" do
      homed = described_class.new(journal:, home: "/home/u")
      Sync do |task|
        run = task.async { homed.adjudicate(lists("~/notes"), in_dir("/srv/p")) }
        homed.dequeue.deny(surface: "spec", authority: :human, reason: "mine")
        run.wait
      end

      expect(homed.denied(requester: "agent", path: "/home/u/notes")).to eq("mine")
    end

    it "remembers a deny given no words as an empty reason, still a String" do
      denied_by_human(lists("/home"), reason: nil)

      expect(queue.denied(requester: "agent", path: "/home")).to eq("")
    end

    it "remembers nothing for an approval" do
      settled(lists("/home")) { |pending| pending.approve(surface: "spec") }

      expect(queue.denied(requester: "agent", path: "/home")).to be_nil
    end

    # Scenario: a postpone is not a remembered denial
    it "remembers nothing for a postpone, so the same call parks again" do
      settled(lists("/home")) do |pending|
        pending.decide(Lain::Approval::Verdict::Hold.new(note: "after lunch"), surface: "spec", authority: :human)
      end

      expect(queue.denied(requester: "agent", path: "/home")).to be_nil
      expect(queue.denied_call(requester: "agent", tool: "list_files", input: { "path" => "/home" },
                               cwd: Lain::Session.cwd_of(nil))).to be_nil
    end

    describe "a call the silence rule denied" do
      def lapsed(effect, silence:)
        silent = described_class.new(journal:, timeout: 0.01, silence:)
        Sync { silent.adjudicate(effect, in_dir("/srv/p")) }
        silent
      end

      def repeat_of(queue, effect)
        queue.denied_call(requester: "agent", tool: effect.name, input: effect.input, cwd: "/srv/p")
      end

      # Scenario: a repeat is not parked again
      it "remembers the exact call, in the words the model was told" do
        effect = tool_call("bash", { "command" => "cat .env" })

        expect(repeat_of(lapsed(effect, silence: Lain::Approval::Silence::DENY), effect))
          .to have_attributes(reason: start_with("denied after 0:01 with no answer; the call waits for a human"),
                              authority: :automatic)
      end

      it "holds nothing against its path, since nobody judged the path" do
        queue = lapsed(lists("/home"), silence: Lain::Approval::Silence::DENY)

        expect(queue.denied(requester: "agent", path: "/home")).to be_nil
      end

      it "remembers nothing when the silence rule postponed it" do
        effect = tool_call("bash", { "command" => "cat .env" })

        expect(repeat_of(lapsed(effect, silence: Lain::Approval::Silence::HOLD), effect)).to be_nil
      end

      it "is forgotten once a human speaks, so the resend parks again for a real answer" do
        effect = tool_call("bash", { "command" => "cat .env" })
        queue = lapsed(effect, silence: Lain::Approval::Silence::DENY)

        queue.forget_lapsed
        parked = Sync do |task|
          run = task.async { queue.adjudicate(effect, in_dir("/srv/p")) }
          task.with_timeout(1) { queue.dequeue }.tap { _1.approve(surface: "spec", authority: :human) && run.wait }
        end

        expect([repeat_of(queue, effect), parked.input]).to eq([nil, effect.input])
      end

      it "keeps a human's denial when a human speaks" do
        denied_by_human(tool_call("bash", { "command" => "make deploy" }), in_dir("/srv/p"))

        queue.forget_lapsed

        expect(repeat_of(queue, tool_call("bash", { "command" => "make deploy" })))
          .to have_attributes(reason: "not your business", authority: :human)
      end
    end

    it "remembers nothing for a call that names no path" do
      denied_by_human(tool_call)

      expect(queue.denied(requester: "agent", path: Dir.pwd)).to be_nil
    end

    describe "a denied bash call" do
      def runs(command, **input) = tool_call("bash", { "command" => command, **input })

      def remembered_of(*paths) = paths.to_h { [_1, queue.denied(requester: "agent", path: _1)] }

      it "is remembered by each path its command names, never by the directory it ran in" do
        denied_by_human(runs("cat .env"), in_dir("/srv/p"))

        expect(remembered_of("/srv/p/.env", "/srv/p", "/srv/p/README.md"))
          .to eq("/srv/p/.env" => "not your business", "/srv/p" => nil, "/srv/p/README.md" => nil)
      end

      it "names its paths from the call's own cwd" do
        denied_by_human(runs("cat .env", "cwd" => "sub"), in_dir("/srv/p"))

        expect(queue.denied(requester: "agent", path: "/srv/p/sub/.env")).to eq("not your business")
      end

      it "reads ~ in the command as the home it was built with" do
        homed = described_class.new(journal:, home: "/home/u")
        Sync do |task|
          run = task.async { homed.adjudicate(runs("cat ~/notes"), in_dir("/srv/p")) }
          homed.dequeue.deny(surface: "spec", authority: :human, reason: "mine")
          run.wait
        end

        expect(homed.denied(requester: "agent", path: "/home/u/notes")).to eq("mine")
      end

      it "remembers nothing for a ~ word when it was built with no home" do
        denied_by_human(runs("cat ~/notes"), in_dir("/srv/p"))

        expect(queue.denied(requester: "agent", path: "/srv/p/~/notes")).to be_nil
      end

      it "remembers nothing for a command whose paths cannot be named" do
        denied_by_human(runs('cat "$HOME/.netrc"'), in_dir("/srv/p"))

        expect(remembered_of("/srv/p", "/srv/p/.netrc").values).to all(be_nil)
      end

      it "remembers nothing a command only partly read names" do
        denied_by_human(runs("cat .env; cd x; cat y"), in_dir("/srv/p"))

        expect(queue.denied(requester: "agent", path: "/srv/p/.env")).to be_nil
      end

      it "remembers neither the directory it runs in nor any directory above it" do
        ["git add .", "ls ..", "du -sh /srv/p"].each { denied_by_human(runs(_1), in_dir("/srv/p")) }

        expect(remembered_of("/srv/p/.env", "/srv/p", "/srv").values).to all(be_nil)
      end

      # Asked again rather than refused: the human denied a look at the parent,
      # not every read in the project below it.
      it "remembers no directory at or above one a cd led to" do
        denied_by_human(runs("cd /tmp/x && ls /tmp"), in_dir("/srv/p"))

        expect(remembered_of("/tmp", "/tmp/.env").values).to all(be_nil)
      end

      it "does not remember a literal directory the call runs below" do
        denied_by_human(runs("ls /home/u"), in_dir("/home/u/p"))

        expect(remembered_of("/home/u", "/home/u/.netrc").values).to all(be_nil)
      end

      it "remembers no word that starts with a dash, but the operand beside it" do
        denied_by_human(runs("ls -la"), in_dir("/srv/p"))
        denied_by_human(runs("rm -rf f"), in_dir("/srv/p"))

        expect(remembered_of("/srv/p/a", "/srv/p/f")).to eq("/srv/p/a" => nil, "/srv/p/f" => "not your business")
      end

      it "remembers a file a cd led to, but not the directory the cd named" do
        denied_by_human(runs("cd x && cat .env"), in_dir("/srv/p"))

        expect(remembered_of("/srv/p/x/.env", "/srv/p/x/a.rb"))
          .to eq("/srv/p/x/.env" => "not your business", "/srv/p/x/a.rb" => nil)
      end

      it "parks a call its stack parsed without parsing the command again" do
        command = "cd x && cat .env"
        parses = 0
        allow(Lain::Ext::TreeSitter).to receive(:query).and_wrap_original do |original, source, *rest|
          parses += 1 if source == command
          original.call(source, *rest)
        end
        face = nil
        parser = Lain::Middleware::ParsedCommand.new(scan: Lain::Approval::Disclosure::Unscanned)
        parser.call(Lain::Middleware::Env.wrap({ effect: runs(command), context: in_dir("/srv/p") })) do |env|
          denied_by_human(runs(command), env.fetch(:context)) { face = _1.cwd_face }
          env.merge(result: :done)
        end

        expect([remembered_of("/srv/p/x/.env"), face, parses])
          .to eq([{ "/srv/p/x/.env" => "not your business" }, 'in "/srv/p"', 1])
      end

      it "remembers neither a glob's directory nor a recursive search's root" do
        denied_by_human(runs("cat .e*"), in_dir("/srv/p"))
        denied_by_human(runs("grep -r token ."), in_dir("/srv/p"))

        expect(remembered_of("/srv/p", "/srv/p/.env", "/srv/p/lib/a.rb").values).to all(be_nil)
      end
    end

    describe "a denied call through the file facts it was built over" do
      let(:queue) do
        described_class.new(journal:, file_facts: Lain::FileFacts::Recorded.new(
          places: ["/srv/p"], landings: { "/srv/p/cfglink" => "/srv/p/.env.local" }
        ))
      end

      it "is remembered by where the facts land it, with nothing on disk" do
        denied_by_human(tool_call("read_file", { "path" => "cfglink" }), in_dir("/srv/p"))

        expect(queue.denied(requester: "agent", path: "/srv/p/.env.local")).to eq("not your business")
      end

      it "parks the call with where the facts land its path, never asking the live disk" do
        parked = nil
        asked = live_asks do
          parked = Sync do |task|
            task.async { queue.adjudicate(tool_call("read_file", { "path" => "cfglink" }), in_dir("/srv/p")) }
            queue.dequeue.tap { _1.deny(surface: "spec", authority: :human) }
          end
        end

        expect(parked.landing).to eq("/srv/p/.env.local")
        expect(asked).to eq([])
      end

      it "parks a call that names no path with no landing" do
        parked = Sync do |task|
          task.async { queue.adjudicate(tool_call("bash", { "command" => "ls" }), in_dir("/srv/p")) }
          queue.dequeue.tap { _1.deny(surface: "spec", authority: :human) }
        end

        expect(parked.landing).to be_nil
      end

      it "asks the live disk by default" do
        expect(described_class.new(journal:).file_facts).to be(Lain::FileFacts::LIVE)
      end

      it "holds a command's word by its own name, not by the directory the facts land it in" do
        queue = described_class.new(journal:, file_facts: Lain::FileFacts::Recorded.new(
          places: ["/srv/p", "/srv/p/dir"], landings: { "/srv/p/link" => "/srv/p/dir" }
        ))
        settled = lambda do |effect, context|
          Sync do |task|
            task.async { queue.dequeue.deny(surface: "spec", authority: :human, reason: "not your business") }
            queue.call(effect, context)
          end
        end
        settled.call(tool_call("bash", { "command" => "cat link" }), in_dir("/srv/p"))

        expect(%w[/srv/p/link /srv/p/dir].map { queue.denied(requester: "agent", path: _1) })
          .to eq(["not your business", nil])
      end
    end

    describe "a denied call through a link" do
      def runs(command) = tool_call("bash", { "command" => command })

      around do |example|
        Dir.mktmpdir("queue-link") do |dir|
          @dir = File.realpath(dir)
          example.run
        end
      end

      def linked(name, target)
        File.symlink(target, File.join(@dir, name))
      end

      it "is remembered by the file the link lands on as well as by its own name" do
        File.write(File.join(@dir, ".env.local"), "K=v\n")
        linked("cfglink", ".env.local")

        denied_by_human(runs("cat cfglink"), in_dir(@dir))

        expect(%W[#{@dir}/cfglink #{@dir}/.env.local].map { queue.denied(requester: "agent", path: _1) })
          .to all(eq("not your business"))
      end

      it "is remembered by the file a path tool's link lands on" do
        File.write(File.join(@dir, ".env.local"), "K=v\n")
        linked("cfglink", ".env.local")

        denied_by_human(tool_call("read_file", { "path" => "cfglink" }), in_dir(@dir))

        expect(queue.denied(requester: "agent", path: "#{@dir}/.env.local")).to eq("not your business")
      end

      it "answers for a link asked about whose target was denied" do
        File.write(File.join(@dir, ".env.local"), "K=v\n")
        linked("cfglink", ".env.local")

        denied_by_human(tool_call("read_file", { "path" => ".env.local" }), in_dir(@dir))

        expect(queue.denied(requester: "agent", path: "#{@dir}/cfglink")).to eq("not your business")
      end

      it "is remembered by its lexical path only when the link dangles" do
        linked("cfglink", "missing.env")

        denied_by_human(runs("cat cfglink"), in_dir(@dir))

        expect(%W[#{@dir}/cfglink #{@dir}/missing.env].to_h { [_1, queue.denied(requester: "agent", path: _1)] })
          .to eq("#{@dir}/cfglink" => "not your business", "#{@dir}/missing.env" => nil)
      end

      it "does not remember the directory a command's link lands on" do
        Dir.mkdir(File.join(@dir, "tree"))
        linked("treelink", "tree")

        denied_by_human(runs("cat treelink"), in_dir(@dir))

        expect(queue.denied(requester: "agent", path: "#{@dir}/tree/a.rb")).to be_nil
      end
    end

    describe "the exact call a human denied" do
      def runs(command) = tool_call("bash", { "command" => command })

      def repeat_of(command, requester: "agent", cwd: "/srv/p")
        queue.denied_call(requester:, tool: "bash", input: { "command" => command }, cwd:)
      end

      before { denied_by_human(runs("make deploy"), in_dir("/srv/p")) }

      it "answers the human's reason for the same call from the same requester in the same directory" do
        expect(repeat_of("make deploy")).to have_attributes(reason: "not your business", authority: :human)
      end

      it "answers nothing for a different call, another requester, or another directory" do
        expect([repeat_of("make test"), repeat_of("make deploy", requester: "researcher"),
                repeat_of("make deploy", cwd: "/srv/q")]).to all(be_nil)
      end
    end

    it "remembers no call a machine decided" do
      settled(tool_call) { |pending| pending.deny(surface: Lain::Approval::Parked::SecretSurface::SURFACE) }

      expect(queue.denied_call(requester: "agent", tool: "dangerous", input: { "text" => "boom" },
                               cwd: Lain::Session.cwd_of(nil))).to be_nil
    end

    it "remembers nothing for a path that cannot be resolved" do
      denied_by_human(lists("/home/\0x"))

      expect(queue.denied(requester: "agent", path: "/home")).to be_nil
    end

    it "remembers no deny a surface left undeclared" do
      settled(lists("/tmp/x")) { |pending| pending.deny(surface: "tty") }

      expect(queue.denied(requester: "agent", path: "/tmp/x")).to be_nil
    end

    it "remembers nothing a machine or a fault decided" do
      [Lain::Approval::Parked::SecretSurface::SURFACE, Lain::Frontend::ApprovalPolicy::FAULT_SURFACE].each do |surface|
        settled(lists("/tmp/x")) { |pending| pending.deny(surface:) }
      end

      expect(queue.denied(requester: "agent", path: "/tmp/x")).to be_nil
    end

    it "remembers nothing the window decided" do
      timed = described_class.new(journal:, timeout: 0.01)
      Sync { timed.adjudicate(lists("/tmp/x"), nil) }

      expect(timed.denied(requester: "agent", path: "/tmp/x")).to be_nil
    end

    it "remembers nothing for a declined secret release, which is a no about regions and not the path" do
      regions = Lain::Sensitivity::Regions.detect("API_KEY=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n")
      outstanding = described_class::Outstanding.new(path: "/srv/creds.txt", regions:)
      Sync do |task|
        run = task.async { queue.adjudicate(tool_call("read_file", { "path" => "/srv/creds.txt" }), nil, outstanding:) }
        queue.dequeue.deny(surface: "spec", reason: "keep the token")
        run.wait
      end

      expect(queue.denied(requester: "agent", path: "/srv/creds.txt")).to be_nil
    end

    it "settles a binary path against a non-ASCII cwd without raising, and leaves nothing parked" do
      denied_by_human(lists("\xFF/x".b), in_dir("/srv/proj\u00e9t"))

      expect(queue.count).to eq(0)
    end

    it "remembers nothing for a pending its requester abandoned" do
      Sync { |task| task.async { queue.adjudicate(lists("/tmp/x"), nil) }.stop }

      expect(queue.denied(requester: "agent", path: "/tmp/x")).to be_nil
    end
  end

  # A command whose automatically approved output was withheld may be approved
  # by a person only, so its pending says so and an automatic surface is never
  # offered it.
  describe "a call barred from automatic approval" do
    def carried(barred:) = Lain::Middleware::WithholdAutomaticOutput::Carried.new(nil, barred:)

    def parked_pendings(*contexts)
      Sync do |task|
        runs = contexts.map { |context| task.async { queue.adjudicate(tool_call, context) } }
        pendings = contexts.map { task.with_timeout(1) { queue.dequeue } }
        yield pendings
      ensure
        pendings&.each { |pending| pending.deny(surface: "spec") }
        runs&.each(&:wait)
      end
    end

    it "parks a pending only a human may decide" do
      parked_pendings(carried(barred: true), carried(barred: false), nil) do |barred, unbarred, bare|
        expect(barred).to be_humans_only
        expect(unbarred).not_to be_humans_only
        expect(bare).not_to be_humans_only
      end
    end
  end

  describe "the notes a context carries" do
    let(:noted) { Lain::Approval::Escalation::Noted.new(nil, "cat is /repo/bin/cat") }

    def notes_of(context, queue: self.queue)
      Sync do |task|
        run = task.async { queue.adjudicate(tool_call, context) }
        pending = task.with_timeout(1) { queue.dequeue }
        pending.deny(surface: "spec")
        run.wait
        pending.notes
      end
    end

    it "reads them into the pending, frozen" do
      expect(notes_of(noted)).to eq(["cat is /repo/bin/cat"]).and be_frozen
    end

    it "gives a pending parked with none an empty list" do
      expect(notes_of(nil)).to eq([])
    end

    it "follows the ladder's notes with the call's disclosure, in lain's words" do
      disclosure = Lain::Approval::Disclosure.new(holdings: { ".env" => 1 }, sinks: ["127.0.0.1"], unnameable: false)
      disclosing = Lain::Approval::Escalation::Noted.new(Struct.new(:disclosure).new(disclosure), "a rung's note")

      expect(notes_of(disclosing)).to eq(["a rung's note", '".env" holds 1 sensitive region',
                                          'it names "127.0.0.1" as a network destination'])
    end

    it "keeps what a plain approval does on this box out of the reasons, which the phone shows and cannot act on" do
      disclosure = Lain::Approval::Disclosure.new(holdings: { ".env" => 1 }, sinks: [], unnameable: false)
      unable = described_class.new(journal:, containment: Lain::Confine::Sandbox::Containment.unable("no bwrap"))

      expect(notes_of(Struct.new(:disclosure).new(disclosure),
                      queue: unable)).to eq(['".env" holds 1 sensitive region'])
    end

    it "contains a machine surface's approval of a secret-bearing call, as a person's" do
      contained = described_class.new(journal:, containment: Lain::Confine::Sandbox::Containment::ABLE)
      disclosure = Lain::Approval::Disclosure.new(holdings: { ".env" => 1 }, sinks: [], unnameable: false)
      pending = Sync do |task|
        run = task.async { contained.adjudicate(tool_call, Struct.new(:disclosure).new(disclosure)) }
        task.with_timeout(1) { contained.dequeue }.tap { _1.approve(surface: "oracle") }.tap { run.wait }
      end

      expect(pending).to be_contained
    end

    it "journals an approval's note, so a note asking for network is kept" do
      Sync do |task|
        run = task.async { queue.adjudicate(tool_call, nil) }
        task.with_timeout(1) { queue.dequeue }
            .decide(Lain::Approval::Verdict::Approve.new(note: "network please"), surface: "tty", authority: :human)
        run.wait
      end

      expect(journal_records(journal_io, "approval_decision").last).to include("note" => "network please")
        .and(satisfy { !_1.key?("network") })
    end

    describe "the ports a parked call that reads secrets may be granted" do
      let(:reads_env) { Lain::Approval::Disclosure.new(holdings: { ".env" => 1 }, sinks: [], unnameable: false) }
      let(:granting) { Lain::Confine::Sandbox::Containment.able(grants: true) }

      def ports_of(command, carried: command, queue: described_class.new(journal:, containment: granting))
        context = Struct.new(:disclosure, :parsed_command).new(reads_env, carried && Lain::Shell::Parse.new.call(carried))
        Sync do |task|
          run = task.async { queue.adjudicate(tool_call("bash", { "command" => command }), context) }
          pending = task.with_timeout(1) { queue.dequeue }
          pending.deny(surface: "spec")
          run.wait
          pending.containment.ports
        end
      end

      it "names the ports a build tool's fetch could be granted" do
        expect(ports_of("cargo fetch .env")).to eq([443])
      end

      it "asks the session's verdict, so a program it excludes earns nothing" do
        no_cargo = Struct.new(:nothing) { def permits?(program) = program != "cargo" }.new
        queue = described_class.new(journal:, containment: granting,
                                    verdict: Lain::Shell::Verdict.new(capability_set: no_cargo))

        expect(ports_of("cargo fetch .env", queue:)).to eq([])
      end

      it "reads a carried parse only for the command it was made of" do
        expect(ports_of("git fetch", carried: "cargo fetch .env")).to eq([])
      end

      it "reads the command itself when no parse was carried" do
        expect(ports_of("cargo fetch .env", carried: nil)).to eq([443])
      end
    end

    it "says nothing of containment on a call that reads no secret" do
      contained = described_class.new(journal:, containment: Lain::Confine::Sandbox::Containment::ABLE)

      expect(notes_of(Struct.new(:disclosure).new(Lain::Approval::Disclosure::NONE), queue: contained)).to eq([])
    end

    it "journals a human's choice of network on the decision" do
      contained = described_class.new(journal:, containment: Lain::Confine::Sandbox::Containment::ABLE)
      disclosure = Lain::Approval::Disclosure.new(holdings: { ".env" => 1 }, sinks: [], unnameable: false)
      Sync do |task|
        run = task.async { contained.adjudicate(tool_call, Struct.new(:disclosure).new(disclosure)) }
        task.with_timeout(1) { contained.dequeue }
            .decide(Lain::Approval::Verdict::Approve.new(network: true), surface: "tty", authority: :human)
        run.wait
      end

      expect(journal_records(journal_io, "approval_decision").last).to include("verdict" => "approve",
                                                                               "network" => true)
    end

    it "answers reasons with lain's words plain and everyone else's quoted, in the order given" do
      deferred = Lain::Approval::Judged::Deferred.new(noted)
      reasons = Sync do |task|
        run = task.async { queue.adjudicate(tool_call, deferred) }
        pending = task.with_timeout(1) { queue.dequeue }
        pending.deny(surface: "spec")
        run.wait
        pending.reasons
      end

      expect(reasons.map(&:to_s)).to eq(['"cat is /repo/bin/cat"', Lain::Approval::Judged::DEFERRAL_NOTE])
      expect(reasons.map(&:own?)).to eq([false, true])
    end

    it "bounds a long reason to its first 400 characters and says how much was cut" do
      reason = described_class::Reason.of("x" * 900)

      expect(reason.text).to eq("#{"x" * 400}[cut at 400 of 900 characters; the full call is in lain://approval]")
    end

    it "cuts a reason once however often it is rebuilt" do
      cut = described_class::Reason.of("x" * 900)

      expect([described_class::Reason.new(**cut.to_h).text, cut.with(own: true).text]).to all(eq(cut.text))
    end

    it "leaves a reason of 400 characters whole" do
      expect(described_class::Reason.own("y" * 400).text).to eq("y" * 400)
    end

    it "journals the deferral in the pending record's notes" do
      deferred = Lain::Approval::Judged::Deferred.new(noted)
      Sync do |task|
        run = task.async { queue.adjudicate(tool_call, deferred) }
        task.with_timeout(1) { queue.dequeue }.deny(surface: "spec")
        run.wait
      end

      expect(pending_records.sole["notes"]).to eq(["cat is /repo/bin/cat", Lain::Approval::Judged::DEFERRAL_NOTE])
    end

    it "keeps the deferral among the notes the journal records" do
      pending = described_class::Pending.new(effect: tool_call, identity: Lain::Requester.main, clock: -> { 0.0 },
                                             notes: ["a path", described_class::Reason.own("lain says")])

      expect(pending.notes).to eq(["a path", "lain says"])
    end
  end

  # gate.rb's doctrine, applied to the queue's OWN writes: an unattended gate
  # refuses, it never wedges. Journalling is evidence about the turn and must
  # never be able to cost the turn -- Gate sits above Handler::Live, so an
  # exception raised here reaches the agent loop as a dead turn rather than as
  # the denial an unanswerable approval is owed.
  describe "a failing journal degrades, it never wedges the turn" do
    def queue_over(journal, timeout: 0.01)
      described_class.new(journal:, timeout:)
    end

    it "still denies -- and does not raise -- when the announcement cannot be written" do
      queue = queue_over(ApprovalSpecSupport::BrittleJournal.new(journal, fails_on: Lain::Telemetry::AwaitingHuman))
      verdict = nil

      expect { verdict = Sync { queue.call(tool_call, nil) } }.not_to raise_error
      expect(verdict).to be(false)
    end

    it "records the unwritable announcement as the Journal's own journal_error, and still parks" do
      queue = queue_over(ApprovalSpecSupport::BrittleJournal.new(journal, fails_on: Lain::Telemetry::AwaitingHuman))

      Sync { queue.call(tool_call, nil) }

      expect(error_records).to contain_exactly(
        a_hash_including("entry_class" => "Lain::Telemetry::AwaitingHuman",
                         "error" => "IOError: no space left on device")
      )
      expect(decision_records).to contain_exactly(a_hash_including("verdict" => "deny", "surface" => "timeout"))
    end

    # The same hazard on the settle path, which predates the announcement: a
    # raise inside `ensure` replaces the verdict with an exception.
    it "still answers the verdict when the DECISION record cannot be written" do
      queue = queue_over(ApprovalSpecSupport::BrittleJournal.new(journal, fails_on: described_class::Pending))
      verdict = nil

      expect { verdict = Sync { queue.call(tool_call, nil) } }.not_to raise_error
      expect(verdict).to be(false)
      expect(error_records).to contain_exactly(
        a_hash_including("entry_class" => "Lain::Approval::Parked::Queue::Pending")
      )
    end

    # The record's OWN construction is a thing that can raise: Guards refuses a
    # park it cannot name. Building it as an ARGUMENT would evaluate it before
    # control entered the rescue, putting the guard's ArgumentError right back
    # outside the protection -- the same wedge, one line above the fix for it.
    # Reachable: anthropic/stream_assembler.rb:104 seeds "id" from a
    # skeleton that a content_block_start may omit, and Effect::ToolCall interns
    # `-nil.to_s` into "", which fails presence.
    it "denies rather than raising when the gated call carries no id to correlate on" do
      queue = queue_over(journal)
      nameless = Lain::Effect::ToolCall.new(tool_use_id: nil, name: "dangerous", input: {})
      verdict = nil

      expect { verdict = Sync { queue.call(nameless, nil) } }.not_to raise_error
      expect(verdict).to be(false)
      expect(approval_types).to eq(%w[approval_decision])
      expect(error_records).to contain_exactly(
        a_hash_including("entry_class" => "Lain::Telemetry::AwaitingHuman",
                         "error" => /\AArgumentError: tool_use_id must name the gated call/)
      )
    end

    it "denies rather than raising when the call's id is blank" do
      queue = queue_over(journal)
      blank = Lain::Effect::ToolCall.new(tool_use_id: "   ", name: "dangerous", input: {})

      expect { Sync { queue.call(blank, nil) } }.not_to raise_error
      expect(error_records.length).to eq(1)
      expect(decision_records).to contain_exactly(a_hash_including("verdict" => "deny"))
    end

    # A journal that is simply gone: the degraded write fails too, and there is
    # nowhere left to be honest to. The turn still gets its denial.
    it "denies rather than raising when even the error record cannot be written" do
      journal.close
      queue = queue_over(journal)
      verdict = nil

      expect { verdict = Sync { queue.call(tool_call, nil) } }.not_to raise_error
      expect(verdict).to be(false)
    end
  end

  describe "timeout is deny" do
    let(:queue) { described_class.new(journal:, timeout: 0.01) }

    it "denies when no surface answers within the window (fail-closed holds)" do
      verdict = Sync { queue.call(tool_call, nil) }

      expect(verdict).to be(false)
    end

    it "journals the timeout as a timed-out denial" do
      Sync { queue.call(tool_call, nil) }

      expect(decision_records).to contain_exactly(
        a_hash_including("verdict" => "deny", "surface" => "timeout", "timed_out" => true)
      )
    end

    it "returns the refusal Result through the gate" do
      runs = []
      gate = gate_over(runs)

      result = Sync { gate.call(tool_call) }

      expect(result).to have_attributes(is_error: true)
      expect(runs).to be_empty
    end

    it "tells the model the call lapsed, in the window's own words" do
      result = Sync { gate_over([]).call(tool_call("dangerous")) }

      expect(result.content).to eq('refused tool "dangerous": denied after 0:01 with no answer; ' \
                                   "#{Lain::Approval::Silence::WAITS}")
    end
  end

  # Scenario: a silent park holds
  describe "a silent park under the project's default silence" do
    let(:queue) do
      described_class.new(journal:, timeout: 0.01, silence: Lain::Approval::Silence.from(Lain::Config.empty))
    end

    it "postpones the call, signed by the clock, naming the window" do
      pending = Sync { queue.adjudicate(tool_call, nil) }

      expect(pending).to have_attributes(postponed?: true, approved?: false, timed_out?: true,
                                         reason: "no answer within 0.01s",
                                         lapse: "postponed after 0:01 with no answer")
    end

    it "journals a timed-out postpone, not a denial" do
      Sync { queue.call(tool_call, nil) }

      expect(decision_records).to contain_exactly(
        a_hash_including("verdict" => "postpone", "surface" => "timeout", "timed_out" => true)
      )
    end

    it "tells the agent the call is postponed and waits for a human, and its turn goes on" do
      runs = []
      result = Sync { gate_over(runs).call(tool_call("dangerous")) }

      expect(result.content).to eq('refused tool "dangerous": postponed after 0:01 with no answer; ' \
                                   "#{Lain::Approval::Silence::WAITS}")
      expect([result.ends_turn, runs]).to eq([false, []])
    end

    # The parked set is what /approve, /deny and lain://approval list. A longer
    # window, so the re-issued call is surely still parked when it is approved.
    it "parks the re-issued call again, listed for the human, and runs it once approved" do
      queue = described_class.new(journal:, timeout: 0.3, silence: Lain::Approval::Silence.from(Lain::Config.empty))
      gate = Lain::Middleware::Gate.new(policy: asking_ladder(queue))
      toolset = Lain::Toolset.new([gated_tool(runs = [])])
      issue = -> { dispatch_call("dangerous", { "text" => "again" }, id: "tu_1", toolset:, layers: [gate]) }

      listed, result = Sync do |task|
        issue.call
        again = task.async { issue.call }
        pending = task.with_timeout(1) { queue.dequeue }
        [queue.map(&:input), pending.approve(surface: "spec") && again.wait]
      end

      expect(listed).to eq([{ "text" => "again" }])
      expect([result, runs]).to eq([Lain::Tool::Result.ok("again"), [{ "text" => "again" }]])
    end

    it "warns of the postpone on the pending's own face" do
      pending = Sync do |task|
        task.async { queue.call(tool_call, nil) }
        queue.dequeue.tap { _1.deny(surface: "spec") }
      end

      expect(pending.silence_face).to eq("postpones in 0:01")
    end
  end

  describe "a pending that was drawn after it parked" do
    let(:queue) { described_class.new(journal:, timeout: 0.3) }

    def elapsed_until_settled(draw_at:)
      Sync do |task|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        run = task.async { queue.adjudicate(tool_call, nil) }
        pending = queue.dequeue
        task.async do
          task.sleep(draw_at)
          pending.drawn
        end
        [run.wait, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
      end
    end

    it "gets its whole window from the moment it was drawn" do
      pending, elapsed = elapsed_until_settled(draw_at: 0.2)

      expect([pending.surface, elapsed]).to match([described_class::TIMEOUT_SURFACE, be >= 0.49])
    end

    it "keeps the window from the park for a pending nobody drew" do
      pending, elapsed = elapsed_until_settled(draw_at: 5)

      expect([pending.surface, elapsed]).to match([described_class::TIMEOUT_SURFACE, be_between(0.3, 4)])
    end

    it "is still decided by an answer inside the extended window" do
      verdict = Sync do |task|
        run = task.async { queue.adjudicate(tool_call, nil) }
        pending = queue.dequeue
        task.sleep(0.1)
        pending.drawn
        task.sleep(0.15)
        pending.approve(surface: "tty")
        run.wait
      end

      expect(verdict).to have_attributes(surface: "tty", decision: :approve)
    end
  end

  # The Conductor#supervise grace/Ctrl-C path stops the gated fiber while it is
  # parked. An asked-and-abandoned approval must not linger: no leak in the
  # pending list, no ghost delivered to a surface (a human prompted to approve
  # a call nobody awaits), and no journal hole (probes/i4/probe_cancelled_requester.rb).
  describe "a cancelled requester abandons its pending" do
    def dequeue_or_nothing(task)
      task.with_timeout(0.05) { queue.dequeue }
    rescue Async::TimeoutError
      :nothing_delivered
    end

    it "removes the abandoned pending from the parked list" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        expect(queue.count).to eq(1)

        run.stop

        expect(queue.count).to eq(0)
      end
    end

    it "journals the abandonment, so an asked-and-unanswered approval leaves no hole" do
      Sync do |task|
        task.async { queue.call(tool_call, nil) }.stop
      end

      expect(decision_records).to contain_exactly(
        a_hash_including("verdict" => "deny", "surface" => "abandoned", "timed_out" => false)
      )
    end

    it "never delivers the orphan to a surface" do
      Sync do |task|
        task.async { queue.call(tool_call, nil) }.stop

        expect(dequeue_or_nothing(task)).to eq(:nothing_delivered)
      end
    end

    it "skips the abandoned pending and delivers the next live one" do
      Sync do |task|
        task.async { queue.call(tool_call("dangerous", { "n" => 1 }), nil) }.stop
        live = task.async { queue.call(tool_call("dangerous", { "n" => 2 }), nil) }

        pending = queue.dequeue
        expect(pending.input).to eq({ "n" => 2 })

        pending.approve(surface: "tty")
        expect(live.wait).to be(true)
      end
    end

    it "makes a late surface answer a no-op on an abandoned pending" do
      pending = nil

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        pending = queue.first
        run.stop
      end

      expect(pending.approve(surface: "tty")).to be(false)
      expect(pending).to have_attributes(surface: "abandoned", decision: :deny)
    end
  end

  # A cockpit's chat reads no approval, so NOTHING dequeues: the editor and the
  # chat's arrival note both observe the parked set. An arrival buffer that
  # kept every decided pending would keep each one -- its input included, a
  # whole file body for a write -- for the life of the session.
  describe "a decided pending leaves the arrival buffer" do
    # The buffer is not observable through the queue's own messages -- that it
    # holds nothing a surface could still be handed is the whole claim -- so
    # this reads it, as signoff_queue_spec reads its parked set.
    def retained = queue.instance_variable_get(:@arrivals).size

    it "retains nothing after ten calls are parked and decided with no consumer" do
      Sync do |task|
        10.times do |index|
          run = task.async { queue.call(tool_call("dangerous", { "n" => index }), nil) }
          queue.first.approve(surface: "nvim")
          run.wait
        end
      end

      expect(retained).to eq(0)
    end

    it "still hands a consumer the live pending parked behind a decided one, in order" do
      Sync do |task|
        first = task.async { queue.call(tool_call("dangerous", { "n" => 1 }), nil) }
        second = task.async { queue.call(tool_call("dangerous", { "n" => 2 }), nil) }
        third = task.async { queue.call(tool_call("dangerous", { "n" => 3 }), nil) }
        queue.first.deny(surface: "nvim")
        first.wait

        expect([queue.dequeue.input, queue.dequeue.input]).to eq([{ "n" => 2 }, { "n" => 3 }])
        [second, third].each(&:stop)
      end
    end
  end

  describe "first answer wins" do
    it "makes the second surface's answer a no-op: single-shot resolution, no double-run" do
      runs = []
      gate = gate_over(runs)

      Sync do |task|
        run = task.async { gate.call(tool_call) }

        # Two surfaces watching ONE pending approval: one drew it from the
        # queue, the other looked at the pending list.
        first_surface = queue.dequeue
        second_surface = queue.first

        expect(first_surface.approve(surface: "tty")).to be(true)
        expect(second_surface.deny(surface: "nvim")).to be(false)
        expect(second_surface).to have_attributes(surface: "tty", decision: :approve)
        run.wait
      end

      expect(runs.length).to eq(1)
      expect(decision_records).to contain_exactly(a_hash_including("surface" => "tty", "verdict" => "approve"))
    end

    it "keeps a late surface answer a no-op after the timeout already denied" do
      queue = described_class.new(journal:, timeout: 0.01)
      pending = nil

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        pending = queue.dequeue
        expect(run.wait).to be(false)
      end

      expect(pending.approve(surface: "tty")).to be(false)
      expect(pending).to have_attributes(surface: "timeout", decision: :deny)
    end
  end

  # A pending can CARRY the sensitive regions approving it would release,
  # so a surface can say what is at stake. A capability, not a flow -- the queue
  # sits below the read and has only a path, so the arm holding the file's bytes
  # is what builds one. Nothing here detects, and nothing here releases.
  describe "a pending carrying outstanding sensitive regions" do
    # Real regions, not doubles: the two security claims below (no bytes in the
    # journal, no write to the ledger) can only discriminate against regions
    # that genuinely hold the secret.
    let(:secret) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }
    let(:regions) { Lain::Sensitivity::Regions.detect("API_KEY=#{secret}\n") }
    let(:outstanding) { described_class::Outstanding.new(path: "/repo/.env", regions:) }

    it "carries the regions and their file onto the parked pending" do
      Sync do |task|
        run = task.async { queue.adjudicate(tool_call, nil, outstanding:) }

        expect(queue.first.outstanding).to have_attributes(path: "/repo/.env", count: 1)
        queue.dequeue.approve(surface: "spec")
        run.wait
      end
    end

    it "discloses nothing by default, which is every ordinary gated call" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }

        expect(queue.first.outstanding.any?).to be(false)
        queue.dequeue.approve(surface: "spec")
        run.wait
      end
    end

    it "answers the verdict exactly as an undisclosing pending does" do
      verdict = Sync do |task|
        run = task.async { queue.adjudicate(tool_call, nil, outstanding:) }
        queue.dequeue.approve(surface: "spec")
        run.wait.approved?
      end

      expect(verdict).to be(true)
    end

    # Telemetry::AwaitingHuman leaves the Pending's `input` off because tool
    # arguments may carry credential bytes; regions ARE those bytes, so the same
    # rule binds harder. The whole journal is searched, not one record type.
    it "keeps the regions' bytes out of the journal entirely" do
      Sync do |task|
        run = task.async { queue.adjudicate(tool_call, nil, outstanding:) }
        queue.dequeue.approve(surface: "spec")
        run.wait
      end

      expect(journal_io.string).not_to include(secret)
    end

    # The card's ruling: `decide` stays a pure single-shot decision, and
    # releasing is the settling caller's move.
    #
    # Asserted as SHAPE, not as behaviour, and that distinction cost a review
    # round: an example that builds a Ledger, hands it to nobody and then finds
    # it empty is vacuous, because no implementation of `decide` could write to
    # an object it was never given. What makes the ruling true is that there is
    # no ledger to write -- so the parameter list is the thing to pin, and a
    # `ledger:` added with a default (the likely shape, since every other
    # collaborator here has one) fails right here.
    it "takes no ledger, so `decide` has nothing to release into" do
      expect(described_class::Pending.instance_method(:initialize).parameters)
        .to eq([%i[keyreq effect], %i[keyreq identity], %i[keyreq clock], %i[key timeout],
                %i[key outstanding], %i[key humans_only], %i[key cwd], %i[key within], %i[key wall],
                %i[key notes], %i[key file_facts], %i[key silence], %i[key spawn], %i[key named],
                %i[key containment], %i[key mask]])
    end

    # The other half of the same ruling, one level up: a queue that constructed
    # a ledger of its own would satisfy the parameter pin above. Comments may
    # cite the ruling, so only code lines are searched.
    it "names no ledger anywhere in the queue's code" do
      code = File.read(File.expand_path("../../../../lib/lain/approval/parked/queue.rb", __dir__))
                 .lines.grep_v(/\A\s*#/).join

      expect(code).not_to match(/ledger/i)
    end

    # queue.rb's no-lock claim covers a pending that carries regions exactly as
    # it covers one that does not: nothing added here yields.
    it "is still ordinary coordination state -- first answer wins, the second reports that it lost" do
      Sync do |task|
        run = task.async { queue.adjudicate(tool_call, nil, outstanding:) }
        first_surface = queue.dequeue
        second_surface = queue.first

        expect(first_surface.approve(surface: "tty")).to be(true)
        expect(second_surface.deny(surface: "nvim")).to be(false)
        expect(second_surface).to have_attributes(surface: "tty", decision: :approve, outstanding:)
        run.wait
      end
    end

    # The Gherkin says "decided from two fibers at once", and the example above
    # does not do that -- it decides one object twice inside ONE fiber, a path
    # HEAD already covered. This is the real claim: both racers are awake and
    # released together, so the scheduler, not the writing order, picks the
    # winner. Repeated, because a race that holds once may hold by luck.
    it "keeps exactly one winner when two live fibers race to decide it" do
      verbs = %i[approve deny]
      outcomes = Array.new(25) do
        pending = described_class::Pending.new(effect: tool_call, identity: Lain::Requester.main,
                                               clock: -> { 0.0 }, outstanding:)
        won = []

        Sync do |task|
          gate = Async::Queue.new
          racers = verbs.map do |verb|
            task.async do
              gate.dequeue
              won << pending.public_send(verb, surface: verb.to_s)
            end
          end
          racers.length.times { gate.enqueue(:go) }
          racers.each(&:wait)
        end

        [won.count(true), won.count(false), pending.outstanding]
      end

      expect(outcomes).to all(eq([1, 1, outstanding]))
    end
  end

  # The reason `/deny <reason>` offers on a call while the call is asked.
  describe "Pending#offering" do
    let(:offered) { described_class::Pending.new(effect: tool_call, identity: Lain::Requester.main, clock: -> { 0.0 }) }

    it "holds no reason before any offering" do
      expect(offered.offered_reason).to be_nil
    end

    it "holds the reason for the block, and none once a block that raised has ended" do
      inside = nil
      expect { offered.offering("wrong tree") { (inside = offered.offered_reason) && raise(IOError, "gone") } }
        .to raise_error(IOError)

      expect([inside, offered.offered_reason]).to eq(["wrong tree", nil])
    end

    it "nests: an inner offering on the same call gives the outer reason back as it ends" do
      seen = offered.offering("outer") do
        offered.offering("inner") { offered.offered_reason }.then { [_1, offered.offered_reason] }
      end

      expect([seen, offered.offered_reason]).to eq([%w[inner outer], nil])
    end
  end

  describe "a decision that is not a tool call" do
    let(:decision) do
      described_class::Decision.new(requester: "egress", kind: "egress", summary: "send 12 bytes to api.example.com",
                                    digest: "b3_abc")
    end

    def asked(timeout: nil)
      Sync do |task|
        asking = task.async { queue.ask_decision(decision, timeout:) }
        pending = task.with_timeout(1) { queue.dequeue }
        yield pending if block_given?
        [asking.wait, pending]
      end
    end

    it "resolves true when a surface approves it and false when one denies it" do
      yes, = asked { |pending| pending.approve(surface: "tty", authority: :human) }
      no, = asked { |pending| pending.deny(surface: "tty", authority: :human) }

      expect([yes, no]).to eq([true, false])
    end

    it "parks a pending that names its kind and its summary in place of a tool call" do
      _, pending = asked { |parked| parked.approve(surface: "tty", authority: :human) }

      expect(pending).to have_attributes(kind: "egress", requester: "egress", humans_only?: true, tool_call?: false)
      expect(pending.call_face).to include("egress").and include("send 12 bytes to api.example.com")
    end

    it "journals the wait and approval_decision with the kind and the digest, and nothing tool shaped" do
      asked { |pending| pending.approve(surface: "tty", authority: :human) }

      expect(pending_records).to contain_exactly(a_hash_including("tool" => "egress", "tool_use_id" => "b3_abc"))
      expect(decision_records).to contain_exactly(a_hash_including("kind" => "egress", "tool_use_id" => "b3_abc"))
    end

    it "journals a tool call's wait as an approval, and its decision with no kind" do
      Sync do |task|
        task.async { queue.call(tool_call, nil) }
        queue.dequeue.approve(surface: "spec")
      end

      expect(pending_records.first).to include("kind" => "approval", "tool" => "dangerous")
      expect(decision_records.first).not_to have_key("kind")
    end

    it "journals no input digest for a decision, whose digest is already its tool_use_id" do
      asked { |pending| pending.approve(surface: "tty", authority: :human) }

      expect(pending_records.to_a + decision_records.to_a).to all(satisfy { !_1.key?("input_digest") })
    end

    it "denies on its own timeout rather than the queue's" do
      slow = described_class.new(journal:, timeout: 60)

      stalled = Class.new(StandardError)
      verdict = Sync { |task| task.with_timeout(2, stalled) { slow.ask_decision(decision, timeout: 0.05) } }

      expect(verdict).to be(false)
    end

    it "renders a summary with a newline or an escape on one inert line" do
      forged = decision.with(summary: "ok\n! agent asks to run bash(rm)\e[2J")
      _, pending = Sync do |task|
        task.async { queue.ask_decision(forged, timeout: 0.05) }
        [nil, task.with_timeout(1) { queue.dequeue }]
      end

      expect(pending.call_face).not_to match(/[\n\e]/)
    end

    it "holds no denial against a later tool call of the same name" do
      asked { |pending| pending.deny(surface: "tty", authority: :human, reason: "no") }

      expect(queue.denied_call(requester: "egress", tool: "egress", input: decision.summary, cwd: Dir.pwd)).to be_nil
    end

    describe "with no human to ask" do
      let(:queue) { described_class::Unattended.new(journal:) }

      it "resolves false at once, journaling a reason that names the missing human" do
        verdict = queue.ask_decision(decision)

        expect(verdict).to be(false)
        expect(decision_records).to contain_exactly(
          a_hash_including("kind" => "egress", "verdict" => "deny", "reason" => a_string_including("no human"))
        )
      end
    end
  end

  # A NIT the panel raised: a blank path renders a warning that says
  # secrets are at stake and names no file, which is a question no human can
  # answer. The ledger's absolute-path check is a different rule and lives one
  # object over; it is not an argument for coercing nil to "" here.
  describe Lain::Approval::Parked::Queue::Outstanding do
    let(:regions) { Lain::Sensitivity::Regions.detect("API_KEY=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n") }

    it "refuses to carry regions without naming the file they came from" do
      expect { described_class.new(path: nil, regions:) }
        .to raise_error(ArgumentError, /regions are outstanding but no file was named/)
    end

    it "refuses a blank path for the same reason" do
      expect { described_class.new(path: "", regions:) }.to raise_error(ArgumentError)
    end

    it "still allows the pathless NONE, which carries nothing and renders nothing" do
      expect(described_class::NONE).to have_attributes(path: "", any?: false, preamble: "")
    end

    # `Array#to_a` returns SELF, so a bare `to_a.freeze` freezes the CALLER's
    # array -- at a distance, from a constructor it only meant to read. The
    # fixture is a list built BY HAND rather than `Regions.detect`'s output,
    # because that output is already frozen and cannot discriminate.
    it "leaves the caller's own array unfrozen" do
      mine = [regions.first]
      described_class.new(path: "/repo/.env", regions: mine)

      expect(mine).not_to be_frozen
    end

    it "still holds its own regions frozen" do
      expect(described_class.new(path: "/repo/.env", regions: regions.to_a).regions).to be_frozen
    end
  end

  describe "masking the face a surface shows" do
    let(:value) { "zq7lowentropyprobevalue42" }
    let(:mask) { ->(text, _context) { text.gsub(value, "<redacted:1>") } }
    let(:call) { tool_call("bash", { "command" => "curl -H #{value} x" }) }

    def parked_by(queue)
      Sync do |task|
        run = task.async { queue.adjudicate(call, Object.new) }
        pending = queue.dequeue
        shown = pending.call_face
        pending.approve(surface: "spec", authority: :human)
        run.wait
        [pending, shown]
      end
    end

    it "shows a placeholder where the call holds a known value, and keeps the real input" do
      pending, shown = parked_by(described_class.new(journal:, mask:))

      expect(shown).to include("<redacted:1>").and(satisfy { !_1.include?(value) })
      expect(pending.input.fetch("command")).to include(value)
    end

    it "shows the call as it is when no mask is given" do
      _, shown = parked_by(queue)

      expect(shown).to include(value)
    end
  end

  describe "where a relative path in a call lands" do
    def face_of(name, input)
      call = Lain::Effect::ToolCall.new(tool_use_id: "tu_cwd", name:, input:)
      described_class::Pending.new(effect: call, identity: Lain::Requester.main, clock: -> { 0.0 }, cwd: "/srv/scratch")
    end

    it "names the directory for a relative path on a file tool" do
      expect(face_of("write_file", { "path" => "src/x.rb" }).call_face).to end_with('in "/srv/scratch"')
    end

    it "names nothing for an absolute or home path" do
      faces = [{ "path" => "/srv/x.rb" }, { "path" => "~/x.rb" }].map { face_of("write_file", _1).cwd_face }

      expect(faces).to eq([nil, nil])
    end

    it "does not count an option word as a relative path" do
      expect(face_of("bash", { "command" => "ls -la /srv" }).cwd_face).to be_nil
    end

    it "names nothing for a decision that is not a tool call" do
      decision = described_class::Decision.new(requester: "egress", kind: "egress", summary: "send", digest: "b3_abc")
      held = described_class::DecisionPending.new(decision:, identity: Lain::Requester.main, clock: -> { 0.0 })

      expect(held.call_face).to eq('egress: "send"')
    end
  end
end
