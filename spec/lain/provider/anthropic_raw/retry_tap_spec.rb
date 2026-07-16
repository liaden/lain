# frozen_string_literal: true

RSpec.describe Lain::Provider::AnthropicRaw::RetryTap do
  let(:channel) { RecordingChannel.new }
  let(:tap) { described_class.new(spool: Lain::Provider::Spool::Null.new, channel:) }

  # A recording spool: every open_frame records its digest, so a rotation shows
  # up as a SECOND open under the same digest.
  def recording_spool(log)
    Class.new do
      define_method(:open_frame) do |request_digest:|
        log << request_digest
        Lain::Provider::Spool::Null::Frame.new
      end
    end.new
  end

  # Faraday hands the retry_block a real Env whose `request` RequestOptions
  # carries the context the transport stashed the frame on; a plain Hash with a
  # RequestOptions double reads the same way through `env[:request].context`.
  def env_for(frame, status: nil)
    request_options = Data.define(:context).new(context: { wal_frame: frame })
    { request: request_options, status: }
  end

  it "journals an exhausted retry run at the configured max, with no next backoff" do
    options = Data.define(:max).new(max: 3)
    tap.exhausted_block.call(env: { status: 503 }, exception: Faraday::ConnectionFailed.new("x"), options:)

    event = channel.events.grep(Lain::Telemetry::ProviderRetry).fetch(0)
    expect(event.attempt).to eq(3)
    expect(event.will_retry_in).to be_nil
    expect(event.status).to eq(503)
    expect(event.reason).to eq("Faraday::ConnectionFailed")
  end

  it "rotates the retried request's OWN frame, read off the env, and journals" do
    frames = []
    tap = described_class.new(spool: recording_spool(frames), channel:)
    frame = tap.open_frame(request_digest: "d")

    tap.retry_block.call(env: env_for(frame), retry_count: 0,
                         exception: Faraday::ConnectionFailed.new("x"), will_retry_in: 0.5)

    expect(frames).to eq(%w[d d]) # the retried attempt got a fresh frame under the same digest
    expect(channel.events.grep(Lain::Telemetry::ProviderRetry).size).to eq(1)
  end

  # The blocker: one Provider instance serves the main Agent and every parallel
  # subagent, so two round trips are in flight through this ONE RetryTap at once.
  # A retry firing for request A must rotate A's frame and ONLY A's frame --
  # instance-held live state would rotate whichever sibling opened last, forging
  # a "complete" frame out of two concatenated attempts on the wrong request.
  it "rotates only the frame on the retried env when two requests share the instance" do
    frames = []
    tap = described_class.new(spool: recording_spool(frames), channel:)
    frame_a = tap.open_frame(request_digest: "req-a")
    tap.open_frame(request_digest: "req-b")

    tap.retry_block.call(env: env_for(frame_a), retry_count: 0,
                         exception: Faraday::ConnectionFailed.new("x"), will_retry_in: 0.1)

    # req-a rotated (opened twice); req-b's frame never touched, even though it
    # opened last -- the old instance-state bug would have rotated req-b.
    expect(frames).to eq(%w[req-a req-b req-a])
  end
end
