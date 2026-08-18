# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Lain::Provider::Ollama::RetryTap do
  let(:channel) { RecordingChannel.new }
  let(:tap) { described_class.new(channel:) }

  # Faraday hands the retry_block a real Env whose `request` RequestOptions
  # carries the context the transport stashed the attempt on; a plain Hash with
  # a RequestOptions double reads the same way through `env[:request].context`.
  def env_for(attempt, status: nil)
    request_options = Data.define(:context).new(context: { retry_attempt: attempt })
    { request: request_options, status: }
  end

  def fire_retry(env, retry_count: 0)
    tap.retry_block.call(env:, retry_count:, exception: Faraday::ConnectionFailed.new("x"), will_retry_in: 0.5)
  end

  describe "#retry_block" do
    it "journals the retry with the attempt number, backoff, status and cause" do
      fire_retry(env_for(tap.open_attempt, status: 503), retry_count: 1)

      event = channel.events.grep(Lain::Telemetry::ProviderRetry).fetch(0)
      expect(event.attempt).to eq(2)
      expect(event.will_retry_in).to eq(0.5)
      expect(event.status).to eq(503)
      expect(event.reason).to eq("Faraday::ConnectionFailed")
    end

    it "abandons the attempt on the retried env, so what that attempt accumulated is discarded" do
      discarded = []
      fire_retry(env_for(tap.open_attempt { discarded << :rolled_back }))

      expect(discarded).to eq([:rolled_back])
    end

    # The blocker RetryTap exists to answer, stated for Anthropic and true here:
    # one Provider serves the chat and the summarizer tier for a whole session,
    # so two round trips can be in flight through this ONE tap. A retry firing
    # for round trip A must abandon A and only A -- instance-held live state
    # would abandon whichever sibling opened last, which for T10 means throwing
    # away the WRONG stream's bytes.
    it "abandons only the attempt on the retried env when two round trips share the instance" do
      abandoned = []
      attempt_a = tap.open_attempt { abandoned << :a }
      tap.open_attempt { abandoned << :b }

      fire_retry(env_for(attempt_a))

      expect(abandoned).to eq([:a])
    end

    # Null Object, not a nil guard: a round trip with nothing to discard is
    # abandoned exactly like one that has something, so #retry_block carries no
    # `if rollback` and T10 changes only what it registers, not this path.
    it "journals a retry for a round trip that registered nothing to discard" do
      fire_retry(env_for(tap.open_attempt))

      expect(channel.events.grep(Lain::Telemetry::ProviderRetry).map(&:attempt)).to eq([1])
    end

    # A probe (`/api/ps`) opens no attempt, and neither does an injected config
    # in a spec; both must still journal rather than crash on a missing context.
    it "journals a retry on an env carrying no attempt at all" do
      fire_retry({ request: Data.define(:context).new(context: nil), status: nil })

      expect(channel.events.grep(Lain::Telemetry::ProviderRetry).map(&:attempt)).to eq([1])
    end
  end

  describe "#exhausted_block" do
    it "journals the exhausted run at the ordinal of the attempt that actually failed" do
      options = Data.define(:max).new(max: 3)
      tap.exhausted_block.call(env: { status: 503 }, exception: Faraday::ConnectionFailed.new("x"), options:)

      event = channel.events.grep(Lain::Telemetry::ProviderRetry).fetch(0)
      # max retries means max+1 real attempts (the original try plus each
      # retry) -- F16: a counting TCP listener saw 4 real attempts rendered
      # as "1, 2, 3, 3" because this used to push the retry COUNT.
      expect(event.attempt).to eq(4)
      expect(event.will_retry_in).to be_nil
      expect(event.reason).to eq("Faraday::ConnectionFailed")
    end

    # AC: the give-up line names a higher attempt number than the last
    # retrying notice did. Stated as a relation, not a literal, so the test
    # cannot pass by coincidence if both numbers are wrong by the same amount.
    it "names a higher attempt number than the last retrying notice did" do
      options = Data.define(:max).new(max: 3)
      fire_retry(env_for(tap.open_attempt), retry_count: options.max - 1)
      last_retrying = channel.events.grep(Lain::Telemetry::ProviderRetry).last.attempt

      tap.exhausted_block.call(env: { status: 503 }, exception: Faraday::ConnectionFailed.new("x"), options:)
      gave_up_at = channel.events.grep(Lain::Telemetry::ProviderRetry).last.attempt

      expect(gave_up_at).to be > last_retrying
    end
  end

  # The half a Hash env double cannot prove: that a REAL faraday-retry reaches
  # this request's attempt, which depends on {Transport} threading it onto the
  # Faraday request context. T10's assembler reset rides exactly this path, so
  # it is pinned end to end rather than at the tap's own doorstep.
  describe "over the real transport", :webmock do
    it "abandons the attempt the transport threaded onto the retried request" do
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_raise(Faraday::ConnectionFailed).then
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{}")
      config = zero_retry_config
      config.retry_block = tap.retry_block
      abandoned = []

      Lain::Provider::Ollama::Transport.new(config)
                                       .sync_post({}, attempt: tap.open_attempt { abandoned << :discarded })

      expect(abandoned).to eq([:discarded])
      expect(channel.events.grep(Lain::Telemetry::ProviderRetry).map(&:attempt)).to eq([1])
    end
  end
end
