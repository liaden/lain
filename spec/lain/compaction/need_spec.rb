# frozen_string_literal: true

RSpec.describe Lain::Compaction::Need do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, body)
    { "role" => role, "content" => text(body) }
  end

  subject(:need) { described_class.new(byte_threshold: 100, window_tokens: 1000, approaching_ratio: 0.9) }

  # Scenario: Each need-signal raises the flag without compacting
  describe "the token-threshold signal" do
    it "raises the need flag once the candidate messages cross the byte-length proxy" do
      result = need.check(messages: [message("user", "a" * 200)])

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:token_threshold)
    end

    it "does not raise the flag under threshold" do
      result = need.check(messages: [message("user", "a")])

      expect(result.needed?).to be(false)
      expect(result.signals).not_to include(:token_threshold)
    end
  end

  describe "the approaching-window signal" do
    it "raises the need flag once used tokens cross the ratio of the window" do
      result = need.check(used_tokens: 950)

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:approaching_window)
    end

    it "does not raise the flag comfortably below the window" do
      result = need.check(used_tokens: 10)

      expect(result.needed?).to be(false)
      expect(result.signals).not_to include(:approaching_window)
    end

    it "does not raise the flag when usage is unknown (nil)" do
      result = need.check(used_tokens: nil)

      expect(result.signals).not_to include(:approaching_window)
    end
  end

  describe "the manual signal" do
    it "raises the need flag on an explicit manual trigger" do
      result = need.check(manual: true)

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:manual)
    end

    it "does not raise the flag without one" do
      result = need.check(manual: false)

      expect(result.signals).not_to include(:manual)
    end
  end

  describe "the plan-step-completion signal" do
    # Scenario: A completed todo raises the need flag
    it "raises the need flag when handed a completed plan-step signal" do
      result = need.check(plan_step_completed: true)

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:plan_step_completion)
    end

    it "does not raise the flag without one" do
      result = need.check(plan_step_completed: false)

      expect(result.signals).not_to include(:plan_step_completion)
    end
  end

  it "raises no flag when nothing fires" do
    result = need.check

    expect(result.needed?).to be(false)
    expect(result.signals).to eq([])
  end

  it "collects every signal that fires, not just the first" do
    result = need.check(messages: [message("user", "a" * 200)], manual: true, plan_step_completed: true)

    expect(result.signals).to contain_exactly(:token_threshold, :manual, :plan_step_completion)
  end

  # "no compaction runs": Need's Result carries only which signals fired, never
  # rewritten content -- there is no summarizer collaborator anywhere in this
  # object for a signal to reach, so raising a flag structurally cannot also
  # execute a rewrite.
  it "never summarizes or rewrites -- the result carries flags, not content" do
    result = need.check(messages: [message("user", "a" * 200)], manual: true)

    expect(result).to respond_to(:signals)
    expect(result).not_to respond_to(:messages)
    expect(need).not_to respond_to(:call)
  end

  # CLAUDE.md: value objects are deeply frozen, and a magnus-wrapped or
  # plain-Ruby collaborator is not Ractor-shareable "for free" -- it broke
  # once elsewhere (Symbol#to_s/interpolation returning a mutable String).
  # `need` itself already covers its four nested detectors transitively (
  # `be_deeply_frozen` walks ivars), but each detector is pinned on its own
  # too: a future refactor that replaces one detector's #initialize (as one
  # already did here -- Manual/PlanStepCompletion had no custom #initialize
  # and were not frozen by default even inside a frozen @detectors Array,
  # since Array#freeze is shallow) should fail at THAT detector, not just
  # at the top level.
  describe "shareability" do
    it "is deeply frozen and Ractor-shareable" do
      expect(need).to be_deeply_frozen
      expect(need).to be_ractor_shareable
    end

    it "produces a deeply frozen, Ractor-shareable Result" do
      result = need.check(messages: [message("user", "a" * 200)], manual: true, plan_step_completed: true)

      expect(result).to be_deeply_frozen
      expect(result).to be_ractor_shareable
    end

    it "keeps every detector collaborator deeply frozen and Ractor-shareable" do
      detectors = need.instance_variable_get(:@detectors)

      expect(detectors).not_to be_empty
      detectors.each do |detector|
        expect(detector).to be_deeply_frozen
        expect(detector).to be_ractor_shareable
      end
    end
  end
end
