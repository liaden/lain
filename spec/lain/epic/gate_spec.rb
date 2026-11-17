# frozen_string_literal: true

require "json"
require "open3"
require "stringio"
require "tmpdir"

# Epic::Gate is the artifact gate: any artifact answering #digest and
# #gate_question must pass it before an irreversible action consumes that
# digest. It asks through an ask_human-shaped duck, blocks on the promise with
# a timeout -> deny, journals a gate_decision attributed to the answering
# surface, and remembers nothing: where a partition stands is Signoff's fold
# of those records, read here through each partition's GateView.
#
# `policy:` is carried onto the record as a label, so the policies wrap this
# one rather than branching inside it.
RSpec.describe Lain::Epic::Gate do
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
    journal_records(journal_io, "gate_decision")
  end

  def gate(**overrides)
    described_class.new(journal:, **overrides)
  end

  def call(gate, asker:, stage: "epic_plan", epic_slug: "lain-epics", **overrides)
    Sync { gate.call(plan, asker:, stage:, epic_slug:, **overrides) }
  end

  def view_of(digest, stage: "epic_plan", epic_slug: "lain-epics", issue_id: nil)
    gate_view_of(journal_io.string.lines, current: digest, epic_slug:, stage:, issue_id:)
  end

  def phase_of(digest, **partition) = view_of(digest, **partition).phase

  describe "an unapproved digest refuses to pass" do
    it "leaves a partition no gate decided open" do
      expect(phase_of(plan.digest)).to eq(:open)
    end

    it "still refuses after a denial -- a denied digest is an unapproved digest" do
      expect(call(gate, asker: deny_asker)).to be(false)

      expect(phase_of(plan.digest)).to eq(:denied)
    end

    it "refuses an edited artifact -- a different content address is a different gate" do
      call(gate, asker: approve_asker)

      expect(phase_of(plan.digest)).to eq(:approved)
      expect(phase_of("blake3:plan-v2")).to eq(:edited)
    end
  end

  describe "a timeout denies and attributes itself" do
    it "journals approved false, answered_by timeout, and the partition keys it was called with" do
      subject_gate = gate(timeout: 0.02)

      approved = call(subject_gate, asker: silent_asker, stage: "research", epic_slug: "lain-epics")

      expect(approved).to be(false)
      expect(phase_of(plan.digest, stage: "research")).to eq(:denied)
      record = decisions.first
      expect(record["artifact_digest"]).to eq(plan.digest)
      expect(record["verdict"]).to eq("deny")
      expect(record["answered_by"]).to eq(described_class::TIMEOUT_SURFACE)
      expect(record["stage"]).to eq("research")
      expect(record["epic_slug"]).to eq("lain-epics")
    end

    it "leaves evidence_digest null and gives the bare silence rule's reason" do
      call(gate(timeout: 0.02), asker: silent_asker)

      expect(decisions.first).to include("evidence_digest" => nil, "reason" => "timeout")
    end
  end

  # A window that has already closed when it opens, reporting the seconds it
  # stands for, so a 900 second wait is decided without waiting for it.
  def lapsed(seconds)
    Module.new do
      define_singleton_method(:seconds) { seconds }
      define_singleton_method(:open) { self }
      define_singleton_method(:around) { |_task| raise Async::TimeoutError }
    end
  end

  def silence(source = nil)
    return Lain::Approval::Silence.from(Lain::Config.empty) unless source

    Dir.mktmpdir do |root|
      write_config(root, source)
      Lain::Approval::Silence.from(Lain::Config.load(root:, paths: Lain::Paths.new))
    end
  end

  def nine_issue_wave
    ids = (1..9).map { "i#{_1}" }
    graph = Lain::Epic::Graph.new(issues: ids.map { Lain::Epic::Issue.new(id: _1, title: "the #{_1} issue") })
    views = ids.map { |id| Lain::Epic::IssueView.new(issue: graph.fetch(id), graph:, authored: "") }
    Lain::Epic::Submission.wave(slug: "frugirl", views:, number: 1)
  end

  describe "what silence settles as" do
    # Scenario: a silent wave gate holds each issue
    it "holds each issue of a silent wave when the project leaves silence unset" do
      outcome = Sync do
        gate(timeout: lapsed(900), silence:)
          .call(nine_issue_wave, asker: silent_asker, stage: "issue_plan", epic_slug: "frugirl")
      end

      expect(outcome.held.values).to eq(["no answer within 900s"] * 9)
      expect([outcome.denied, outcome.approved]).to eq([{}, []])
      expect(decisions.map { _1.values_at("verdict", "reason", "answered_by") })
        .to eq([["hold", "no answer within 900s", described_class::TIMEOUT_SURFACE]] * 9)
    end

    # Scenario: deny is a choice
    it "denies each item with the word timeout when the project chooses deny" do
      approved = call(gate(timeout: lapsed(900), silence: silence("approval silence: :deny\n")),
                      asker: silent_asker)

      expect(approved).to be(false)
      expect(decisions.map { _1.values_at("verdict", "reason") }).to eq([%w[deny timeout]])
    end

    # Scenario: an interrupt still denies
    [nil, "approval silence: :deny\n"].each do |source|
      it "denies an interrupted wait with the word interrupted under #{source ? "deny" : "hold"}" do
        subject_gate = gate(timeout: 30, silence: silence(source))

        Sync do |task|
          asking = task.async { subject_gate.call(plan, asker: silent_asker, stage: "research", epic_slug: "demo") }
          task.yield until journal_io.size.positive?
          asking.stop
        end

        expect(decisions.map { _1.values_at("verdict", "reason", "answered_by") })
          .to eq([["deny", "interrupted", described_class::INTERRUPTED_SURFACE]])
      end
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
      expect(record["verdict"]).to eq("deny")
      expect(record["answered_by"]).to eq(described_class::INTERRUPTED_SURFACE)
      expect(phase_of(plan.digest, stage: "implementation", epic_slug: "demo")).to eq(:denied)
    end

    it "parks an interrupted wait whose policy parks, leaving the standing approval of that digest standing" do
      subject_gate = gate(timeout: 30)
      call(subject_gate, asker: approve_asker, stage: "research", epic_slug: "demo")

      waits = journal_records(journal_io, "awaiting_human").size
      Sync do |task|
        asking = task.async do
          subject_gate.call(plan, asker: silent_asker, stage: "research", epic_slug: "demo", policy: "deferred",
                                  interrupted: Lain::Epic::GateDecision::Deferred.new)
        end
        task.yield until asking.finished? || journal_records(journal_io, "awaiting_human").size > waits
        asking.stop
      end

      expect(decisions.last.values_at("verdict", "answered_by"))
        .to eq(["deferred", described_class::INTERRUPTED_SURFACE])
      expect(view_of(plan.digest, stage: "research", epic_slug: "demo").standing)
        .to have_attributes(digest: plan.digest, verdict: be_approved)
    end

    it "still withdraws the question and leaves a real asker free" do
      asker = Lain::Tools::AskHuman.new(parent: -> { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) })

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
        return unless event.is_a?(Lain::Epic::GateDecision)

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
      expect(decisions.first["verdict"]).to eq("approve")
      expect(phase_of(plan.digest, stage: "research", epic_slug: "demo")).to eq(:approved)
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
        if event.is_a?(Lain::Epic::GateDecision)
          entered_record = true
          sleep 0.2
        end
        real_journal.record(event)
      end
      subject_gate = described_class.new(journal: slow_journal, timeout: 30)

      Sync do |task|
        asking = task.async { subject_gate.call(plan, asker: approving, stage: "research", epic_slug: "demo") }
        task.yield until entered_record
        asking.stop
      end

      expect(decisions.size).to eq(1)
      expect(decisions.first["verdict"]).to eq("approve")
      expect(phase_of(plan.digest, stage: "research", epic_slug: "demo")).to eq(:approved)
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
    it "arms no timer: a promise resolved later by a plain thread, nothing else pending, still lands" do
      script = <<~RUBY
        require "lain"
        require "stringio"

        io = StringIO.new
        gate = Lain::Epic::Gate.new(journal: Lain::Journal.new(io:),
                                        timeout: Lain::Epic::Gate::Window::Unbounded)
        artifact = Data.define(:digest, :gate_question).new(digest: "blake3:epoll", gate_question: "Approve?")
        reader, writer = IO.pipe
        Thread.new { sleep 0.2; writer.write("go\\n") }

        asker = Object.new
        asker.define_singleton_method(:ask) do |_question|
          Lain::Promise.new.tap do |promise|
            Async::Task.current.async do
              promise.resolve(Lain::Epic::Gate::Answer.approve("human")) if reader.gets
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
      asker = Lain::Tools::AskHuman.new(parent: -> { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) })
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
      asker = Lain::Tools::AskHuman.new(parent: -> { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) })

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
    let(:store) { Lain::Dag::Factory.store }
    let(:asker) { Lain::Tools::AskHuman.new(parent: Lain::Dag::Factory.timeline(store:)) }

    def consumptions
      journal_records(journal_io, "questions_consumed")
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
        .to eq(%w[awaiting_human gate_decision questions_consumed])
    end

    # The CLI's own prompt and every standing answer write no question into any
    # record, so there is nothing for a reader to list and nothing to retire.
    it "journals no retirement for an asker whose promise names no question" do
      call(gate, asker: approve_asker)

      expect(consumptions).to be_empty
    end
  end

  # Scenario: a gate opening is journaled with its deadline
  describe "a gate that asks a human journals the wait it opens" do
    let(:opened_at) { Time.utc(2026, 11, 2, 9, 0, 0) }

    def waits = journal_records(journal_io, "awaiting_human")

    it "journals an awaiting_human of kind gate with the deadline before the answer" do
      issue = Data.define(:digest, :gate_question, :changeset)
                  .new(digest: "blake3:issue-a", gate_question: "Approve the issue_plan?", changeset: nil)
      answered = []
      asker = scripted_asker { |promise, _q| answered << promise }
      subject_gate = gate(timeout: 900, wall: -> { opened_at })

      Sync do |task|
        deciding = task.async do
          subject_gate.call(issue, asker:, stage: "issue_plan", epic_slug: "alpha", issue_id: "a")
        end
        task.yield until answered.any?
        expect(waits).to contain_exactly(
          include("kind" => "gate", "ref" => "blake3:issue-a", "deadline" => "2026-11-02T09:15:00Z",
                  "summary" => "Approve the issue_plan?", "epic_slug" => "alpha", "stage" => "issue_plan",
                  "issue_id" => "a")
        )
        expect(decisions).to be_empty
        answered.first.resolve(described_class::Answer.approve("human"))
        deciding.wait
      end

      expect(Lain::Journal.records(journal_io.string.lines).map { |record| record["type"] }.to_a)
        .to eq(%w[awaiting_human gate_decision])
    end

    it "journals a null deadline for a window only a cancellation ends" do
      call(gate(timeout: described_class::Window::Unbounded), asker: approve_asker)

      expect(waits.map { |record| record["deadline"] }).to eq([nil])
    end

    it "journals one wait per issue of a wave, each under the digest its decision closes" do
      graph = Lain::Epic::Graph.new(issues: %w[b c].map { |id| Lain::Epic::Issue.new(id:, title: "the #{id} issue") })
      views = %w[b c].map { |id| Lain::Epic::IssueView.new(issue: graph.fetch(id), graph:, authored: "") }
      wave = Lain::Epic::Submission.wave(slug: "frugirl", views:, number: 1)

      Sync { gate.call(wave, asker: approve_asker, stage: "issue_plan", epic_slug: "frugirl") }

      expect(waits.map { |record| record.values_at("ref", "issue_id") })
        .to eq(decisions.map { |record| record.values_at("artifact_digest", "issue_id") })
    end

    it "journals the waits of one wave under one question key" do
      graph = Lain::Epic::Graph.new(issues: %w[b c].map { |id| Lain::Epic::Issue.new(id:, title: "the #{id} issue") })
      views = %w[b c].map { |id| Lain::Epic::IssueView.new(issue: graph.fetch(id), graph:, authored: "") }
      wave = Lain::Epic::Submission.wave(slug: "frugirl", views:, number: 1)

      Sync { gate.call(wave, asker: approve_asker, stage: "issue_plan", epic_slug: "frugirl") }

      expect(waits.map { |record| record["question_key"] }.uniq).to contain_exactly(a_string_starting_with("blake3:"))
    end

    it "summarizes a submission's question by its first sentence, without the reply instructions" do
      submission = Lain::Epic::Submission.new(stage: "research", slug: "alpha", content_digest: "blake3:doc",
                                              fact: "research.md")

      Sync { gate.call(submission, asker: approve_asker, stage: "research", epic_slug: "alpha") }

      expect(waits.last["summary"]).to eq('Approve the research stage for "alpha"?')
    end

    it "bounds a summary whose first sentence runs long" do
      long = artifact(digest: "blake3:long", question: "#{"word " * 60}? Reply approve.")

      Sync { gate.call(long, asker: approve_asker, stage: "research", epic_slug: "alpha") }

      expect(waits.last["summary"].length).to be <= 120
      expect(waits.last["summary"]).to end_with("...")
    end

    it "journals no wait for a standing answer, which no human gives" do
      standing = Lain::Epic::Gate::Policy::StandingAnswer.new(described_class::Answer.approve("hands_off"))

      call(gate, asker: standing)

      expect(waits).to be_empty
      expect(decisions.size).to eq(1)
    end
  end

  # An answer that carries a reason of its own -- a note the human wrote, say
  # -- has that reason journaled beside the verdict, over the caller's.
  describe "an answer that carries its own reason" do
    it "journals the answer's reason over the caller's" do
      noted = described_class::Answer.new(verdict: Lain::Approval::Verdict::Deny.new(note: "wrong crate name"),
                                          surface: "human")
      asker = scripted_asker { |promise, _q| promise.resolve(noted) }

      call(gate, asker:, reason: "the caller's note")

      expect(decisions.first).to include("answered_by" => "human", "reason" => "wrong crate name")
    end

    it "journals the caller's reason when the answer carries none" do
      call(gate, asker: approve_asker, reason: "the caller's note")

      expect(decisions.first).to include("reason" => "the caller's note")
    end

    it "carries a policy's deferral, which approves nothing" do
      parked = described_class::Answer.deferred("deferred")

      expect([parked.verdict, parked.approved?]).to eq([Lain::Epic::GateDecision::Deferred.new, false])
    end

    it "keeps a carried reason frozen, so the answer stays shareable" do
      expect(described_class::Answer.new(verdict: Lain::Approval::Verdict::Deny.new(note: +"why"), surface: +"human"))
        .to be_deeply_frozen
    end
  end

  # A surface hands the gate what the human wrote, and the gate reads it
  # through the one reply grammar.
  describe "a human's words" do
    def research
      Lain::Epic::Submission.research(text: "round 2 notes", slug: "alpha")
    end

    def words_in_turn(*replies, asked: [])
      queue = replies.dup
      scripted_asker do |promise, question|
        asked << question
        promise.resolve(described_class::Said.new(words: queue.shift, surface: "human"))
      end
    end

    def decide(asker)
      Sync { gate.call(research, asker:, stage: "research", epic_slug: "alpha") }
    end

    # Scenario: an approval with a note approves
    it "approves an approval with a note, carrying the note, and records nothing as unrecognised" do
      approved = decide(words_in_turn("approve, round 2 research, re-signed unchanged"))

      expect(approved).to be(true)
      expect(decisions.map { |record| record.values_at("verdict", "answered_by", "reason") })
        .to eq([["approve", "human", "round 2 research, re-signed unchanged"]])
      expect(journal_io.string).not_to include("unrecognised")
    end

    # Scenario: an unrecognised reply asks again
    it "asks again with the reply instruction on an unrecognised reply, recording no decision for it" do
      asked = []
      approved = decide(words_in_turn("aprove", "approve", asked:))

      expect(approved).to be(true)
      expect(asked.size).to eq(2)
      expect(asked.last).to include('"aprove"', Lain::Epic::GateReply::INSTRUCTION)
      expect(decisions.map { |record| record.values_at("verdict", "answered_by") }).to eq([%w[approve human]])
    end

    it "asks again after each of 2 unreadable replies in a row" do
      asked = []
      approved = decide(words_in_turn("aprove", "lgtm", "approve", asked:))

      expect(approved).to be(true)
      expect(asked.size).to eq(3)
      expect(decisions.map { |record| record.values_at("verdict", "answered_by") }).to eq([%w[approve human]])
    end

    it "withdraws the unread question before it asks again" do
      events = []
      replies = %w[aprove approve]
      said = described_class::Said
      asker = Object.new
      asker.define_singleton_method(:ask) do |_question|
        Lain::Promise.new.tap do |promise|
          events << [:ask, promise.object_id]
          promise.resolve(said.new(words: replies.shift, surface: "human"))
        end
      end
      asker.define_singleton_method(:withdraw) { |promise| events << [:withdraw, promise.object_id] }

      decide(asker)

      first, second = events.select { _1.first == :ask }.map(&:last)
      expect(events.first(3)).to eq([[:ask, first], [:withdraw, first], [:ask, second]])
    end

    # A window that restarted at each re-ask would never close while unreadable
    # replies kept arriving inside it; here the 6th reply would approve.
    it "ends a bounded window on time while unreadable replies keep arriving" do
      asks = 0
      asker = scripted_asker do |promise, _question|
        asks += 1
        words = asks >= 6 ? "approve" : "aprove"
        Async do
          sleep 0.06
          promise.resolve(described_class::Said.new(words:, surface: "human"))
        end
      end

      approved = Sync { gate(timeout: 0.1).call(research, asker:, stage: "research", epic_slug: "alpha") }

      expect(approved).to be(false)
      expect(asks).to be < 6
      expect(decisions.map { |record| record["answered_by"] }).to eq([described_class::TIMEOUT_SURFACE])
    end

    it "decides nothing while every reply is unrecognised" do
      subject_gate = gate(timeout: 0.05)
      asks = 0
      asker = scripted_asker do |promise, _question|
        asks += 1
        promise.resolve(described_class::Said.new(words: "aprove", surface: "human")) if asks == 1
      end

      Sync { subject_gate.call(research, asker:, stage: "research", epic_slug: "alpha") }

      expect(decisions.map { |record| record["answered_by"] }).to eq([described_class::TIMEOUT_SURFACE])
    end

    it "denies on the end of input, naming nobody's answer" do
      decide(words_in_turn(nil))

      expect(decisions.map { |record| record.values_at("verdict", "answered_by") })
        .to eq([["deny", Lain::Epic::GateReply::EOF]])
    end

    it "holds on a hold word, with the words after it as the note" do
      decide(words_in_turn("hold back after lunch"))

      expect(decisions.map { |record| record.values_at("verdict", "answered_by", "reason") })
        .to eq([["hold", "human", "back after lunch"]])
      expect(decisions.first).not_to have_key("approved")
    end
  end

  # Where the partition stands is Epic::Signoff's fold of what the gate journaled, so the
  # gate's records, the sign-off queue and `lain epic status` cannot disagree on a digest.
  describe "a deny revokes" do
    def approve_then(asker, gate = self.gate(timeout: 0.02))
      Sync do
        gate.call(plan, asker: approve_asker, stage: "epic_plan", epic_slug: "lain-epics")
        gate.call(plan, asker:, stage: "epic_plan", epic_slug: "lain-epics")
      end
      gate
    end

    it "answers not approved after approve -> deny of one digest, with both decisions journaled" do
      approve_then(silent_asker)

      expect(phase_of(plan.digest)).to eq(:denied)
      expect(decisions.map { |record| record.values_at("verdict", "answered_by") })
        .to eq([%w[approve human], %w[deny timeout]])
    end

    it "keeps an approval a later hold of the same digest leaves standing" do
      held = scripted_asker do |promise, _q|
        promise.resolve(described_class::Answer.new(verdict: Lain::Approval::Verdict::Hold.new, surface: "human"))
      end
      approve_then(held)

      expect(phase_of(plan.digest)).to eq(:approved)
    end

    it "withdraws an approval once a newer draft of the partition is approved" do
      subject_gate = gate
      newer = artifact(digest: "blake3:plan-v2")
      Sync do
        subject_gate.call(plan, asker: approve_asker, stage: "epic_plan", epic_slug: "lain-epics")
        subject_gate.call(newer, asker: approve_asker, stage: "epic_plan", epic_slug: "lain-epics")
      end

      expect([phase_of(plan.digest), phase_of(newer.digest)]).to eq(%i[edited approved])
    end

    it "agrees with the sign-off queue and the stage boundary over one journal" do
      Sync do
        gate.call(artifact(digest: "blake3:r1"), asker: approve_asker, stage: "research", epic_slug: "alpha")
        gate.call(artifact(digest: "blake3:r1"), asker: deny_asker, stage: "research", epic_slug: "alpha")
      end
      queue = Lain::Epic::SignoffQueue.from_journal(journal_io.string.lines)

      expect(phase_of("blake3:r1", stage: "research", epic_slug: "alpha")).to eq(:denied)
      expect(queue.standing?("blake3:r1", "alpha", "research")).to be(false)
      expect(Lain::Epic::Stage.new("epic_plan").blocked_by(queue, epic_slug: "alpha")[:unapproved].map(&:name))
        .to eq(["research"])
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
        .to raise_error(described_class::NoReactor, /Epic::Gate.*Sync/m)
    end
  end

  # Signoff keys its partitions by stage, and every reader refuses a decision
  # journaled outside the pipeline, so the gate refuses one before anyone is asked.
  describe "a stage outside the pipeline" do
    it "refuses before asking, journaling nothing" do
      asked = []
      asker = scripted_asker do |promise, question|
        asked << question
        promise.resolve(described_class::Answer.approve("human"))
      end

      expect { call(gate, asker:, stage: "bench") }.to raise_error(Lain::Epic::UnknownStage, /bench/)
      expect(asked).to be_empty
      expect(journal_io.string).to be_empty
    end
  end

  describe "an issue-scoped decision" do
    it "journals the issue and the criteria it was handed" do
      call(gate, asker: approve_asker, stage: "issue_plan", issue_id: "a", criteria_digest: "blake3:criteria")

      expect(decisions.last).to include("stage" => "issue_plan", "issue_id" => "a",
                                        "criteria_digest" => "blake3:criteria")
    end
  end

  # One question for a wave's issue plans, and one decision per issue, each
  # under that issue's own digest so a later implementation still asks for it.
  describe "a wave" do
    def wave_graph
      Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "the a issue", blocks: %w[b c d]),
                                     *%w[b c d].map { |id| Lain::Epic::Issue.new(id:, title: "the #{id} issue") }])
    end

    def wave
      graph = wave_graph
      views = %w[b c d].map { |id| Lain::Epic::IssueView.new(issue: graph.fetch(id), graph:, authored: "") }
      Lain::Epic::Submission.wave(slug: "frugirl", views:, number: 2)
    end

    def words_asker(*replies, asked: [])
      queue = replies.dup
      scripted_asker do |promise, question|
        asked << question
        promise.resolve(described_class::Said.new(words: queue.shift, surface: "human"))
      end
    end

    def decide(*replies, subject_gate: gate, asked: [], of: wave)
      Sync do
        subject_gate.call(of, asker: words_asker(*replies, asked:), stage: "issue_plan", epic_slug: "frugirl")
      end
    end

    def verdict(kind, note = nil) = Lain::Approval::Verdict.const_get(kind).new(note:)

    def outcome_of(verdicts) = described_class::Outcome.new(verdicts:, surface: "human")

    def by_issue = decisions.to_h { |record| [record["issue_id"], record.values_at("verdict", "reason")] }

    def digest_of(id) = wave.submissions.find { |submission| submission.issue_id == id }.digest

    it "asks one question naming each issue's title, blockers and view path" do
      asked = []
      asker = scripted_asker do |promise, question|
        asked << question
        promise.resolve(described_class::Answer.approve("human"))
      end
      Sync { gate.call(wave, asker:, stage: "issue_plan", epic_slug: "frugirl") }

      expect(asked.size).to eq(1)
      expect(asked.first).to include("wave 2", '"the b issue"', '"the c issue"', '"the d issue"', "blocked by a",
                                     "lain://epic/frugirl/issues/c.md")
    end

    it "approves every issue on approve, each under its own digest" do
      subject_gate = gate
      outcome = decide("approve", subject_gate:)

      expect(outcome).to eq(outcome_of(%w[b c d].to_h { [_1, verdict(:Approve)] }))
      expect(decisions.map { |record| record.values_at("issue_id", "artifact_digest", "verdict") })
        .to eq(%w[b c d].map { |id| [id, digest_of(id), "approve"] })
      expect(%w[b c d].map { |id| phase_of(digest_of(id), stage: "issue_plan", epic_slug: "frugirl", issue_id: id) })
        .to all(eq(:approved))
    end

    # Scenario: a wave reply resolves per issue
    it "resolves a reply issue by issue, the leading bare verdict deciding every issue it does not name" do
      leaves = %w[a b c].map { |id| Lain::Epic::Issue.new(id:, title: "the #{id} issue") }
      root = Lain::Epic::Issue.new(id: "z", title: "the root", blocks: %w[a b c])
      graph = Lain::Epic::Graph.new(issues: [root, *leaves])
      views = %w[a b c].map { |id| Lain::Epic::IssueView.new(issue: graph.fetch(id), graph:, authored: "") }
      abc = Lain::Epic::Submission.wave(slug: "frugirl", views:, number: 2)

      outcome = decide("approve; deny b: wrong crate; hold c", of: abc)

      expect(outcome.verdicts).to eq("a" => verdict(:Approve), "b" => verdict(:Deny, "wrong crate"),
                                     "c" => verdict(:Hold))
      expect(decisions.map { |record| record.values_at("issue_id", "verdict", "answered_by", "reason") })
        .to eq([["a", "approve", "human", nil], ["b", "deny", "human", "wrong crate"], ["c", "hold", "human", nil]])
    end

    it "says in the reply instruction that a leading bare verdict decides every issue not named" do
      expect(wave.gate_question).to include(Lain::Epic::GateReply::WAVE_INSTRUCTION)
      expect(Lain::Epic::GateReply::WAVE_INSTRUCTION)
        .to include("approve; deny b: wrong crate; hold c", "every issue the reply does not name")
    end

    it "carries a note on a named approval" do
      outcome = decide("deny: not yet; approve c: looks right")

      expect(outcome.verdicts).to eq("b" => verdict(:Deny, "not yet"), "c" => verdict(:Approve, "looks right"),
                                     "d" => verdict(:Deny, "not yet"))
    end

    it "asks again when the reply leaves an issue undecided, and decides on the next reply" do
      asked = []
      outcome = decide("deny c: the end time is missing", "approve; deny c: the end time is missing", asked:)

      expect(asked.size).to eq(2)
      expect(asked.last).to include("b, d")
      expect(outcome.denied).to eq("c" => "the end time is missing")
      expect(by_issue).to eq("b" => ["approve", nil], "c" => ["deny", "the end time is missing"],
                             "d" => ["approve", nil])
    end

    # Scenario: a mistyped id is asked again, never read as another issue
    it "asks again when the reply names an id outside the wave, saying which" do
      asked = []
      decide("deny cc: the end time is missing", "deny", asked:)

      expect(asked.last).to include("cc is not in wave 2")
      expect(decisions.map { |record| record["verdict"] }).to eq(%w[deny deny deny])
      expect(decisions.map { |record| record["reason"] }).to all(be_nil)
    end

    {
      "a capitalised id" => "approve; deny C: y",
      "a mixed-case word" => "approve; deny Cc: y",
      "an underscored word" => "approve; deny c_d: y",
      "an issue named twice" => "approve; deny c: x; hold c",
      "2 bare verdicts" => "approve; deny",
      "an unrecognised clause" => "approve; deny c: x; approve it",
      "an unrecognised first clause" => "aprove; deny b",
      "a note naming an id in another case" => "approve; deny b: C too",
      "an approval whose note says deny" => "approve; approve b: no, deny it",
      "an approval after a deny whose note says deny" => "deny; approve b: actually deny",
      "an approval whose note says nope" => "approve; approve b: nope",
      "an approval whose note says no in fullwidth" => "approve, \uFF4E\uFF4F",
      "an approval whose note says deny in fullwidth" => "approve, \uFF44\uFF45\uFF4E\uFF59",
      "an approval whose note says rejected" => "approve; approve b: rejected",
      "an approval whose note says not ok" => "approve, not ok",
      "an approval whose note says don't" => "approve; approve b: don't ship",
      "an approval whose note says cancel" => "approve: cancel"
    }.each do |shape, reply|
      it "asks again, deciding nothing, on #{shape}" do
        asked = []
        decide(reply, "deny", asked:)

        expect(asked.size).to eq(2)
        expect(decisions.map { |record| record["verdict"] }).to eq(%w[deny deny deny])
      end
    end

    # Scenario: a bare deny denies everything
    describe "a reply that could be read 2 ways" do
      def real_wave
        root = Lain::Epic::Issue.new(id: "asr", title: "the root", blocks: %w[asr-vad asr-vad-live asr-adapter])
        leaves = %w[asr-vad asr-vad-live asr-adapter].map { |id| Lain::Epic::Issue.new(id:, title: "the #{id} issue") }
        graph = Lain::Epic::Graph.new(issues: [root, *leaves])
        views = %w[asr-vad asr-vad-live asr-adapter].map do |id|
          Lain::Epic::IssueView.new(issue: graph.fetch(id), graph:, authored: "")
        end
        Lain::Epic::Submission.wave(slug: "frugirl", views:, number: 2)
      end

      ["approve; deny asr-vad asr-vad-live", "approve; deny asr-vad, asr-vad-live",
       "approve; deny asr-vad and asr-vad-live", "approve; deny asr-vad, asr-vad-live: same bug",
       "deny asr-vad asr-vad-live; approve asr-adapter", "approve, but deny asr-vad",
       "deny: approve asr-adapter later", "approve; hold asr-vad: also deny asr-adapter",
       # 1 guard each: a note without a colon, an id in an id clause's note, a verdict word in a bare note
       "approve; deny asr-vad wrong crate", "approve; deny asr-vad: same as asr-adapter",
       "approve, but deny the rest"].each do |reply|
        it "asks again on #{reply.inspect}, recording no decision for it" do
          asked = []
          decide(reply, "deny", asked:, of: real_wave)

          expect(asked.size).to eq(2)
          expect(decisions.map { |record| record.values_at("verdict", "reason") }).to all(eq(["deny", nil]))
        end
      end

      it "decides a note after a colon on an id clause" do
        outcome = decide("approve; deny asr-vad-live: same bug", of: real_wave)

        expect(outcome.verdicts).to eq("asr-vad" => verdict(:Approve), "asr-vad-live" => verdict(:Deny, "same bug"),
                                       "asr-adapter" => verdict(:Approve))
      end
    end

    # A note after an id's colon cannot open a clause, so a verdict word in it
    # is only a word.
    {
      "approve; deny b: no tests" => { "b" => [:Deny, "no tests"] },
      "approve; deny b: stop doing that" => { "b" => [:Deny, "stop doing that"] },
      "approve; hold c: wait for review" => { "c" => [:Hold, "wait for review"] },
      "approve; deny b: n+1 query" => { "b" => [:Deny, "n+1 query"] },
      "approve; deny c: y" => { "c" => [:Deny, "y"] },
      "approve; deny b :x" => { "b" => [:Deny, "x"] },
      "approve; approve b: yes, ship it" => { "b" => [:Approve, "yes, ship it"] },
      "approve: lgtm" => %w[b c d].to_h { [_1, [:Approve, "lgtm"]] },
      "approve; approve b: ok" => { "b" => [:Approve, "ok"] }
    }.each do |reply, named|
      it "decides #{reply.inspect}, keeping the note" do
        approved = wave.ids.to_h { [_1, verdict(:Approve)] }
        expected = approved.merge(named.transform_values { |kind, note| verdict(kind, note) })

        expect(decide(reply).verdicts).to eq(expected)
      end
    end

    it "denies every issue with a bare deny's reason" do
      outcome = decide("deny: not yet")

      expect(outcome.denied).to eq("b" => "not yet", "c" => "not yet", "d" => "not yet")
      expect(by_issue.values).to all(eq(["deny", "not yet"]))
    end

    # Scenario: a semicolon inside a note is not a new clause
    it "opens a clause only at a semicolon or line that starts with a verdict word" do
      outcome = decide("approve; deny c: keep the WAV; add the end time\nhold d: rename it")

      expect(outcome.denied).to eq("c" => "keep the WAV; add the end time")
      expect(outcome.held).to eq("d" => "rename it")
      expect(outcome.approved).to eq(%w[b])
    end

    it "holds the whole wave on hold, approving and denying nothing" do
      subject_gate = gate
      outcome = decide("hold on", subject_gate:)

      expect(outcome.held).to eq(%w[b c d].to_h { [_1, "on"] })
      expect(decisions.map { |record| record.values_at("verdict", "answered_by") }).to eq([%w[hold human]] * 3)
      expect(%w[b c d].map { |id| phase_of(digest_of(id), stage: "issue_plan", epic_slug: "frugirl", issue_id: id) })
        .to all(eq(:held))
    end

    it "denies the whole wave when the window closes under the bare silence rule" do
      outcome = Sync { gate(timeout: 0.02).call(wave, asker: silent_asker, stage: "issue_plan", epic_slug: "frugirl") }

      expect(outcome.denied).to eq(%w[b c d].to_h { [_1, "timeout"] })
      expect(decisions.map { |record| record["answered_by"] }).to eq([described_class::TIMEOUT_SURFACE] * 3)
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

  describe "a call that fails journals no approval" do
    it "raises the journal's error when the journal cannot write" do
      exploding = Object.new
      exploding.define_singleton_method(:record) { |_| raise IOError, "disk full" }

      expect { call(described_class.new(journal: exploding), asker: approve_asker, stage: "research") }
        .to raise_error(IOError)
    end

    it "journals nothing when the stage check refuses the call" do
      expect { call(gate, asker: approve_asker, stage: nil) }.to raise_error(Lain::Epic::UnknownStage)
      expect(decisions).to be_empty
    end

    it "fails loudly when the artifact has no #gate_question" do
      half = Data.define(:digest).new(digest: "blake3:x")

      expect { Sync { gate.call(half, asker: approve_asker, stage: "research", epic_slug: "e") } }
        .to raise_error(NoMethodError, /gate_question/)
    end

    it "refuses a nil digest, journaling nothing" do
      nil_digest = Data.define(:digest, :gate_question).new(digest: nil, gate_question: "q?")

      expect { Sync { gate.call(nil_digest, asker: approve_asker, stage: "research", epic_slug: "e") } }
        .to raise_error(ArgumentError, /artifact_digest/)
      expect(decisions).to be_empty
    end

    it "refuses a malformed Answer rather than treating it as truthy" do
      bad = scripted_asker { |p, _q| p.resolve(described_class::Answer.new(verdict: "yes", surface: "h")) }

      expect { call(gate, asker: bad, stage: "research") }.to raise_error(ArgumentError, /verdict/)
      expect(decisions).to be_empty
    end
  end

  describe "the newest decision stands" do
    it "ends approved after deny then approve, with both journaled" do
      subject_gate = gate(timeout: 0.02)
      call(subject_gate, asker: deny_asker, stage: "research")
      call(subject_gate, asker: approve_asker, stage: "research")

      expect(phase_of(plan.digest, stage: "research")).to eq(:approved)
      expect(decisions.length).to eq(2)
    end
  end

  # The timeout rides Async's reactor clock; `latency` rides the injected one, so a
  # 0.3s window must not journal whatever the injected clock says.
  it "journals a latency consistent with the timeout window that fired" do
    ticks = [0.0, 1000.0].each

    expect(call(gate(timeout: 0.3, clock: -> { ticks.next }), asker: silent_asker, stage: "research")).to be(false)
    expect(decisions.first["answered_by"]).to eq("timeout")
    expect(decisions.first["latency"]).to be_within(0.2).of(0.3)
  end

  it "round-trips through the Journal with string keys and preserves types" do
    Sync { gate.call(plan, asker: approve_asker, stage: :epic_plan, epic_slug: :"lain-epics") }
    row = decisions.first

    expect(row.values_at("type", "stage", "epic_slug", "verdict")).to eq(%w[gate_decision epic_plan lain-epics approve])
    expect(row["latency"]).to be_a(Float)
    expect(row).to have_key("evidence_digest")
    expect(row.keys).to all(be_a(String))
  end

  # The property is the GATE's: a verdict resolved on one promise must not approve
  # the other gate's artifact. The asker is a deliberately unguarded stand-in that
  # hands out a promise per call and holds them all.
  it "does not cross-resolve when one asker serves two gates" do
    pendings = []
    shared = Object.new
    shared.define_singleton_method(:ask) { |_q| Lain::Promise.new.tap { |p| pendings << p } }
    other = artifact(digest: "blake3:other")

    results = Sync do
      first = Async { gate(timeout: 1.0).call(plan, asker: shared, stage: "research", epic_slug: "e") }
      second = Async { gate(timeout: 1.0).call(other, asker: shared, stage: "research", epic_slug: "e") }
      Async do
        Async::Task.current.sleep(0.001) until pendings.size == 2
        pendings.last&.resolve(described_class::Answer.approve("human"))
      end
      [first.wait, second.wait]
    end

    expect(results.count(true)).to eq(1)
  end

  describe Lain::Epic::GateDecision do
    def record(**overrides)
      described_class.new(artifact_digest: "blake3:abc", epic_slug: "lain-epics", stage: "epic_plan",
                          verdict: Lain::Approval::Verdict::Approve.new, answered_by: "human", policy: "interactive",
                          latency: 0.5,
                          evidence_digest: nil, **overrides)
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(record(artifact_digest: +"blake3:abc", answered_by: +"human")).to be_deeply_frozen
    end

    # Guarded rather than coerced: `to_f` would journal "answered instantly", a measurement nobody made.
    [nil, "quick", -3.0].each do |latency|
      it "refuses a latency of #{latency.inspect}" do
        expect { record(latency:) }.to raise_error(ArgumentError, /latency/)
      end
    end

    it "refuses a blank-to_s stage rather than journaling an empty partition key" do
      blank = Object.new
      blank.define_singleton_method(:to_s) { "" }

      expect { record(stage: blank) }.to raise_error(ArgumentError, /stage/)
    end

    it "is deeply frozen even with mutable inputs" do
      expect(record(epic_slug: +"e", stage: +"research", evidence_digest: +"ev")).to be_deeply_frozen
    end

    it "journals under the gate_decision discriminator" do
      expect(record.to_journal["type"]).to eq("gate_decision")
    end

    it "carries the full wire shape, evidence, reason and issue scope included" do
      expect(record(evidence_digest: "blake3:spike", reason: "researcher spawn failed").to_journal.keys)
        .to contain_exactly("type", "artifact_digest", "epic_slug", "stage", "verdict", "answered_by",
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

    it "refuses a verdict that is no verdict -- a truthy \"yes\" approves nothing" do
      expect { record(verdict: "yes") }.to raise_error(ArgumentError, /verdict/)
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

  describe Lain::Epic::Gate::Answer do
    it "is Ractor-shareable (a verdict and an interned surface String)" do
      expect(described_class.approve(+"human")).to be_deeply_frozen
    end

    it "reads its verdict through #approved?" do
      expect(described_class.approve("human").approved?).to be(true)
      expect(described_class.deny("timeout").approved?).to be(false)
    end

    it "carries the verdict it was built from, and the surface that gave it" do
      hold = Lain::Approval::Verdict::Hold.new(note: "after lunch")
      answer = described_class.new(verdict: hold, surface: "human")

      expect([answer.verdict, answer.surface]).to eq([hold, "human"])
      expect(described_class.new(verdict: Lain::Approval::Verdict::Approve.new(note: "fine"), surface: "human").verdict)
        .to eq(Lain::Approval::Verdict::Approve.new(note: "fine"))
      expect(described_class.deny("timeout").verdict).to eq(Lain::Approval::Verdict::Deny.new)
    end
  end
end
