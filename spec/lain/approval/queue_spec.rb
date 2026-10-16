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
RSpec.describe Lain::Approval::Queue do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:queue) { described_class.new(journal:) }

  def tool_call(name = "dangerous", input = { "text" => "boom" })
    Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)
  end

  def decision_records
    Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a
  end

  def pending_records
    Lain::Journal.records(journal_io.string.lines, type: "approval_pending").to_a
  end

  # The approval records in the order they were written, so "announced before
  # decided" is read off the journal itself rather than inferred.
  def approval_types
    Lain::Journal.records(journal_io.string.lines)
                 .map { |record| record["type"] }
                 .select { |type| type.start_with?("approval_") }
                 .to_a
  end

  def error_records
    Lain::Journal.records(journal_io.string.lines, type: "journal_error").to_a
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

  # The queue as a gate's policy, in front of the one gated tool, driven the
  # way a turn drives a call: through the runner, into a real Live.
  def gate_over(runs)
    toolset = Lain::Toolset.new([gated_tool(runs)])
    gate = Lain::Middleware::Gate.new(policy: queue)
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

    # The queue as a Gate policy answers a ruling itself, so it is never
    # adapted, and its refusal is never final: a surface answering no this
    # time could answer yes the next.
    it "answers #rule with the surface's ruling, never a final one" do
      Sync do |task|
        denied = task.async { queue.rule(tool_call, nil) }
        queue.dequeue.deny(surface: "tty")
        approved = task.async { queue.rule(tool_call, nil) }
        queue.dequeue.approve(surface: "tty")

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
      described_class::Pending.new(effect:, requester: "agent", clock: -> { now.call }, timeout:)
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
      pending = described_class::Pending.new(effect:, requester: "agent", clock: -> { now }, timeout: 300,
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
  end

  describe "the words a denial is given in" do
    def pending = described_class::Pending.new(effect: tool_call, requester: "agent", clock: -> { 0.0 })

    it "keeps them on one line with no control bytes, so they stay one clause of the tool result" do
      denied = pending
      denied.deny(surface: "tty", reason: "stay\ninside\e[2K  ~/dev/frugirl\r")

      expect(denied.reason).to eq("stay inside [2K ~/dev/frugirl")
    end

    it "holds none for blank words or for an approval" do
      blank = pending
      blank.deny(surface: "tty", reason: "  \n")
      approved = pending
      approved.decide(true, surface: "tty", reason: "fine")

      expect([blank.reason, approved.reason]).to eq([nil, nil])
    end
  end

  # Parking is itself evidence. Before this, the only observable moment in
  # an approval's life was the post-hoc decision, so nothing could render "a
  # call is waiting on you" -- the state a human is actually asked to act on.
  describe "parking announces itself" do
    it "journals an approval_pending record naming the requester and the tool" do
      queue = described_class.new(journal:, requester: "the-agent")

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.approve(surface: "tty")
        run.wait
      end

      expect(pending_records).to contain_exactly(
        a_hash_including("type" => "approval_pending", "requester" => "the-agent", "tool" => "dangerous")
      )
    end

    it "announces the park BEFORE any decision is made" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        expect(approval_types).to eq(%w[approval_pending])

        queue.dequeue.approve(surface: "tty")
        run.wait
      end

      expect(approval_types).to eq(%w[approval_pending approval_decision])
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

      expect(pending_records.map { |record| record.fetch("humans_only") }).to eq([true, false])
    end

    it "keeps the announcement when the requester is abandoned before deciding" do
      Sync do |task|
        task.async { queue.call(tool_call, nil) }.stop
      end

      expect(pending_records).to contain_exactly(a_hash_including("tool" => "dangerous"))
      expect(decision_records).to contain_exactly(a_hash_including("surface" => "abandoned", "verdict" => "deny"))
      expect(approval_types).to eq(%w[approval_pending approval_decision])
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
  # ({Approval::PolicySwitch::Requested}), which is why nothing between a
  # child's gate and this queue had to widen its `call(effect, context)` duck.
  # That value's OWN behaviour -- its delegation, and the names it refuses --
  # is spec'd at its mirrored path, `spec/lain/approval/policy_switch_spec.rb`;
  # what belongs here is what the QUEUE does with it.
  describe "who a parked call is asked on behalf of" do
    def asked_by(requester) = Lain::Approval::PolicySwitch::Requested.new(nil, requester)

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
      requester ? Lain::Approval::PolicySwitch::Requested.new(session, requester) : session
    end

    def settled(effect, context = nil)
      Sync do |task|
        run = task.async { queue.adjudicate(effect, context) }
        yield queue.dequeue
        run.wait
      end
    end

    def denied_by_human(effect, context = nil, reason: "not your business")
      settled(effect, context) { |pending| pending.deny(surface: "spec", reason:) }
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

      expect(queue.denied(requester: described_class::REQUESTER, path: "/home")).to eq("not your business")
    end

    it "resolves a relative path against the call's own cwd, cleaned" do
      denied_by_human(lists("../secret/./x"), in_dir("/srv/project"))

      expect(queue.denied(requester: "agent", path: "/srv/secret/x")).to eq("not your business")
    end

    it "reads ~ as the home it was built with" do
      homed = described_class.new(journal:, home: "/home/u")
      Sync do |task|
        run = task.async { homed.adjudicate(lists("~/notes"), in_dir("/srv/p")) }
        homed.dequeue.deny(surface: "spec", reason: "mine")
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
          homed.dequeue.deny(surface: "spec", reason: "mine")
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

      it "remembers neither a glob's directory nor a recursive search's root" do
        denied_by_human(runs("cat .e*"), in_dir("/srv/p"))
        denied_by_human(runs("grep -r token ."), in_dir("/srv/p"))

        expect(remembered_of("/srv/p", "/srv/p/.env", "/srv/p/lib/a.rb").values).to all(be_nil)
      end
    end

    it "remembers nothing for a path that cannot be resolved" do
      denied_by_human(lists("/home/\0x"))

      expect(queue.denied(requester: "agent", path: "/home")).to be_nil
    end

    it "remembers nothing a machine or a fault decided" do
      [Lain::Approval::SecretSurface::SURFACE, Lain::Frontend::ApprovalPolicy::FAULT_SURFACE].each do |surface|
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
      queue = queue_over(ApprovalSpecSupport::BrittleJournal.new(journal, fails_on: Lain::Telemetry::ApprovalPending))
      verdict = nil

      expect { verdict = Sync { queue.call(tool_call, nil) } }.not_to raise_error
      expect(verdict).to be(false)
    end

    it "records the unwritable announcement as the Journal's own journal_error, and still parks" do
      queue = queue_over(ApprovalSpecSupport::BrittleJournal.new(journal, fails_on: Lain::Telemetry::ApprovalPending))

      Sync { queue.call(tool_call, nil) }

      expect(error_records).to contain_exactly(
        a_hash_including("entry_class" => "Lain::Telemetry::ApprovalPending",
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
        a_hash_including("entry_class" => "Lain::Approval::Queue::Pending")
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
        a_hash_including("entry_class" => "Lain::Telemetry::ApprovalPending",
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

      expect(result.content).to eq('approval denied for tool "dangerous": denied after 0:01 with no answer')
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

    # Telemetry::ApprovalPending leaves the Pending's `input` off because tool
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
        .to eq([%i[keyreq effect], %i[keyreq requester], %i[keyreq clock], %i[key timeout],
                %i[key outstanding], %i[key humans_only], %i[key cwd], %i[key within], %i[key wall],
                %i[key judge_deferred]])
    end

    # The other half of the same ruling, one level up: a queue that constructed
    # a ledger of its own would satisfy the parameter pin above. Comments may
    # cite the ruling, so only code lines are searched.
    it "names no ledger anywhere in the queue's code" do
      code = File.read(File.expand_path("../../../lib/lain/approval/queue.rb", __dir__))
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
        pending = described_class::Pending.new(effect: tool_call, requester: "agent",
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

  # A NIT the panel raised: a blank path renders a warning that says
  # secrets are at stake and names no file, which is a question no human can
  # answer. The ledger's absolute-path check is a different rule and lives one
  # object over; it is not an argument for coercing nil to "" here.
  describe Lain::Approval::Queue::Outstanding do
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
end
