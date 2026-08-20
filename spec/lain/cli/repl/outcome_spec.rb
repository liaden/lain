# frozen_string_literal: true

# The conversation's exit status as a value, driven directly -- what a headless
# run reports is decided entirely here, and repl_spec.rb pins two of these cases
# end to end through the real Wiring rather than all of them: the rules are this
# object's, the wiring is the Repl's.
RSpec.describe Lain::CLI::Repl::Outcome do
  subject(:outcome) { described_class.new }

  def answered(stop_reason)
    Lain::Response.new(content: [{ "type" => "text", "text" => "words" }], stop_reason:)
  end

  it "starts complete: a conversation that ran no line failed no line" do
    expect(outcome.exit_status).to eq(described_class::COMPLETED)
  end

  describe "what it accepts as a finished answer" do
    it "takes an ended turn" do
      outcome.note(answered(:end_turn))

      expect(outcome.exit_status).to eq(described_class::COMPLETED)
    end

    # The caller asked generation to stop there, so the answer is complete --
    # the one non-obvious member of the allow-list.
    it "takes a turn stopped at a caller's own stop sequence" do
      outcome.note(answered(:stop_sequence))

      expect(outcome.exit_status).to eq(described_class::COMPLETED)
    end

    it "hands the value straight back, so a call site stays one expression" do
      response = answered(:end_turn)

      expect(outcome.note(response)).to equal(response)
    end
  end

  # Each of these renders text to the terminal and used to exit 0, so a script
  # could not tell a finished answer from a cut-off one -- which is the whole
  # point of --non-interactive.
  describe "what it counts as a turn that did not finish" do
    it "counts a refusal carried out of the ask as a value" do
      outcome.note(Lain::Error.new("the endpoint is unreachable"))

      expect(outcome.exit_status).to eq(described_class::UNFINISHED)
    end

    it "counts an answer cut off at max_tokens" do
      outcome.note(answered(:max_tokens))

      expect(outcome.exit_status).to eq(described_class::UNFINISHED)
    end

    it "counts the model refusing" do
      outcome.note(answered(:refusal))

      expect(outcome.exit_status).to eq(described_class::UNFINISHED)
    end

    it "counts a turn that only paused" do
      outcome.note(answered(:pause_turn))

      expect(outcome.exit_status).to eq(described_class::UNFINISHED)
    end

    # An interrupt tears the ask before it commits a response
    # ({Lain::CLI::Conductor::Outcome#response} is nil then), and a run that was
    # stopped is not a run that finished.
    it "counts an ask torn before it committed anything" do
      outcome.note(nil)

      expect(outcome.exit_status).to eq(described_class::UNFINISHED)
    end

    # The allow-list's whole reason for being: the wire enums are
    # non-exhaustive, StopReason normalizes what it does not know to :unknown,
    # and a deny-list would welcome every reason added after this was written.
    it "counts a stop reason it has never heard of" do
      outcome.note(answered(:some_reason_invented_next_year))

      expect(outcome.exit_status).to eq(described_class::UNFINISHED)
    end

    # A middleware that short-circuits without setting :response breaks its own
    # contract; the Repl names that at the terminal, and it is a torn line with
    # no value to describe it.
    it "counts a breach that produced no value at all" do
      outcome.torn_by("the middleware never set :response")

      expect(outcome.exit_status).to eq(described_class::UNFINISHED)
    end

    it "hands that reason back, so the one caller renders it in the same breath" do
      expect(outcome.torn_by("the middleware never set :response")).to eq("the middleware never set :response")
    end
  end

  it "does not forget: a good turn after a torn one still reports the tear" do
    outcome.note(answered(:max_tokens))
    outcome.note(answered(:end_turn))

    expect(outcome.exit_status).to eq(described_class::UNFINISHED)
  end
end
