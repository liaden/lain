# frozen_string_literal: true

# T5 review probes -- adversarial, written by the panel. Each example names the
# seam it attacks; failures here are candidate specs for the fix round.
require "stringio"

RSpec.describe "T5 probes: Lain::Approval::Gate" do
  let(:gate_class) { Lain::Approval::Gate }

  def scripted_asker(&resolver)
    Object.new.tap do |asker|
      asker.define_singleton_method(:ask) do |question|
        Lain::Promise.new.tap { |promise| resolver&.call(promise, question) }
      end
    end
  end

  def approve_asker(surface: "human")
    scripted_asker { |promise, _q| promise.resolve(gate_class::Answer.approve(surface)) }
  end

  def artifact(digest: "blake3:plan", question: "Approve? reply approve or deny.")
    Data.define(:digest, :gate_question).new(digest:, gate_question: question)
  end

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:plan) { artifact }

  def decisions
    Lain::Journal.records(journal_io.string.lines, type: "gate_decision").to_a
  end

  # ---- P1: does the gate fail CLOSED when the journal write raises? ----
  describe "P1 journal failure" do
    it "does not leave a standing approval when the journal raises" do
      exploding = Object.new
      exploding.define_singleton_method(:record) { |_| raise IOError, "disk full" }
      subject_gate = gate_class.new(journal: exploding)

      expect { Sync { subject_gate.call(plan, asker: approve_asker, stage: "s", epic_slug: "e") } }
        .to raise_error(IOError)
      expect(subject_gate.approved?(plan.digest)).to be(false)
      expect { subject_gate.ensure_approved!(plan) }.to raise_error(gate_class::NotApproved)
    end

    it "does not leave a standing approval when the record guard rejects the call args" do
      subject_gate = gate_class.new(journal:)

      expect { Sync { subject_gate.call(plan, asker: approve_asker, stage: nil, epic_slug: "e") } }
        .to raise_error(ArgumentError, /stage/)
      expect(subject_gate.approved?(plan.digest)).to be(false)
    end
  end

  # ---- P2: monotonicity direction ----
  describe "P2 monotonicity direction" do
    it "deny-then-approve ends approved (add-only, as documented)" do
      subject_gate = gate_class.new(journal:, timeout: 0.02)
      Sync do
        subject_gate.call(plan, asker: scripted_asker { |p, _| p.resolve(gate_class::Answer.deny("human")) },
                                stage: "s", epic_slug: "e")
        subject_gate.call(plan, asker: approve_asker, stage: "s", epic_slug: "e")
      end
      expect(subject_gate.approved?(plan.digest)).to be(true)
      expect(decisions.length).to eq(2)
    end
  end

  # ---- P3: artifact duck failures ----
  describe "P3 artifact duck" do
    it "fails loudly when the artifact has no #gate_question" do
      half = Data.define(:digest).new(digest: "blake3:x")
      expect { Sync { gate_class.new(journal:).call(half, asker: approve_asker, stage: "s", epic_slug: "e") } }
        .to raise_error(NoMethodError, /gate_question/)
    end

    it "refuses to register a nil digest as approved" do
      nil_digest = Data.define(:digest, :gate_question).new(digest: nil, gate_question: "q?")
      subject_gate = gate_class.new(journal:)
      expect { Sync { subject_gate.call(nil_digest, asker: approve_asker, stage: "s", epic_slug: "e") } }
        .to raise_error(ArgumentError, /artifact_digest/)
      expect(subject_gate.approved?(nil)).to be(false)
    end
  end

  # ---- P4: timeout clock -- injected or wall? ----
  describe "P4 timeout clock" do
    # The timeout rides Async's reactor clock; `latency` rides the injected one.
    # Two clocks, no relationship: a 0.3s window journals whatever the injected
    # clock says, so the record can claim 1000s for a 0.3s timeout.
    it "journals a latency consistent with the timeout window that fired" do
      ticks = [0.0, 1000.0].each
      subject_gate = gate_class.new(journal:, timeout: 0.3, clock: -> { ticks.next })
      approved = Sync do
        subject_gate.call(plan, asker: scripted_asker { |_p, _q| nil }, stage: "s", epic_slug: "e")
      end
      expect(approved).to be(false)
      expect(decisions.first["answered_by"]).to eq("timeout")
      expect(decisions.first["latency"]).to be_within(0.2).of(0.3)
    end
  end

  # ---- P4b: a malformed Answer from an untrusted surface ----
  describe "P4b Answer has no construction guard" do
    it "refuses a non-boolean verdict rather than treating it as truthy" do
      expect { gate_class::Answer.new(approved: "yes", surface: "human") }
        .to raise_error(ArgumentError, /approved/)
    end

    it "does not register an approval from a malformed Answer" do
      bad = scripted_asker { |p, _q| p.resolve(gate_class::Answer.new(approved: "yes", surface: "h")) }
      subject_gate = gate_class.new(journal:)
      Sync { subject_gate.call(plan, asker: bad, stage: "s", epic_slug: "e") }
    rescue ArgumentError
      expect(subject_gate.approved?(plan.digest)).to be(false)
    end
  end

  # ---- P5: latency typing ----
  describe "P5 latency" do
    it "refuses a nil latency rather than silently journaling 0.0" do
      expect do
        Lain::Approval::GateDecision.new(artifact_digest: "d", epic_slug: "e", stage: "s", approved: true,
                                         answered_by: "human", policy: "interactive", latency: nil)
      end.to raise_error(ArgumentError, /latency/)
    end

    it "refuses a non-numeric latency rather than coercing it to 0.0" do
      expect do
        Lain::Approval::GateDecision.new(artifact_digest: "d", epic_slug: "e", stage: "s", approved: true,
                                         answered_by: "human", policy: "interactive", latency: "quick")
      end.to raise_error(ArgumentError, /latency/)
    end

    it "refuses a negative latency" do
      expect do
        Lain::Approval::GateDecision.new(artifact_digest: "d", epic_slug: "e", stage: "s", approved: true,
                                         answered_by: "human", policy: "interactive", latency: -3.0)
      end.to raise_error(ArgumentError, /latency/)
    end
  end

  # ---- P6: wire shape round trip ----
  describe "P6 wire shape" do
    it "round-trips through the Journal with string keys and preserves types" do
      Sync { gate_class.new(journal:).call(plan, asker: approve_asker, stage: :epic_plan, epic_slug: :"lain-epics") }
      row = decisions.first
      expect(row["type"]).to eq("gate_decision")
      expect(row["stage"]).to eq("epic_plan")
      expect(row["epic_slug"]).to eq("lain-epics")
      expect(row["approved"]).to be(true).or be(false)
      expect(row["latency"]).to be_a(Float)
      expect(row).to have_key("evidence_digest")
      expect(row.keys).to all(be_a(String))
    end

    # Probe as written asserted the DEFECT (a blank-to_s stage journaling ""),
    # which the orchestrator ruled against: the guard must check the STRINGIFIED
    # value, so this can never be journaled at all. Same seam, expectation moved
    # to the ruled behaviour -- refusal, not a present-but-empty partition key.
    it "refuses a blank-to_s stage rather than journaling an empty partition key" do
      blank = Object.new
      blank.define_singleton_method(:to_s) { "" }

      expect do
        Lain::Approval::GateDecision.new(artifact_digest: "d", epic_slug: "e", stage: blank, approved: true,
                                         answered_by: "human", policy: "p", latency: 0.1)
      end.to raise_error(ArgumentError, /stage/)
    end
  end

  # ---- P7: shared asker ----
  describe "P7 two gates, one asker" do
    it "does not silently cross-resolve when one AskHuman-shaped asker serves two gates" do
      pendings = []
      shared = Object.new
      shared.define_singleton_method(:ask) do |_q|
        Lain::Promise.new.tap { |p| pendings << p } # last-write-wins, AskHuman's shape
      end
      a = gate_class.new(journal:, timeout: 0.05)
      b = gate_class.new(journal:, timeout: 0.05)
      other = artifact(digest: "blake3:other")

      results = Sync do
        t1 = Async { a.call(plan, asker: shared, stage: "s", epic_slug: "e") }
        t2 = Async { b.call(other, asker: shared, stage: "s", epic_slug: "e") }
        Async do
          Async::Task.current.sleep(0.01)
          pendings.last&.resolve(gate_class::Answer.approve("human"))
        end
        [t1.wait, t2.wait]
      end
      # The reply lands on ONE promise; the other must NOT be approved.
      expect(results.count(true)).to eq(1)
      expect(a.approved?(plan.digest) && b.approved?(other.digest)).to be(false)
    end
  end

  # ---- P8: Ractor / freezing ----
  describe "P8 immutability" do
    it "GateDecision is deeply frozen even with mutable inputs" do
      rec = Lain::Approval::GateDecision.new(artifact_digest: +"d", epic_slug: +"e", stage: +"s", approved: false,
                                             answered_by: +"timeout", policy: +"interactive", latency: 1.0,
                                             evidence_digest: +"ev")
      expect(Ractor.shareable?(rec)).to be(true)
      expect(rec.evidence_digest).to be_frozen
    end

    it "does not mutate a frozen digest argument" do
      frozen = "blake3:frozen"
      rec = Lain::Approval::GateDecision.new(artifact_digest: frozen, epic_slug: "e", stage: "s", approved: true,
                                             answered_by: "h", policy: "p", latency: 1.0)
      expect(rec.artifact_digest).to eq(frozen)
    end
  end

  # ---- P9: reactor precondition ----
  describe "P9 outside a reactor" do
    it "names the missing reactor rather than raising a bare NoMethodError" do
      expect { gate_class.new(journal:).call(plan, asker: approve_asker, stage: "s", epic_slug: "e") }
        .to raise_error(/reactor|Async|task/i)
    end
  end
end
