# frozen_string_literal: true

require "stringio"

# Approval::Gate is the artifact gate: any artifact answering #digest and
# #gate_question must pass it before an irreversible action consumes that
# digest. It is Gherkin::Approval's shape generalized off Criteria -- ask
# through an ask_human-shaped duck, block on the promise with a timeout ->
# deny, journal a gate_decision attributed to the answering surface, and
# remember the approved digest so ensure_approved! refuses loudly otherwise.
#
# T5 ships only the asker-delegating path; `policy:` is carried onto the record
# as a label so a later card's policies (hands_off, deferred) wrap this one
# without ever widening the durable wire shape.
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

  # AC1
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

  # AC2
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

  # AC3
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

  describe Lain::Approval::GateDecision do
    def record(**overrides)
      described_class.new(artifact_digest: "blake3:abc", epic_slug: "lain-epics", stage: "epic_plan",
                          approved: true, answered_by: "human", policy: "interactive", latency: 0.5,
                          evidence_digest: nil, **overrides)
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(Ractor.shareable?(record(artifact_digest: +"blake3:abc", answered_by: +"human"))).to be(true)
    end

    it "journals under the gate_decision discriminator" do
      expect(record.to_journal["type"]).to eq("gate_decision")
    end

    it "carries the full wire shape on day one, evidence_digest and reason included" do
      expect(record(evidence_digest: "blake3:spike", reason: "researcher spawn failed").to_journal.keys)
        .to contain_exactly("type", "artifact_digest", "epic_slug", "stage", "approved", "answered_by",
                            "policy", "latency", "evidence_digest", "reason")
    end

    # The rationale field: nullable like evidence_digest, and for the same
    # reason -- a shape a later card can populate but must never widen.
    it "defaults reason to nil, so a verdict with no rationale journals one" do
      expect(record.to_journal).to include("reason" => nil)
    end

    it "keeps a supplied reason frozen, so the record stays shareable" do
      decision = record(reason: +"researcher spawn failed -- parked without evidence")

      expect(Ractor.shareable?(decision)).to be(true)
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
      expect(Ractor.shareable?(described_class.approve(+"human"))).to be(true)
    end

    it "reads its verdict through #approved?" do
      expect(described_class.approve("human").approved?).to be(true)
      expect(described_class.deny("timeout").approved?).to be(false)
    end
  end
end
