# frozen_string_literal: true

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
