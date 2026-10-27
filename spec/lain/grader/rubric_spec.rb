# frozen_string_literal: true

# Grader::Rubric is an LLM judge that scores a subject against explicit criteria
# in a SEPARATE context window -- a fresh Request built only from the rubric and
# the thing being judged, never the run-under-study's own timeline. Its `#why`
# is mandatory: an unexplainable judgment is unusable, so a blank explanation is
# a loud failure, not a silent 0.
#
# The mechanics run offline through Provider::Mock, which never touches the
# network, so these examples are safe untagged. The one real-API example is
# :live-tagged and skipped by default.
RSpec.describe Lain::Grader::Rubric do
  def judge(text)
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => text }],
                                                  stop_reason: :end_turn)
                             ])
  end

  def rubric(provider)
    described_class.new(criteria: "Answer must name the capital of France.",
                        provider:, model: "claude-opus-4-8")
  end

  it "parses a JSON verdict into a Grade with score and explanation" do
    grade = rubric(judge('{"score": 0.9, "why": "Correctly says Paris."}')).grade("The capital is Paris.")

    expect(grade.score).to eq(0.9)
    expect(grade.why).to eq("Correctly says Paris.")
  end

  it "judges in a SEPARATE context window: the request carries only rubric + subject" do
    provider = judge('{"score": 1.0, "why": "ok"}')
    rubric(provider).grade("Paris.")

    request = provider.last_request
    expect(request.messages.map { |m| m["content"] }.join).to include("Paris.")
    expect(Array(request.system).map { |b| b.is_a?(Hash) ? b["text"] : b }.join)
      .to include("capital of France")
  end

  it "requires an explanation: a blank #why is a loud failure" do
    expect { rubric(judge('{"score": 0.5, "why": ""}')).grade("Lyon.") }
      .to raise_error(ArgumentError, /explain/)
  end

  it "does not treat a high-but-continuous score as a pass -- callers threshold #score" do
    # Pinning the documented contract: #pass? carries Grade's default (>= 1.0),
    # which a continuous judge almost never returns, so it is NOT the verdict.
    grade = rubric(judge('{"score": 0.95, "why": "excellent but not perfect"}')).grade("Paris.")

    expect(grade).not_to be_pass
    expect(grade.score).to be >= 0.8 # the caller's own threshold is where a decision lives
  end

  it "clamps an out-of-range score into 0.0..1.0" do
    grade = rubric(judge('{"score": 4, "why": "overzealous judge"}')).grade("Paris.")
    expect(grade.score).to eq(1.0)
  end

  it "extracts the verdict even when the judge wraps it in prose" do
    wrapped = 'Here is my assessment: {"score": 0.7, "why": "mostly right"} -- done.'
    grade = rubric(judge(wrapped)).grade("Paris, probably.")
    expect(grade.score).to eq(0.7)
    expect(grade.why).to eq("mostly right")
  end

  it "raises rather than fabricating a score when the judge is unparseable" do
    expect { rubric(judge("I cannot comply.")).grade("Paris.") }
      .to raise_error(described_class::Unparseable)
  end

  describe "against the real API", :live do
    it "returns a score and a real explanation" do
      require "lain/provider/anthropic"

      grade = described_class.new(
        criteria: "The answer must state that the capital of France is Paris.",
        provider: Lain::Provider::AnthropicReference.new,
        model: "claude-opus-4-8"
      ).grade("The capital of France is Paris.")

      expect(grade.score).to be_between(0.0, 1.0)
      expect(grade.why).not_to be_empty
    end
  end

  describe "scale" do
    def system_text(provider) = Array(provider.last_request.system).map { |b| b.is_a?(Hash) ? b["text"] : b }.join

    def scaled(text, scale) = described_class.new(criteria: "c", provider: judge(text), model: "m", scale:)

    it "sends today's prompt byte for byte when built with no scale" do
      provider = judge('{"score": 1, "why": "ok"}')
      described_class.new(criteria: "c", provider:, model: "m").grade("x")

      expect(system_text(provider)).to eq(
        "You are a strict grader. Score how well the answer below satisfies the criteria.\n" \
        "Reply with ONE JSON object and nothing else:\n" \
        "{\"score\": <number between 0 and 1>, \"why\": \"<one sentence explaining the score>\"}\n" \
        "\n\nCriteria:\nc"
      )
    end

    it "sends the scale's own instruction when one is named" do
      provider = judge('{"verdict": "holds", "why": "ok"}')
      described_class.new(criteria: "c", provider:, model: "m", scale: :binary).grade("x")

      expect(system_text(provider)).to start_with(Lain::Grader::Rubric::Scale.fetch(:binary).instruction)
    end

    it "scores a binary holds 1.0 and fails 0.0, and refuses a number" do
      expect(scaled('{"verdict": "holds", "why": "ok"}', :binary).grade("x").score).to eq(1.0)
      expect(scaled('{"verdict": "fails", "why": "no"}', :binary).grade("x").score).to eq(0.0)
      expect do
        scaled('{"verdict": 0.8, "why": "no"}', :binary).grade("x")
      end.to raise_error(described_class::Unparseable)
    end

    it "scores a three-level unsure 0.5" do
      expect(scaled('{"verdict": "unsure", "why": "hm"}', :three).grade("x").score).to eq(0.5)
    end

    it "scores two defects 0.5 and names both" do
      grade = scaled('{"defects": ["no evidence", "wrong file"]}', :deduction).grade("x")

      expect(grade.score).to eq(0.5)
      expect(grade.why).to include("no evidence", "wrong file")
    end
  end
end
