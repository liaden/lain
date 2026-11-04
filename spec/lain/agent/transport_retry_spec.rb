# frozen_string_literal: true

RSpec.describe Lain::Agent::TransportRetry do
  let(:journal) { [] }
  let(:slept) { [] }
  let(:retrying) { described_class.new(journal:, sleeper: ->(seconds) { slept << seconds }) }

  def failure(cause)
    raise cause
  rescue StandardError
    begin
      raise Lain::Provider::Ollama::APIError, "round trip failed"
    rescue StandardError => e
      e
    end
  end

  def dropped = failure(Faraday::SSLError.new(OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof while reading")))

  def round_trip(*outcomes)
    calls = []
    trip = lambda {
      calls << :sent
      outcome = outcomes.size > 1 ? outcomes.shift : outcomes.first
      outcome.is_a?(Exception) ? raise(outcome) : outcome
    }
    [trip, calls]
  end

  it "answers a round trip that succeeds without waiting or journaling" do
    trip, calls = round_trip(:answer)

    expect(retrying.call(&trip)).to eq(:answer)
    expect([calls.size, slept, journal]).to eq([1, [], []])
  end

  it "re-sends a dropped round trip after the first backoff and journals the retry" do
    trip, calls = round_trip(dropped, :answer)

    expect(retrying.call(&trip)).to eq(:answer)
    expect([calls.size, slept]).to eq([2, [0.1]])
    expect(journal).to eq([Lain::Telemetry::ProviderRetry.new(attempt: 1, will_retry_in: 0.1,
                                                              reason: "Faraday::SSLError", path: "agent")])
  end

  it "stops after 4 attempts, backing off between them, and raises the last drop" do
    last = dropped
    trip, calls = round_trip(dropped, dropped, dropped, last)

    expect { retrying.call(&trip) }.to raise_error(last)
    expect([calls.size, slept]).to eq([4, [0.1, 0.2, 0.4]])
    expect(journal.map { |record| [record.attempt, record.will_retry_in] }).to eq([[1, 0.1], [2, 0.2], [3, 0.4],
                                                                                   [4, nil]])
  end

  it "leaves a server-side status to Faraday's own retries" do
    unavailable = Lain::Provider::Ollama::APIStatusError.new("unavailable", status: 503)
    trip, calls = round_trip(unavailable, :answer)

    expect { retrying.call(&trip) }.to raise_error(unavailable)
    expect([calls.size, slept, journal]).to eq([1, [], []])
  end

  it "does not retry a 503 that follows a drop" do
    unavailable = Lain::Provider::Ollama::APIStatusError.new("unavailable", status: 503)
    trip, calls = round_trip(dropped, unavailable)

    expect { retrying.call(&trip) }.to raise_error(unavailable)
    expect([calls.size, slept, journal.size]).to eq([2, [0.1], 1])
  end

  it "lets an error that follows a drop propagate at once" do
    trip, calls = round_trip(dropped, ArgumentError.new("a bug"))

    expect { retrying.call(&trip) }.to raise_error(ArgumentError, "a bug")
    expect(calls.size).to eq(2)
  end

  it "has a pass-through that answers the round trip once and retries nothing" do
    trip, calls = round_trip(dropped, :answer)

    expect { described_class::NONE.call(&trip) }.to raise_error(Lain::Provider::Ollama::APIError)
    expect(calls.size).to eq(1)
  end

  it "does not retry a stalled stream" do
    stalled = failure(Lain::Provider::HTTP::Streaming::StalledStreamError.new("stalled stream"))
    trip, calls = round_trip(stalled, :answer)

    expect { retrying.call(&trip) }.to raise_error(stalled)
    expect(calls.size).to eq(1)
  end
end
