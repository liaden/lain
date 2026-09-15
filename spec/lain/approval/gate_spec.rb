# frozen_string_literal: true

require "json"
require "open3"
require "stringio"

# Approval::Gate is the artifact gate: any artifact answering #digest and
# #gate_question must pass it before an irreversible action consumes that
# digest. It asks through an ask_human-shaped duck, blocks on the promise with
# a timeout -> deny, journals a gate_decision attributed to the answering
# surface, and remembers the approved digest so ensure_approved! refuses
# loudly otherwise.
#
# `policy:` is carried onto the record as a label, so the policies wrap this
# one rather than branching inside it.
RSpec.describe Lain::Approval::Gate do
  # An ask_human-shaped duck: #ask returns a Promise the injected block may
  # resolve (the degenerate sync case) or leave pending forever (the
  # silence-denies path). The block receives the promise and the question.
  def scripted_asker(&resolver)
    Object.new.tap do |asker|
      asker.define_singleton_method(:ask) do |question|
        Lain::Promise.new.tap { |promise| resolver&.call(promise, question) }
      end
    end
  end

  def approve_asker(surface: "human")
    scripted_asker { |promise, _q| promise.resolve(described_class::Answer.approve(surface)) }
  end

  def deny_asker(surface: "human")
    scripted_asker { |promise, _q| promise.resolve(described_class::Answer.deny(surface)) }
  end

  def silent_asker
    scripted_asker { |_promise, _q| nil }
  end

  # The whole artifact duck: a digest and its human-facing rendering. An epic
  # plan, an issue plan, a Criteria -- the gate never learns which.
  def artifact(digest: "blake3:plan", question: "Approve the epic plan? Reply approve or deny.")
    Data.define(:digest, :gate_question).new(digest:, gate_question: question)
  end

  let(:plan) { artifact }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def decisions
    Lain::Journal.records(journal_io.string.lines, type: "gate_decision").to_a
  end

  def gate(**overrides)
    described_class.new(journal:, **overrides)
  end

  def call(gate, asker:, stage: "epic_plan", epic_slug: "lain-epics", **overrides)
    Sync { gate.call(plan, asker:, stage:, epic_slug:, **overrides) }
  end

  describe "an unapproved digest refuses to pass" do
    it "raises NotApproved naming the digest when the gate holds no decisions" do
      expect { gate.ensure_approved!(plan) }
        .to raise_error(described_class::NotApproved, /#{Regexp.escape(plan.digest)}/)
    end

    it "still refuses after a denial -- a denied digest is an unapproved digest" do
      subject_gate = gate
      expect(call(subject_gate, asker: deny_asker)).to be(false)

      expect(subject_gate.approved?(plan.digest)).to be(false)
      expect { subject_gate.ensure_approved!(plan) }.to raise_error(described_class::NotApproved)
    end

    it "refuses an edited artifact -- a different content address is a different gate" do
      subject_gate = gate
      call(subject_gate, asker: approve_asker)
      edited = artifact(digest: "blake3:plan-v2")

      expect(subject_gate.ensure_approved!(plan)).to eq(plan.digest)
      expect { subject_gate.ensure_approved!(edited) }
        .to raise_error(described_class::NotApproved, /#{Regexp.escape(edited.digest)}/)
    end
  end

  describe "a timeout denies and attributes itself" do
    it "journals approved false, answered_by timeout, and the partition keys it was called with" do
      subject_gate = gate(timeout: 0.02)

      approved = call(subject_gate, asker: silent_asker, stage: "research", epic_slug: "lain-epics")

      expect(approved).to be(false)
      expect(subject_gate.approved?(plan.digest)).to be(false)
      record = decisions.first
      expect(record["artifact_digest"]).to eq(plan.digest)
      expect(record["approved"]).to be(false)
      expect(record["answered_by"]).to eq(described_class::TIMEOUT_SURFACE)
      expect(record["stage"]).to eq("research")
      expect(record["epic_slug"]).to eq("lain-epics")
    end

    it "leaves evidence_digest and reason null -- later cards populate them, this path has neither" do
      call(gate(timeout: 0.02), asker: silent_asker)

      expect(decisions.first).to include("evidence_digest" => nil, "reason" => nil)
    end
  end

  # CTRL-C IS A DECIDED WAIT, NOT A DROPPED ONE. Async turns a real interrupt
  # into an Async::Cancel while a fiber is parked in the await -- the same
  # exception a caller's own `Async::Task#stop` raises -- so a scripted
  # cancellation here exercises the identical path a terminal's Ctrl-C takes.
  #
  # The rescue that journals it is scoped to the WAIT ALONE, never the whole
  # of `#call`: a cancel that lands earlier, in `asker.ask`, has no verdict to
  # journal, and one that lands later, after `record` has already written a
  # real answer, must not write a second, contradictory decision for the same
  # question.
  describe "a cancelled wait settles fail-closed as interrupted" do
    it "journals approved false and answered_by interrupted before the cancellation propagates" do
      subject_gate = gate(timeout: 30)

      Sync do |task|
        asking = task.async { subject_gate.call(plan, asker: silent_asker, stage: "implementation", epic_slug: "demo") }
        sleep 0.1
        asking.stop
      end

      record = decisions.first
      expect(record["artifact_digest"]).to eq(plan.digest)
      expect(record["approved"]).to be(false)
      expect(record["answered_by"]).to eq(described_class::INTERRUPTED_SURFACE)
      expect(subject_gate.approved?(plan.digest)).to be(false)
    end

    it "still withdraws the question and leaves a real asker free" do
      asker = Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.empty(store: Lain::Store.new) })

      Sync do |task|
        asking = task.async { gate(timeout: 30).call(plan, asker:, stage: "implementation", epic_slug: "demo") }
        task.yield until asker.pending?
        asking.stop
      end

      expect(asker.pending?).to be(false)
      expect { Sync { asker.ask("the next gate?") } }.not_to raise_error
    end

    # An asker duck's own `#ask` can yield too -- a journaled announcement, a
    # write that parks on the reactor -- before it ever hands back a promise
    # `started` could be measured against. A cancel landing there used to
    # reach `@clock.call - nil`, a TypeError that replaced the cancellation
    # and journaled nothing.
    it "propagates untouched a cancel that lands before the question was asked, journaling nothing" do
      yielding_asker = Object.new
      yielding_asker.define_singleton_method(:ask) do |_question|
        sleep 0.2
        Lain::Promise.new
      end
      outcome = nil

      Sync do |task|
        asking = task.async do
          gate(timeout: 30).call(plan, asker: yielding_asker, stage: "research", epic_slug: "demo")
        rescue Async::Cancel => e
          outcome = e
          raise
        end
        sleep 0.05
        asking.stop
      end

      expect(outcome).to be_a(Async::Cancel)
      expect(decisions).to be_empty
    end

    # `SignoffQueue#settle` takes the newest decision for a partition, so a
    # second record appended after an approval would withdraw it in the fold
    # -- a human's "y" quietly overwritten by an "interrupted" that followed
    # it, for the one question that was already answered.
    #
    # `Async::Task#defer_stop` genuinely protects a deferred block ACROSS a
    # yield -- a cancellation arriving while the block runs is held off until
    # the block completes, then raised, never swallowed. Verified directly: a
    # deferred block that yields (`sleep`) still runs to completion despite an
    # external `.stop()`, and only unwinds once it returns. `#call` wraps its
    # own `record` + registry add in exactly this, so both the journal write
    # this asserts on AND the in-memory registry add that follows it commit
    # together, or neither does.
    it "writes no second record for a cancel landing after a decision is already journaled, and still registers it" do
      # Captured OUTSIDE the singleton method: `define_singleton_method`'s
      # block runs with `self` rebound to the object it is defined on, so
      # `described_class` (an RSpec method on the example, not a closed-over
      # local) is unreachable from inside it.
      approved_answer = described_class::Answer.approve("human")
      approving = Object.new
      approving.define_singleton_method(:ask) do |_question|
        Lain::Promise.new.tap { |promise| promise.resolve(approved_answer) }
      end
      real_journal = journal
      written = false
      slow_journal = Object.new
      # A FLAG, never a fixed sleep on the outer side: the approving asker
      # resolves synchronously, so nothing guarantees the child task has even
      # started by a clock-timed `sleep` in the caller -- only that it has
      # written once `written` flips true, which is the one moment this test
      # means to catch a cancellation landing.
      slow_journal.define_singleton_method(:record) do |event|
        real_journal.record(event)
        written = true
        sleep 0.2
      end
      subject_gate = described_class.new(journal: slow_journal, timeout: 30)

      Sync do |task|
        asking = task.async { subject_gate.call(plan, asker: approving, stage: "research", epic_slug: "demo") }
        task.yield until written
        asking.stop
      end

      expect(decisions.size).to eq(1)
      expect(decisions.first["approved"]).to be(true)
      expect(subject_gate.approved?(plan.digest)).to be(true)
    end

    # The OTHER half of the same gap: a cancellation landing BEFORE the
    # journal's bytes are down at all -- ahead of the write, not mid-write --
    # used to leave an answered question with NO decision whatsoever, worse
    # than the duplicate the sibling example above guards against. `#call`'s
    # `task.defer_stop` closes this too: it wraps the whole `record` call, not
    # just the part of it that happens to yield.
    it "still writes the decision when a cancel lands before the journal's bytes are down at all" do
      approved_answer = described_class::Answer.approve("human")
      approving = Object.new
      approving.define_singleton_method(:ask) do |_question|
        Lain::Promise.new.tap { |promise| promise.resolve(approved_answer) }
      end
      real_journal = journal
      entered_record = false
      slow_journal = Object.new
      # `entered_record` flips BEFORE the yield-ahead-of-the-write this
      # simulates (an io_uring submit, a Monitor wait) -- the whole point is
      # to land the cancellation before any byte is written, which a flag set
      # only after the write (as the sibling example uses) could never catch.
      slow_journal.define_singleton_method(:record) do |event|
        entered_record = true
        sleep 0.2
        real_journal.record(event)
      end
      subject_gate = described_class.new(journal: slow_journal, timeout: 30)

      Sync do |task|
        asking = task.async { subject_gate.call(plan, asker: approving, stage: "research", epic_slug: "demo") }
        task.yield until entered_record
        asking.stop
      end

      expect(decisions.size).to eq(1)
      expect(decisions.first["approved"]).to be(true)
      expect(subject_gate.approved?(plan.digest)).to be(true)
    end
  end

  # A window that never closes is still a window that ENDS: only a
  # cancellation ends it, never the reactor's own clock. {Window::Unbounded},
  # never `Float::INFINITY` passed as a plain number: io-event's own timer
  # conversion computes a C `time_t` from the duration, which is undefined
  # behaviour for an infinite double -- sound by luck on this box's io_uring
  # selector, and a hard `Errno::EINVAL` crash on epoll (pinned under a real
  # epoll process below). {Window::Unbounded} arms no reactor timer at all,
  # so there is nothing for that conversion to run on.
  describe "an unbounded window" do
    it "never closes on its own; only a cancellation settles the wait" do
      still_waiting = nil

      Sync do |task|
        asking = task.async do
          gate(timeout: described_class::Window::Unbounded).call(plan, asker: silent_asker, stage: "research",
                                                                       epic_slug: "demo")
        end
        sleep 0.1
        still_waiting = asking.running?
        asking.stop
      end

      expect(still_waiting).to be(true)
      expect(decisions.first["answered_by"]).to eq(described_class::INTERRUPTED_SURFACE)
    end
  end

  # `Window::Unbounded` schedules NO reactor timer at all -- the one property
  # a spec keeping any OTHER timer alive (a `sleep`, a second gate) cannot
  # tell apart from a Bounded window whose duration merely never fires. Only a
  # subprocess booted with no other timer on the heap, under the selector
  # that turns an infinite `with_timeout` into `Errno::EINVAL`, can.
  describe "an unbounded window under a real epoll reactor", :seam do
    # `IO_EVENT_SELECTOR` is read once, at the selector's own construction
    # inside `Sync`/`Async` -- a later `ENV[]=` in this process changes
    # nothing already running, so proving the fix needs a fresh process
    # booted with it set, the way `bundle exec ruby -e` boots one.
    it "arms no timer: a promise resolved a second later by a plain thread, nothing else pending, still lands" do
      script = <<~RUBY
        require "lain"
        require "stringio"

        io = StringIO.new
        gate = Lain::Approval::Gate.new(journal: Lain::Journal.new(io:),
                                        timeout: Lain::Approval::Gate::Window::Unbounded)
        artifact = Data.define(:digest, :gate_question).new(digest: "blake3:epoll", gate_question: "Approve?")
        reader, writer = IO.pipe
        Thread.new { sleep 1; writer.write("go\\n") }

        asker = Object.new
        asker.define_singleton_method(:ask) do |_question|
          Lain::Promise.new.tap do |promise|
            Async::Task.current.async do
              promise.resolve(Lain::Approval::Gate::Answer.approve("human")) if reader.gets
            end
          end
        end

        approved = Sync { gate.call(artifact, asker:, stage: "research", epic_slug: "demo") }
        raise "not approved" unless approved

        puts "OK"
      RUBY

      env = { "IO_EVENT_SELECTOR" => "EPoll", "BUNDLE_GEMFILE" => File.expand_path("../../../Gemfile", __dir__) }
      out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-W0", "-e", script)

      expect(out).not_to include("EINVAL")
      expect(status).to be_success
      expect(out).to include("OK")
    end
  end

  # A GATE THAT DOES NOT OPEN WITHDRAWS ITS QUESTION. The window closing is
  # lain's decision, not the human's: without a withdrawal the asker is left
  # holding a set nobody will ever answer, so the NEXT gate on that asker is
  # refused as outstanding and a stale inbox line offers a question that now
  # decides nothing. That is what makes an unattended pause fatal to a run
  # rather than merely slow.
  describe "a gate that denies withdraws the question it asked" do
    def recording_asker(withdrawn)
      Object.new.tap do |asker|
        asker.define_singleton_method(:ask) { |_question| Lain::Promise.new }
        asker.define_singleton_method(:withdraw) { |promise| withdrawn << promise }
      end
    end

    it "withdraws the set when the window closes" do
      withdrawn = []

      call(gate(timeout: 0.02), asker: recording_asker(withdrawn))

      expect(withdrawn.size).to eq(1)
    end

    # The real asker, and the real consequence: a second gate must be askable.
    it "leaves a real asker free to ask the next issue's gate, with nothing pending" do
      asker = Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.empty(store: Lain::Store.new) })
      subject_gate = gate(timeout: 0.02)

      Sync do
        subject_gate.call(artifact(digest: "blake3:first"), asker:, stage: "implementation", epic_slug: "demo")
        subject_gate.call(artifact(digest: "blake3:second"), asker:, stage: "implementation", epic_slug: "demo")
      end

      expect(asker.pending?).to be(false)
      expect(decisions.size).to eq(2)
      expect(decisions.map { |record| record["answered_by"] }).to eq(%w[timeout timeout])
    end

    # An asker with no withdrawal is still a legal asker: the CLI's own prompt
    # answers synchronously and has nothing to withdraw.
    it "asks nothing of an asker that does not offer a withdrawal" do
      expect { call(gate(timeout: 0.02), asker: silent_asker) }.not_to raise_error
    end

    # A CANCELLED WAIT IS STILL A WAIT THAT ENDED. Stopping the fiber unwinds it
    # at the await, so a withdrawal placed after the answer never runs -- and the
    # set stays outstanding, refusing every later gate on that asker. Whoever
    # gave up waiting is not always the timeout: a caller polling its own
    # interrupt stops this fiber from outside.
    it "withdraws the set when its wait is cancelled rather than answered" do
      asker = Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.empty(store: Lain::Store.new) })

      Sync do |task|
        asking = task.async do
          gate(timeout: 30).call(plan, asker:, stage: "implementation", epic_slug: "demo")
        end
        sleep 0.1
        asking.stop
      end

      expect(asker.pending?).to be(false)
      expect { Sync { asker.ask("the next gate?") } }.not_to raise_error
    end
  end

  # A SETTLED GATE RETIRES ITS QUESTION. The asker's withdrawal frees the asker,
  # but the Q stays in the record, and every inbox reader that folds the record
  # lists it until something names it consumed. A gate is not a tool call, so no
  # committed turn ever cites its question: the gate says so itself, however it
  # settled.
  describe "a gate that settles retires the question it asked" do
    let(:store) { Lain::Store.new }
    let(:asker) { Lain::Tools::AskHuman.new(parent: Lain::Timeline.empty(store:)) }

    def consumptions
      Lain::Journal.records(journal_io.string.lines, type: "questions_consumed").to_a
    end

    def asked_digest = asker.last_question.digest

    it "names the question once its window closes" do
      call(gate(timeout: 0.02), asker:, stage: "implementation")

      expect(consumptions.map { |record| record["digests"] }).to eq([[asked_digest]])
    end

    # A promise that names its question and resolves with a verdict: the shape
    # the chat's asker has once the epic seat has read the human's words.
    it "names the question once it is answered" do
      named = Lain::Tools::AskHuman::Pending.new("blake3:question")
      answering = Object.new.tap { |duck| duck.define_singleton_method(:ask) { |_question| named } }

      approved = Sync do |task|
        deciding = task.async { gate.call(plan, asker: answering, stage: "implementation", epic_slug: "demo") }
        named.resolve(described_class::Answer.approve("human"))
        deciding.wait
      end

      expect(approved).to be(true)
      expect(consumptions.map { |record| record["digests"] }).to eq([["blake3:question"]])
    end

    it "names the question when its wait is cancelled rather than answered" do
      Sync do |task|
        asking = task.async { gate(timeout: 30).call(plan, asker:, stage: "implementation", epic_slug: "demo") }
        task.yield until asker.pending?
        asking.stop
      end

      expect(consumptions.map { |record| record["digests"] }).to eq([[asked_digest]])
    end

    it "journals the verdict before the retirement" do
      call(gate(timeout: 0.02), asker:, stage: "implementation")

      expect(Lain::Journal.records(journal_io.string.lines).map { |record| record["type"] }.to_a)
        .to eq(%w[gate_decision questions_consumed])
    end

    # The CLI's own prompt and every standing answer write no question into any
    # record, so there is nothing for a reader to list and nothing to retire.
    it "journals no retirement for an asker whose promise names no question" do
      call(gate, asker: approve_asker)

      expect(consumptions).to be_empty
    end
  end

  # The gate reads a verdict and nothing else: which words approve, and which
  # surface typed them, is decided before an Answer reaches it. So an answer
  # that carries a reason of its own -- a reply nobody could classify, say --
  # has that reason journaled beside the verdict.
  describe "an answer that carries its own reason" do
    it "journals the answer's reason over the caller's" do
      unclassified = described_class::Answer.new(approved: false, surface: "unrecognised",
                                                 reason: "the reply \"lgtm\" names no verdict")
      asker = scripted_asker { |promise, _q| promise.resolve(unclassified) }

      call(gate, asker:, reason: "the caller's note")

      expect(decisions.first).to include("answered_by" => "unrecognised",
                                         "reason" => "the reply \"lgtm\" names no verdict")
    end

    it "journals the caller's reason when the answer carries none" do
      call(gate, asker: approve_asker, reason: "the caller's note")

      expect(decisions.first).to include("reason" => "the caller's note")
    end

    it "keeps a carried reason frozen, so the answer stays shareable" do
      expect(described_class::Answer.new(approved: false, surface: +"unrecognised", reason: +"why"))
        .to be_deeply_frozen
    end
  end

  describe "approval is monotonic" do
    it "keeps approved? true through approve -> deny while both decisions are journaled" do
      subject_gate = gate(timeout: 0.02)

      Sync do
        subject_gate.call(plan, asker: approve_asker, stage: "epic_plan", epic_slug: "lain-epics")
        subject_gate.call(plan, asker: silent_asker, stage: "epic_plan", epic_slug: "lain-epics")
      end

      expect(subject_gate.approved?(plan.digest)).to be(true)
      expect(subject_gate.ensure_approved!(plan)).to eq(plan.digest)
      expect(decisions.map { |record| record.values_at("approved", "answered_by") })
        .to eq([[true, "human"], [false, "timeout"]])
    end
  end

  describe "attribution and the asked question" do
    it "asks the artifact's own gate_question verbatim -- the artifact owns its rendering" do
      asked = nil
      asker = scripted_asker do |promise, question|
        asked = question
        promise.resolve(described_class::Answer.approve("human"))
      end

      call(gate, asker:)

      expect(asked).to eq(plan.gate_question)
    end

    it "carries the surface verbatim from the resolving Answer -- the gate stays blind to which" do
      call(gate, asker: approve_asker(surface: "gate_adjudicator"))

      expect(decisions.first["answered_by"]).to eq("gate_adjudicator")
    end

    it "journals the policy label it was called under, defaulting to interactive" do
      call(gate, asker: approve_asker)
      call(gate, asker: approve_asker, policy: "signoff")

      expect(decisions.map { |record| record["policy"] }).to eq([described_class::DEFAULT_POLICY, "signoff"])
    end

    it "stamps the elapsed latency from the injected clock" do
      ticks = [10.0, 10.5].each

      call(gate(clock: -> { ticks.next }), asker: approve_asker)

      expect(decisions.first["latency"]).to be_within(1e-9).of(0.5)
    end
  end

  describe "the reactor precondition" do
    it "names the gate and the missing Sync block rather than raising a bare RuntimeError" do
      expect { gate.call(plan, asker: approve_asker, stage: "epic_plan", epic_slug: "lain-epics") }
        .to raise_error(described_class::NoReactor, /Approval::Gate.*Sync/m)
    end
  end

  describe "#each -- the standing approvals, for the bench to inspect" do
    it "enumerates the digests that carry a standing approval" do
      subject_gate = gate
      call(subject_gate, asker: approve_asker)

      expect(subject_gate.to_a).to eq([plan.digest])
    end

    it "omits a denied digest" do
      subject_gate = gate(timeout: 0.02)
      call(subject_gate, asker: silent_asker)

      expect(subject_gate.to_a).to be_empty
    end
  end

  # A day-two process rebuilds the registry from what day-one already
  # journaled, rather than starting empty and re-litigating every digest.
  describe ".from_journal -- approvals survive a restart" do
    it "registers an approved digest and skips a denied one, so ensure_approved! still works" do
      approved_artifact = artifact(digest: "blake3:d")
      denied_artifact = artifact(digest: "blake3:e")

      Sync do
        journal_gate = gate
        journal_gate.call(approved_artifact, asker: approve_asker, stage: "epic_plan", epic_slug: "lain-epics")
        journal_gate.call(denied_artifact, asker: deny_asker, stage: "epic_plan", epic_slug: "lain-epics")
      end

      rebuilt = described_class.from_journal(journal_io.string.lines, journal:)

      expect(rebuilt.approved?(approved_artifact.digest)).to be(true)
      expect(rebuilt.approved?(denied_artifact.digest)).to be(false)
      expect(rebuilt.ensure_approved!(approved_artifact)).to eq(approved_artifact.digest)
    end

    it "folds without raising when foreign record types sit between gate_decisions" do
      Sync { gate.call(plan, asker: approve_asker, stage: "epic_plan", epic_slug: "lain-epics") }
      lines = journal_io.string.lines
      foreign = [%({"type":"turn_usage","tokens":10}\n), %({"type":"doc_written","path":"plan.md"}\n)]
      interleaved = [lines.first, *foreign, *lines.drop(1)]

      rebuilt = nil
      expect { rebuilt = described_class.from_journal(interleaved, journal:) }.not_to raise_error
      expect(rebuilt.approved?(plan.digest)).to be(true)
    end

    # A damaged line is a Lain::Error naming the record in one sentence, the way
    # the sign-off queue's own fold refuses it -- never a bare ArgumentError a
    # human reads as a backtrace from `lain epic land`.
    it "refuses a gate_decision whose approved field is \"maybe\" in one line naming the record" do
      damaged = JSON.generate(Lain::Approval::GateDecision.new(artifact_digest: "blake3:maybe", epic_slug: "demo",
                                                               stage: "issue_plan", approved: true,
                                                               answered_by: "human", policy: "interactive",
                                                               latency: 1.0, issue_id: "a")
                                                          .to_journal.merge("approved" => "maybe"))

      expect { described_class.from_journal([damaged], journal:) }.to raise_error(Lain::Error) { |error|
        expect(error).to be_a(Lain::Approval::SignoffQueue::UnreadableRecord)
        expect(error.message).to include("gate_decision", "blake3:maybe", "approved", "demo/issue_plan/a")
        expect(error.message).not_to include("\n")
      }
    end
  end

  describe "an issue-scoped decision" do
    it "journals the issue and the criteria it was handed" do
      call(gate, asker: approve_asker, stage: "issue_plan", issue_id: "a", criteria_digest: "blake3:criteria")

      expect(decisions.last).to include("stage" => "issue_plan", "issue_id" => "a",
                                        "criteria_digest" => "blake3:criteria")
    end
  end

  # Scenario: the old approval is gone. It gated a bare Criteria and was
  # constructed nowhere; an issue's criteria now ride its plan through this
  # gate instead, so the two could only ever have drifted apart.
  describe "the criteria-only gate this one replaced" do
    it "is gone, together with the record it journaled" do
      expect(defined?(Lain::Gherkin::Approval)).to be_nil
      expect(defined?(Lain::Telemetry::GherkinApproval)).to be_nil
    end
  end

  describe Lain::Approval::GateDecision do
    def record(**overrides)
      described_class.new(artifact_digest: "blake3:abc", epic_slug: "lain-epics", stage: "epic_plan",
                          approved: true, answered_by: "human", policy: "interactive", latency: 0.5,
                          evidence_digest: nil, **overrides)
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(record(artifact_digest: +"blake3:abc", answered_by: +"human")).to be_deeply_frozen
    end

    it "journals under the gate_decision discriminator" do
      expect(record.to_journal["type"]).to eq("gate_decision")
    end

    it "carries the full wire shape, evidence, reason and issue scope included" do
      expect(record(evidence_digest: "blake3:spike", reason: "researcher spawn failed").to_journal.keys)
        .to contain_exactly("type", "artifact_digest", "epic_slug", "stage", "approved", "answered_by",
                            "policy", "latency", "evidence_digest", "reason", "issue_id", "criteria_digest")
    end

    # The rationale field: nullable like evidence_digest -- "no rationale was
    # given" is a value, not a missing field.
    it "defaults reason to nil, so a verdict with no rationale journals one" do
      expect(record.to_journal).to include("reason" => nil)
    end

    # An epic-wide decision names no issue, and says so with the key present:
    # the round-trip metric folds on it and an absent key would read the same
    # only by accident.
    it "journals an epic-wide decision with a nil issue and no criteria" do
      expect(record.to_journal).to include("issue_id" => nil, "criteria_digest" => nil)
    end

    it "keeps an issue's scope frozen, so the record stays shareable" do
      expect(record(issue_id: +"a", criteria_digest: +"blake3:criteria")).to be_deeply_frozen
    end

    it "refuses a blank issue id -- it would name a partition no issue can match" do
      expect { record(issue_id: "  ") }.to raise_error(ArgumentError, /issue_id/)
    end

    [[], ["a"], 7, { "a" => 1 }].each do |damaged|
      it "refuses an issue_id of #{damaged.inspect} -- an issue is named by text or not at all" do
        expect { record(issue_id: damaged) }.to raise_error(ArgumentError, /issue_id/)
      end
    end

    it "keeps a supplied reason frozen, so the record stays shareable" do
      decision = record(reason: +"researcher spawn failed -- parked without evidence")

      expect(decision).to be_deeply_frozen
      expect(decision.reason).to be_frozen
    end

    it "refuses a nil answered_by -- a verdict always names who answered" do
      expect { record(answered_by: nil) }.to raise_error(ArgumentError, /answered_by/)
    end

    it "refuses a non-boolean approved -- presence: cannot reject false, so inclusion guards it" do
      expect { record(approved: "yes") }.to raise_error(ArgumentError, /approved/)
    end

    it "refuses a nil artifact_digest -- a decision always names what it judged" do
      expect { record(artifact_digest: nil) }.to raise_error(ArgumentError, /artifact_digest/)
    end

    it "refuses a nil epic_slug -- it is the queue partition key" do
      expect { record(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
    end

    it "refuses a nil stage -- the other half of the partition key" do
      expect { record(stage: nil) }.to raise_error(ArgumentError, /stage/)
    end

    it "refuses a nil policy -- how the verdict was reached is part of the evidence" do
      expect { record(policy: nil) }.to raise_error(ArgumentError, /policy/)
    end
  end

  describe Lain::Approval::Gate::Answer do
    it "is Ractor-shareable (a boolean and an interned surface String)" do
      expect(described_class.approve(+"human")).to be_deeply_frozen
    end

    it "reads its verdict through #approved?" do
      expect(described_class.approve("human").approved?).to be(true)
      expect(described_class.deny("timeout").approved?).to be(false)
    end
  end
end
