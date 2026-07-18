# frozen_string_literal: true

# Grader::Refuter judges ONE finding -- is it genuine, or a false positive? --
# reusing Rubric's machinery wholesale: a fresh Request built from criteria and
# the finding alone (a SEPARATE context window, never the run-under-study's own
# Timeline), the same JSON-verdict parsing, the same mandatory #why. The one
# thing it adds over a bare Rubric is a THRESHOLD, because a refutation is
# genuinely binary while a Rubric's own #pass? is documented as unreliable for
# a continuous judge.
#
# Grader::Refuter::Recorded is the replay half: it answers journaled verdicts
# (Telemetry::Verdict records, keyed by the finding's own content digest)
# instead of judging live, so a dry replay costs no model call.
RSpec.describe Lain::Grader::Refuter do
  def judge(text)
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => text }],
                                                  stop_reason: :end_turn)
                             ])
  end

  def refuter(provider, **opts)
    described_class.new(provider:, model: "claude-opus-4-8", **opts)
  end

  describe "#refute" do
    it "returns a Grade whose #pass? is the survival verdict, above threshold" do
      grade = refuter(judge('{"score": 0.9, "why": "well-supported"}')).refute("the answer omitted the dosage")

      expect(grade.score).to eq(0.9)
      expect(grade).to be_pass
      expect(grade.why).to eq("well-supported")
    end

    it "refutes a finding scoring below threshold: #pass? is false" do
      grade = refuter(judge('{"score": 0.2, "why": "not actually supported by the evidence"}'))
              .refute("a known-false finding")

      expect(grade).not_to be_pass
      expect(grade.score).to eq(0.2)
    end

    it "judges in a SEPARATE context window: the request carries only criteria + the finding" do
      provider = judge('{"score": 1.0, "why": "ok"}')
      refuter(provider).refute("the finding text")

      request = provider.last_request
      expect(request.messages.map { |m| m["content"] }.join).to include("the finding text")
      expect(Array(request.system).map { |b| b.is_a?(Hash) ? b["text"] : b }.join).to include("false positive")
    end

    it "requires an explanation: a blank #why is a loud failure, same as Rubric" do
      expect { refuter(judge('{"score": 0.5, "why": ""}')).refute("x") }
        .to raise_error(ArgumentError, /explain/)
    end

    it "accepts a custom threshold" do
      grade = refuter(judge('{"score": 0.6, "why": "borderline"}'), threshold: 0.7).refute("x")
      expect(grade).not_to be_pass

      grade = refuter(judge('{"score": 0.6, "why": "borderline"}'), threshold: 0.5).refute("x")
      expect(grade).to be_pass
    end
  end

  describe Lain::Grader::Refuter::Recorded do
    let(:journal_lines) do
      [
        { "type" => "verdict", "digest" => Lain::Canonical.digest("finding one"),
          "survived" => true, "score" => 0.9, "why" => "genuine" }.to_json,
        { "type" => "verdict", "digest" => Lain::Canonical.digest("finding two"),
          "survived" => false, "score" => 0.1, "why" => "false positive" }.to_json
      ]
    end

    it "replays the recorded verdict verbatim, with no provider involved at all" do
      recorded = described_class.from_journal(journal_lines)

      survivor = recorded.refute("finding one")
      expect(survivor.score).to eq(0.9)
      expect(survivor.why).to eq("genuine")
      expect(survivor).to be_pass

      refuted = recorded.refute("finding two")
      expect(refuted.score).to eq(0.1)
      expect(refuted).not_to be_pass
    end

    it "raises loudly for a finding with no recorded verdict, rather than inventing one" do
      recorded = described_class.from_journal(journal_lines)

      expect { recorded.refute("never seen this finding before") }
        .to raise_error(described_class::Unrecorded)
    end

    it "skips foreign journal lines and narrows to verdict records only" do
      lines = journal_lines + ['{"type": "turn_usage", "digest": "d"}', "not even json"]
      recorded = described_class.from_journal(lines)

      expect(recorded.refute("finding one")).to be_pass
    end
  end
end
