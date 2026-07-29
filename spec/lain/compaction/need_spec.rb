# frozen_string_literal: true

RSpec.describe Lain::Compaction::Need do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, body)
    { "role" => role, "content" => text(body) }
  end

  subject(:need) { described_class.new(byte_threshold: 100, approaching_ratio: 0.9) }

  # The window is a per-check PARAMETER, not construction state (it follows the
  # turn's live model), so every example here supplies one. 1000 is the window
  # the approaching-window examples below are sized against.
  def check(window_tokens: 1000, **state) = need.check(window_tokens:, **state)

  # Scenario: Each need-signal raises the flag without compacting
  describe "the token-threshold signal" do
    it "raises the need flag once the candidate messages cross the byte-length proxy" do
      result = check(messages: [message("user", "a" * 200)])

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:token_threshold)
    end

    it "does not raise the flag under threshold" do
      result = check(messages: [message("user", "a")])

      expect(result.needed?).to be(false)
      expect(result.signals).not_to include(:token_threshold)
    end
  end

  describe "the approaching-window signal" do
    it "raises the need flag once used tokens cross the ratio of the window" do
      result = check(used_tokens: 950)

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:approaching_window)
    end

    it "does not raise the flag comfortably below the window" do
      result = check(used_tokens: 10)

      expect(result.needed?).to be(false)
      expect(result.signals).not_to include(:approaching_window)
    end

    it "does not raise the flag when usage is unknown (nil)" do
      result = check(used_tokens: nil)

      expect(result.signals).not_to include(:approaching_window)
    end

    # C1. The window is whatever THIS check was handed, so one Need answers for
    # a session whose model changed under it -- the same occupancy fires against
    # a small window and stays quiet against a large one, with no rebuild.
    describe "the window is per-check, not per-Need" do
      it "evaluates the same occupancy against whichever window it is handed" do
        expect(check(used_tokens: 950, window_tokens: 1000).signals).to include(:approaching_window)
        expect(check(used_tokens: 950, window_tokens: 1_000_000).signals).not_to include(:approaching_window)
      end
    end

    # The boundary itself, pinned. The comparison now lives in a shared
    # {ContextWindow::Occupancy} so a status line and this detector read one
    # number, and the whole point of the extraction is that it moves the
    # threshold by nothing: `used >= window * ratio`, evaluated in that form,
    # including on a window whose ratio has no exact Float.
    describe "the boundary the ratio names" do
      it "fires at exactly the ratio of the window" do
        expect(check(used_tokens: 900).signals).to include(:approaching_window)
      end

      it "does not fire one token below it" do
        expect(check(used_tokens: 899).signals).not_to include(:approaching_window)
      end

      it "fires at the same token on a window the ratio does not divide evenly" do
        expect(check(used_tokens: 900, window_tokens: 1001).signals).not_to include(:approaching_window)
        expect(check(used_tokens: 901, window_tokens: 1001).signals).to include(:approaching_window)
      end

      # Zero usage is a measurable occupancy, not the absence nil stands for --
      # a 0.0 ratio would clear a 0.0 threshold, and nil never does.
      it "distinguishes a zero-token turn from no turn at all" do
        zero = described_class.new(byte_threshold: 100, approaching_ratio: 0.0)

        expect(zero.check(window_tokens: 1000, used_tokens: 0).signals).to include(:approaching_window)
        expect(zero.check(window_tokens: 1000, used_tokens: nil).signals).not_to include(:approaching_window)
      end
    end

    # The coercion the window kept when it was a constructor argument, moved to
    # where the value now arrives. It has to be HERE and not inside the
    # detector: #fired? short-circuits on a nil `used_tokens`, so a garbage
    # window is completely SILENT until the first turn that carries usage, and
    # then surfaces as a NoMethodError on nil from inside a private object,
    # naming neither the parameter nor the fix. Zero and negatives are worse
    # still -- they never raise at all and fire on every turn forever.
    describe "a window that is not a positive Integer" do
      it "refuses a nil window, naming the parameter" do
        expect { check(window_tokens: nil) }.to raise_error(ArgumentError, /window_tokens/)
      end

      it "refuses a non-numeric window" do
        expect { check(window_tokens: "banana") }.to raise_error(ArgumentError, /window_tokens/)
      end

      it "refuses a zero window, which would otherwise fire on every turn forever" do
        expect { check(window_tokens: 0, used_tokens: 1) }.to raise_error(ArgumentError, /window_tokens/)
      end

      it "refuses a negative window" do
        expect { check(window_tokens: -1, used_tokens: 1) }.to raise_error(ArgumentError, /window_tokens/)
      end

      # The silent case, and the reason the guard cannot live in #fired?: with
      # no usage to measure, the detector never touches the window at all.
      it "refuses it on a turn with no usage, before any signal could read it" do
        expect { check(window_tokens: nil, used_tokens: nil) }.to raise_error(ArgumentError, /window_tokens/)
      end

      it "coerces a numeric String, as the constructor argument used to" do
        expect(check(window_tokens: "1000", used_tokens: 950).signals).to include(:approaching_window)
      end
    end
  end

  describe "the manual signal" do
    it "raises the need flag on an explicit manual trigger" do
      result = check(manual: true)

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:manual)
    end

    it "does not raise the flag without one" do
      result = check(manual: false)

      expect(result.signals).not_to include(:manual)
    end
  end

  describe "the plan-step-completion signal" do
    # Scenario: A completed todo raises the need flag
    it "raises the need flag when handed a completed plan-step signal" do
      result = check(plan_step_completed: true)

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:plan_step_completion)
    end

    it "does not raise the flag without one" do
      result = check(plan_step_completed: false)

      expect(result.signals).not_to include(:plan_step_completion)
    end
  end

  # Deliberately REQUIRED, and pinned so it stays that way: a defaulted window
  # is a threshold nobody chose, silently applied to every model that forgets to
  # pass one -- and an over-estimate is the failure that never fires at all. The
  # whole point of C1 is that the window comes from the turn, so a default here
  # would quietly restore the startup-time constant it replaced.
  it "demands a window rather than assuming one" do
    expect { need.check }.to raise_error(ArgumentError, /window_tokens/)
  end

  it "raises no flag when nothing fires" do
    result = check

    expect(result.needed?).to be(false)
    expect(result.signals).to eq([])
  end

  it "collects every signal that fires, not just the first" do
    result = check(messages: [message("user", "a" * 200)], manual: true, plan_step_completed: true)

    expect(result.signals).to contain_exactly(:token_threshold, :manual, :plan_step_completion)
  end

  # "no compaction runs": Need's Result carries only which signals fired, never
  # rewritten content -- there is no summarizer collaborator anywhere in this
  # object for a signal to reach, so raising a flag structurally cannot also
  # execute a rewrite.
  it "never summarizes or rewrites -- the result carries flags, not content" do
    result = check(messages: [message("user", "a" * 200)], manual: true)

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
      result = check(messages: [message("user", "a" * 200)], manual: true, plan_step_completed: true)

      expect(result).to be_deeply_frozen
      expect(result).to be_ractor_shareable
    end

    it "keeps every detector collaborator deeply frozen and Ractor-shareable" do
      detectors = need.instance_variable_get(:@detectors)

      expect(detectors).not_to be_empty
      expect(detectors).to all(be_deeply_frozen.and(be_ractor_shareable))
    end
  end
end
