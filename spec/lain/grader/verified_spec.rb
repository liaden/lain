# frozen_string_literal: true

require "stringio"

# Grader::Verified decorates a FINDING-PRODUCING grader (one whose #grade
# answers an Enumerable of raw findings, not a single Grade -- distinct from
# the Fixture/Recall/Rubric scalar convention) with a second refutation pass:
# each raw finding goes to an injected refuter, in a separate context, and
# only survivors come back out, each carrying the Grade that verified it.
#
# Every refutation journals as a Telemetry::Verdict, keyed by the finding's own
# content digest -- which is what lets Grader::Refuter::Recorded replay the
# exact filtered set later with no model call.
RSpec.describe Lain::Grader::Verified do
  # A minimal finding-producing grader test double: #grade answers whatever raw
  # findings it was built with, ignoring the subject -- the shape Verified is
  # generic over, per the card's note that no shipped grader emits multiple
  # findings today. A method rather than a top-level constant, so the double
  # stays local to this file instead of leaking a class into the global spec
  # namespace (Lint/ConstantDefinitionInBlock).
  def finding_grader(findings)
    Struct.new(:findings) { def grade(_subject) = findings }.new(findings)
  end

  def judge(*texts)
    responses = texts.map do |text|
      Lain::Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn)
    end
    Lain::Provider::Mock.new(responses:)
  end

  def refuter(provider)
    Lain::Grader::Refuter.new(provider:, model: "claude-opus-4-8")
  end

  describe "#grade" do
    it "filters false positives: fewer than N findings come back, each carrying its verdict" do
      inner = finding_grader(["genuinely missing the allergy warning",
                              "a known-false finding",
                              "genuinely wrong dosage units"])
      provider = judge(
        '{"score": 0.9, "why": "confirmed by the transcript"}',
        '{"score": 0.1, "why": "not actually present in the transcript"}',
        '{"score": 0.85, "why": "confirmed by the transcript"}'
      )

      verified = described_class.new(inner:, refuter: refuter(provider))
      survivors = verified.grade("some subject")

      expect(survivors.size).to eq(2)
      expect(survivors).to all(be_a(described_class::Finding))
      expect(survivors.map(&:finding)).to contain_exactly(
        "genuinely missing the allergy warning", "genuinely wrong dosage units"
      )
      expect(survivors.map { |s| s.grade.why }).to all(eq("confirmed by the transcript"))
    end

    it "journals a Verdict for EVERY finding, refuted or not" do
      inner = finding_grader(%w[keep drop])
      provider = judge(
        '{"score": 0.9, "why": "kept"}',
        '{"score": 0.1, "why": "dropped"}'
      )
      journal = []

      described_class.new(inner:, refuter: refuter(provider), journal:).grade("subject")

      expect(journal.size).to eq(2)
      expect(journal).to all(be_a(Lain::Telemetry::Verdict))
      expect(journal.map(&:survived)).to eq([true, false])
      expect(journal.map(&:digest)).to eq([Lain::Canonical.digest("keep"), Lain::Canonical.digest("drop")])
    end

    it "defaults to the Null journal, so no caller has to guard `if journal`" do
      inner = finding_grader(["one finding"])
      provider = judge('{"score": 0.9, "why": "kept"}')

      expect { described_class.new(inner:, refuter: refuter(provider)).grade("subject") }.not_to raise_error
    end
  end

  describe "replay: verdicts journaled from a live grading reproduce the filtered set with no model call" do
    it "reproduces the exact same survivors byte-identically via Refuter::Recorded" do
      findings = ["genuinely missing the allergy warning", "a known-false finding", "genuinely wrong dosage units"]
      inner = finding_grader(findings)
      live_provider = judge(
        '{"score": 0.9, "why": "confirmed by the transcript"}',
        '{"score": 0.1, "why": "not actually present in the transcript"}',
        '{"score": 0.85, "why": "confirmed by the transcript"}'
      )

      io = StringIO.new
      real_journal = Lain::Journal.new(io:)
      live_survivors = described_class.new(inner:, refuter: refuter(live_provider), journal: real_journal)
                                      .grade("subject")

      # Replay: rebuild a refuter purely from the journaled bytes. No Provider
      # is even constructed on this side -- there is nothing for it to call.
      recorded_refuter = Lain::Grader::Refuter::Recorded.from_journal(io.string.each_line)
      replayed_survivors = described_class.new(inner: finding_grader(findings), refuter: recorded_refuter)
                                          .grade("subject")

      expect(replayed_survivors.map(&:finding)).to eq(live_survivors.map(&:finding))
      expect(replayed_survivors.map { |s| s.grade.score }).to eq(live_survivors.map { |s| s.grade.score })
      expect(replayed_survivors.map { |s| s.grade.why }).to eq(live_survivors.map { |s| s.grade.why })
      expect(replayed_survivors.size).to eq(2)
    end

    # Regression (panel review): two findings with IDENTICAL text but DIFFERENT
    # live verdicts share one Canonical digest -- there is nothing else to key
    # on, since a finding carries no id. A lookup that OVERWRITES by digest
    # collapses both journal lines into the last one written, so replay would
    # score the surviving duplicate as refuted (or vice versa). The fix
    # consumes same-digest journal entries in the order they were written
    # (FIFO), matching the order `Verified#grade` produced them in.
    it "reproduces the same survivor set on replay even when two findings share identical text" do
      findings = ["duplicate finding", "duplicate finding"]
      inner = finding_grader(findings)
      live_provider = judge(
        '{"score": 0.9, "why": "the first occurrence checks out"}',
        '{"score": 0.1, "why": "the second occurrence does not"}'
      )

      io = StringIO.new
      live_survivors = described_class.new(inner:, refuter: refuter(live_provider), journal: Lain::Journal.new(io:))
                                      .grade("subject")

      recorded_refuter = Lain::Grader::Refuter::Recorded.from_journal(io.string.each_line)
      replayed_survivors = described_class.new(inner: finding_grader(findings), refuter: recorded_refuter)
                                          .grade("subject")

      expect(live_survivors.size).to eq(1)
      expect(replayed_survivors.size).to eq(live_survivors.size)
      expect(replayed_survivors.map { |s| s.grade.why }).to eq(live_survivors.map { |s| s.grade.why })
    end
  end

  describe Lain::Grader::Verified::Finding do
    it "deep-freezes the wrapped finding, so the whole value is Ractor.shareable?" do
      inner = finding_grader([+"a mutable finding string"])
      finding = Lain::Grader::Verified.new(inner:, refuter: refuter(judge('{"score": 1.0, "why": "ok"}')))
                                      .grade("subject").first

      expect(finding.finding).to be_frozen
      expect(Ractor.shareable?(finding)).to be(true)
    end
  end
end
