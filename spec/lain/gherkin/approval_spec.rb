# frozen_string_literal: true

require "async"
require "stringio"

# Gherkin::Approval is the GG-1 fail-closed gate: a Criteria must pass it before
# anything generates tests from its digest. The gate asks through an
# ask_human-shaped duck, blocks on the promise with a timeout -> deny, journals
# a gherkin_approval attributed to the answering surface, and remembers the
# approved digest so a downstream refuses to consume an un-approved (or edited)
# criteria.
#
# Attribution rides the promise's resolved value (an Answer), NEVER a new meta
# key on ask_human's :message events -- so the escalation trigger (replay must
# ignore unknown meta) never fires: no meta key is added at all.
RSpec.describe Lain::Gherkin::Approval do
  # An ask_human-shaped duck: #ask returns a Promise the injected block may
  # resolve (synchronously, the degenerate sync case ask_human's gate falls out
  # of) or leave pending forever (the silence-denies path). The block receives
  # the promise and the rendered question.
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

  def silent_asker
    scripted_asker { |_promise, _q| nil }
  end

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def approvals
    Lain::Journal.records(journal_io.string.lines, type: "gherkin_approval").to_a
  end

  let(:criteria) do
    Lain::Gherkin::Criteria.parse(<<~MD)
      ```gherkin
      Scenario: adds two numbers
        Given a calculator
        When 2 and 3 are added
        Then the result is 5
      ```
    MD
  end

  # AC1
  describe "approval is content-addressed and attributed" do
    it "journals a gherkin_approval with the criteria digest, approved true, and the answering surface" do
      gate = described_class.new(journal:, clock: -> { 0.0 })

      approved = Sync { gate.call(criteria, asker: approve_asker(surface: "auto_approver")) }

      expect(approved).to be(true)
      expect(gate.approved?(criteria.digest)).to be(true)
      expect(approvals.size).to eq(1)
      record = approvals.first
      expect(record["criteria_digest"]).to eq(criteria.digest)
      expect(record["approved"]).to be(true)
      expect(record["answered_by"]).to eq("auto_approver")
    end

    it "carries the surface verbatim from the resolving Answer -- human or auto, the gate stays blind" do
      gate = described_class.new(journal:)

      Sync { gate.call(criteria, asker: approve_asker(surface: "human")) }

      expect(approvals.first["answered_by"]).to eq("human")
    end

    it "stamps the elapsed latency from the injected clock" do
      ticks = [10.0, 10.5].each
      gate = described_class.new(journal:, clock: -> { ticks.next })

      Sync { gate.call(criteria, asker: approve_asker) }

      expect(approvals.first["latency"]).to be_within(1e-9).of(0.5)
    end
  end

  # AC2
  describe "silence denies (fail-closed, signed by the clock)" do
    it "denies an unanswered gate, attributes it to timeout, and refuses generation against that digest" do
      gate = described_class.new(journal:, timeout: 0.02)

      approved = Sync { gate.call(criteria, asker: silent_asker) }

      expect(approved).to be(false)
      expect(gate.approved?(criteria.digest)).to be(false)
      record = approvals.first
      expect(record["approved"]).to be(false)
      expect(record["answered_by"]).to eq(described_class::TIMEOUT_SURFACE)

      # Generation refuses to run against the un-approved digest.
      expect { gate.ensure_approved!(criteria) }
        .to raise_error(described_class::NotApproved, /#{Regexp.escape(criteria.digest)}/)
    end
  end

  # AC3
  describe "edited criteria invalidate a prior approval" do
    let(:edited) do
      Lain::Gherkin::Criteria.parse(<<~MD)
        ```gherkin
        Scenario: adds two numbers
          Given a calculator
          When 2 and 3 are added
          Then the result is 6
        ```
      MD
    end

    it "refuses generation against the edited criteria, naming its un-approved digest" do
      gate = described_class.new(journal:)
      Sync { gate.call(criteria, asker: approve_asker) }

      # One changed clause (`is 5` -> `is 6`) is a different content address.
      expect(edited.digest).not_to eq(criteria.digest)
      expect(gate.approved?(criteria.digest)).to be(true)
      expect(gate.approved?(edited.digest)).to be(false)

      expect { gate.ensure_approved!(edited) }
        .to raise_error(described_class::NotApproved, /#{Regexp.escape(edited.digest)}/)
      # The prior approval still stands for the original text it addressed.
      expect(gate.ensure_approved!(criteria)).to eq(criteria.digest)
    end
  end

  describe "the registry is monotonic and add-only" do
    # Orchestrator decision (G2 panel): a denial NEVER revokes a prior approval
    # of the same digest. The registry is a process-local convenience answering
    # "may this be generated from"; the Journal is the audit record, and it
    # carries ALL the verdicts in order.
    it "keeps approved? true through deny -> approve -> deny while the journal shows all three verdicts" do
      gate = described_class.new(journal:, timeout: 0.02)

      Sync do
        gate.call(criteria, asker: silent_asker)   # deny (timeout)
        gate.call(criteria, asker: approve_asker)  # approve
        gate.call(criteria, asker: silent_asker)   # deny (timeout) -- does NOT revoke
      end

      expect(gate.approved?(criteria.digest)).to be(true)
      expect(gate.ensure_approved!(criteria)).to eq(criteria.digest)

      verdicts = approvals.map { |record| record.values_at("approved", "answered_by") }
      expect(verdicts).to eq([[false, "timeout"], [true, "human"], [false, "timeout"]])
    end
  end

  describe "#each -- the standing approvals, for the bench to inspect" do
    it "enumerates the digests that carry a standing approval" do
      gate = described_class.new(journal:)
      Sync { gate.call(criteria, asker: approve_asker) }

      expect(gate.to_a).to eq([criteria.digest])
    end

    it "omits a denied digest" do
      gate = described_class.new(journal:, timeout: 0.02)
      Sync { gate.call(criteria, asker: silent_asker) }

      expect(gate.to_a).to be_empty
    end
  end

  describe Lain::Telemetry::GherkinApproval do
    it "is Ractor-shareable (no reachable mutable state)" do
      record = described_class.new(criteria_digest: +"blake3:abc", approved: true,
                                   answered_by: +"auto_approver", latency: 0.5)

      expect(Ractor.shareable?(record)).to be(true)
    end

    it "journals under the gherkin_approval discriminator" do
      expect(described_class.new(criteria_digest: "blake3:abc", approved: false,
                                 answered_by: "timeout", latency: 0.02).to_journal["type"])
        .to eq("gherkin_approval")
    end

    it "refuses a nil answered_by -- a verdict always names who answered" do
      expect do
        described_class.new(criteria_digest: "blake3:abc", approved: true, answered_by: nil, latency: 0.0)
      end.to raise_error(ArgumentError, /answered_by/)
    end

    it "refuses a non-boolean approved -- presence: cannot reject false, so inclusion guards it" do
      expect do
        described_class.new(criteria_digest: "blake3:abc", approved: "yes", answered_by: "human", latency: 0.0)
      end.to raise_error(ArgumentError, /approved/)
    end
  end

  describe Lain::Gherkin::Approval::Answer do
    it "is Ractor-shareable (a boolean and an interned surface String)" do
      expect(Ractor.shareable?(described_class.approve(+"human"))).to be(true)
    end

    it "reads its verdict through #approved?" do
      expect(described_class.approve("human").approved?).to be(true)
      expect(described_class.deny("timeout").approved?).to be(false)
    end
  end
end
