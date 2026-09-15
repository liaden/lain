# frozen_string_literal: true

# Why an ask stopped, read off the error's type and its causes, never its
# message: the text is the provider's to change, and a record classified by it
# would silently re-classify the day the words moved.
RSpec.describe Lain::Agent::StopReason do
  def caused_by(cause, error)
    raise cause
  rescue StandardError
    begin
      raise error
    rescue StandardError => e
      e
    end
  end

  def status_error(status) = Lain::Provider::Ollama::APIStatusError.new("status #{status}", status:)

  it "names a budget ceiling" do
    expect(described_class.for(Lain::Agent::Budget::Exceeded.new("loop ran 25 iterations"))).to eq(:ceiling)
  end

  it "names a prompt refused for not fitting the context" do
    refusal = Lain::Middleware::RequestBudget::OverWindow.new("refused", prompt_tokens: 9, window_tokens: 8,
                                                                         source: "ollama")

    expect(described_class.for(refusal)).to eq(:over_window)
  end

  # A stall never reaches an ask as itself: the provider re-raises it as its
  # own APIError, so the stall survives only as the cause.
  it "names a stalled stream by its cause, not as the transport failure it is wrapped in" do
    stall = Lain::Provider::HTTP::Streaming::StalledStreamError.new("no chunk for 30.0s")

    wrapped = caused_by(stall, Lain::Provider::Anthropic::APIError.new("no chunk"))

    expect(described_class.for(wrapped)).to eq(:stalled_stream)
  end

  it "names a stop this ask was asked for, wherever it sits in the causes" do
    expect(described_class.for(Lain::Stopped.new("stopped"))).to eq(:stopped)
    expect(described_class.for(caused_by(Lain::Stopped.new("stopped"), Lain::Error.new("unwound")))).to eq(:stopped)
  end

  describe "a transport failure" do
    it "names a round trip that never reached the wire" do
      expect(described_class.for(Lain::Provider::Ollama::PreWireError.new("refused"))).to eq(:transport)
    end

    it "names a round trip that got no status back at all" do
      expect(described_class.for(Lain::Provider::Anthropic::APIError.new("connection reset"))).to eq(:transport)
    end

    it "names a server-side failure" do
      expect(described_class.for(status_error(503))).to eq(:transport)
    end

    # Both fail for the moment rather than for the request: a timeout and a
    # rate limit answer differently a little later.
    it "names a request timeout and a rate limit" do
      expect(described_class.for(status_error(408))).to eq(:transport)
      expect(described_class.for(status_error(429))).to eq(:transport)
    end

    it "names an endpoint too busy to take the call" do
      expect(described_class.for(Lain::Provider::Admission::Busy.new("busy"))).to eq(:transport)
    end

    # The request's own fault -- a bad key, a model the server does not have --
    # fails the same way every time, which no transport does.
    it "does not name a status the request itself earned" do
      expect(described_class.for(status_error(401))).to eq(:torn)
    end
  end

  it "says torn for anything it cannot place" do
    expect(described_class.for(Lain::Error.new("no known kind"))).to eq(:torn)
    expect(described_class.for(RuntimeError.new("a bug"))).to eq(:torn)
  end

  it "answers only reasons the run_interrupted record accepts" do
    reasons = [Lain::Error.new("x"), Lain::Stopped.new("x"), status_error(500)].map { |error| described_class.for(error) }

    expect(Lain::Telemetry::RunInterrupted::REASONS).to include(*reasons)
  end
end
