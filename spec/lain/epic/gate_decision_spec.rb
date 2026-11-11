# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Epic::GateDecision do
  verdicts = Lain::Approval::Verdict

  def decision(verdict, policy: "signoff")
    described_class.new(artifact_digest: "blake3:plan", epic_slug: "alpha", stage: "epic_plan", verdict:,
                        answered_by: policy, policy:, latency: 0.1)
  end

  describe "the deferred verdict" do
    it "is deferred, and neither approved, held nor denied" do
      deferred = described_class::Deferred.new(note: "unsure")

      expect([deferred.deferred?, deferred.approved?, deferred.held?, deferred.denied?, deferred.note])
        .to eq([true, false, false, false, "unsure"])
    end

    it "refuses a note that is not a String, by the rule every verdict's note follows" do
      expect { described_class::Deferred.new(note: 5) }.to raise_error(ArgumentError, /note must be a String or nil/)
    end
  end

  describe ".coerce" do
    it "returns each of approve, hold, deny and deferred as given" do
      given = [verdicts::Approve.new, verdicts::Hold.new, verdicts::Deny.new, described_class::Deferred.new]

      expect(given.map { described_class.coerce(_1) }).to eq(given)
    end

    it "refuses a word, a boolean or a symbol" do
      ["deferred", true, :deny].each do |value|
        expect { described_class.coerce(value) }.to raise_error(ArgumentError, /not a gate verdict/)
      end
    end
  end

  describe "the journaled verdict" do
    it "keeps a deny under the deferred policy a deny, since a verdict is never read off its policy" do
      expect(decision(verdicts::Deny.new(note: "doubt"), policy: "deferred").to_journal)
        .to include("verdict" => "deny", "reason" => "doubt", "policy" => "deferred")
    end

    it "says deferred for a deferred verdict handed over as one" do
      expect(decision(described_class::Deferred.new).to_journal).to include("verdict" => "deferred")
    end

    it "reads a deferred record back as the deferred verdict, its reason as the note" do
      record = decision(described_class::Deferred.new(note: "later")).to_journal

      expect(described_class.verdict_in(record)).to eq(described_class::Deferred.new(note: "later"))
    end

    it "refuses a record carrying only the old approved boolean, naming no rewrite command" do
      record = decision(verdicts::Deny.new).to_journal.except("verdict").merge("approved" => false)

      expect { described_class.verdict_in(record) }.to raise_error(ArgumentError) { |error|
        expect(error.message).to include("verdict must be one of approve, hold, deny, deferred")
        expect(error.message).not_to include("rewrite")
      }
    end
  end

  describe "a gate with policy deferred" do
    it "journals the parked submission's verdict as deferred" do
      io = StringIO.new
      journal = Lain::Journal.new(io:)
      queue = Lain::Epic::SignoffQueue.new
      policy = Lain::Epic::Gate::Policy::Deferred.new(queue:, digests: nil, journal:)
      plan = Data.define(:digest, :gate_question).new(digest: "blake3:plan", gate_question: "Approve the research?")
      gate = Lain::Epic::Gate.new(journal:, timeout: 0.5)

      Sync { policy.decide(plan, gate:, stage: "research", epic_slug: "alpha") }

      expect(journal_records(io, "gate_decision")).to contain_exactly(include("verdict" => "deferred"))
      expect(Lain::Epic::SignoffQueue.from_journal(io.string.lines).parked("alpha", "research").map(&:artifact_digest))
        .to eq(["blake3:plan"])
    end
  end
end
