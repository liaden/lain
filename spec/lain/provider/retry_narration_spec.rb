# frozen_string_literal: true

RSpec.describe Lain::Provider::RetryNarration do
  let(:channel) { RecordingChannel.new }
  let(:journal) { RecordingChannel.new }
  let(:narration) { described_class.new(channel:, journal:) }

  def retries_in(sink) = sink.events.grep(Lain::Telemetry::ProviderRetry)

  it "puts a retry on the display and in the record" do
    narration.retried(retry_count: 1, will_retry_in: 0.5, status: 503, exception: Faraday::ConnectionFailed.new("x"))

    expect(retries_in(journal)).to eq(retries_in(channel))
    expect(retries_in(journal).map(&:to_h)).to eq(
      [{ attempt: 2, will_retry_in: 0.5, status: 503, reason: "Faraday::ConnectionFailed" }]
    )
  end

  it "numbers the exhausted run one past the retry count, with no backoff, in both places" do
    narration.exhausted(max: 3, status: 503, exception: Faraday::ConnectionFailed.new("x"))

    expect(retries_in(journal).map(&:to_h)).to eq(
      [{ attempt: 4, will_retry_in: nil, status: 503, reason: "Faraday::ConnectionFailed" }]
    )
    expect(retries_in(channel)).to eq(retries_in(journal))
  end

  it "needs no journal to narrate" do
    described_class.new(channel:).retried(retry_count: 0, will_retry_in: 0.1, status: nil,
                                          exception: Faraday::ConnectionFailed.new("x"))

    expect(retries_in(channel).size).to eq(1)
  end
end
