# frozen_string_literal: true

RSpec.describe Lain::Provider::AnthropicRaw::RetryTap do
  let(:channel) { RecordingChannel.new }
  let(:tap) { described_class.new(spool: Lain::Provider::Spool::Null.new, channel:) }

  it "journals an exhausted retry run at the configured max, with no next backoff" do
    options = Data.define(:max).new(max: 3)
    tap.exhausted_block.call(env: { status: 503 }, exception: Faraday::ConnectionFailed.new("x"), options:)

    event = channel.events.grep(Lain::Telemetry::ProviderRetry).fetch(0)
    expect(event.attempt).to eq(3)
    expect(event.will_retry_in).to be_nil
    expect(event.status).to eq(503)
    expect(event.reason).to eq("Faraday::ConnectionFailed")
  end

  it "rotates the live frame and journals when a retry fires" do
    frames = []
    spool = Class.new do
      define_method(:open_frame) do |request_digest:|
        frames << request_digest
        Lain::Provider::Spool::Null::Frame.new
      end
    end.new
    tap = described_class.new(spool:, channel:)
    tap.open_frame(request_digest: "d")

    tap.retry_block.call(env: { status: nil }, retry_count: 0,
                         exception: Faraday::ConnectionFailed.new("x"), will_retry_in: 0.5)

    expect(frames).to eq(%w[d d]) # the retried attempt got a fresh frame under the same digest
    expect(channel.events.grep(Lain::Telemetry::ProviderRetry).size).to eq(1)
  end
end
