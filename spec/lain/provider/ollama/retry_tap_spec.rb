# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Lain::Provider::Ollama::RetryTap do
  let(:channel) { RecordingChannel.new }
  let(:journal) { RecordingChannel.new }
  let(:tap) { described_class.new(channel:, journal:) }
  let(:base) { "https://cloud.example" }

  def gate(width) = Lain::Provider::Admission.new(endpoint: base, width:)

  # Faraday hands the retry_block a real Env whose `request` RequestOptions
  # carries the context the transport stashed the attempt on; a plain Hash with
  # a RequestOptions double reads the same way through `env[:request].context`.
  def env_for(attempt, status: nil)
    request_options = Data.define(:context).new(context: { retry_attempt: attempt })
    { request: request_options, status: }
  end

  # A recording spool: every open_frame records its digest, so a rotation shows
  # up as a SECOND open under the same digest.
  def recording_spool(log)
    Class.new do
      define_method(:open_frame) do |request_digest:, **|
        log << request_digest
        Lain::Provider::Spool::Null::Frame.new
      end
    end.new
  end

  # Both keys on ONE context, which is what the transport really writes -- the
  # frame and the attempt travel together but are read independently.
  def env_with(attempt: nil, frame: nil, status: nil)
    context = { retry_attempt: attempt, wal_frame: frame }
    { request: Data.define(:context).new(context:), status: }
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
    # would abandon whichever sibling opened last, which for the assembler reset
    # means throwing away the WRONG stream's bytes.
    it "abandons only the attempt on the retried env when two round trips share the instance" do
      abandoned = []
      attempt_a = tap.open_attempt { abandoned << :a }
      tap.open_attempt { abandoned << :b }

      fire_retry(env_for(attempt_a))

      expect(abandoned).to eq([:a])
    end

    # Null Object, not a nil guard: a round trip with nothing to discard is
    # abandoned exactly like one that has something, so #retry_block carries no
    # `if rollback` and the assembler reset changes only what it registers, not
    # this path.
    it "journals a retry for a round trip that registered nothing to discard" do
      fire_retry(env_for(tap.open_attempt))

      expect(channel.events.grep(Lain::Telemetry::ProviderRetry).map(&:attempt)).to eq([1])
    end

    # faraday-retry hands the round trip back only its LAST failure, so each
    # abandoned attempt has to be told to the witness as it is abandoned.
    it "tells the retried round trip's witness what its abandoned attempt failed with" do
      witness = Lain::Provider::ErrorWrapping::WireWitness.new

      tap.retry_block.call(env: env_for(tap.open_attempt.witnessed_by(witness)), retry_count: 0,
                           exception: Faraday::ConnectionFailed.new(Errno::ECONNRESET.new), will_retry_in: 0.5)

      expect(witness.pre_wire?(Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new))).to be(false)
    end

    # A probe (`/api/ps`) opens no attempt, and neither does an injected config
    # in a spec; both must still journal rather than crash on a missing context.
    it "journals a retry on an env carrying no attempt at all" do
      fire_retry({ request: Data.define(:context).new(context: nil), status: nil })

      expect(channel.events.grep(Lain::Telemetry::ProviderRetry).map(&:attempt)).to eq([1])
    end
  end

  describe "#open_frame" do
    it "opens one frame per round trip under the request's own digest" do
      digests = []
      described_class.new(channel:, spool: recording_spool(digests)).open_frame(request_digest: "d", stream: true)

      expect(digests).to eq(%w[d])
    end

    describe "wire" do
      around do |example|
        Dir.mktmpdir("wal") { |dir| @path = File.join(dir, "s.wal") and example.run }
      end

      def wire_of(stream)
        wal = Lain::Provider::ResponseWal.new(@path)
        described_class.new(channel:, spool: wal).open_frame(request_digest: "d", stream:).close(complete: true)
        wal.frames.to_a.fetch(0).wire
      end

      it("names a streamed frame ollama-ndjson") { expect(wire_of(true)).to eq("ollama-ndjson") }
      it("names a sync body's frame ollama-json") { expect(wire_of(false)).to eq("ollama-json") }
    end

    # Null Object, and the default: a provider built with no spool still opens
    # and rotates frames, they just discard. No caller writes `if spool`.
    it "opens a frame over the Null spool when no spool was given" do
      expect { tap.open_frame(request_digest: "d", stream: true).append("x").close(complete: true) }.not_to raise_error
    end
  end

  describe "#retry_block frame rotation" do
    it "rotates the retried request's OWN frame, read off the env" do
      frames = []
      rotating = described_class.new(channel:, spool: recording_spool(frames))
      frame = rotating.open_frame(request_digest: "d", stream: true)

      rotating.retry_block.call(env: env_with(frame:), retry_count: 0,
                                exception: Faraday::ConnectionFailed.new("x"), will_retry_in: 0.5)

      # The retried attempt got a FRESH frame under the same digest.
      expect(frames).to eq(%w[d d])
    end

    # The reentrancy blocker, stated for the frame exactly as it already is for
    # the attempt: one Provider serves the chat and the summarizer tier, so two
    # round trips are in flight through this ONE tap. Rotating the wrong one
    # would abort a live sibling's frame and splice this one anyway.
    it "rotates only the frame on the retried env when two round trips share the instance" do
      frames = []
      rotating = described_class.new(channel:, spool: recording_spool(frames))
      frame_a = rotating.open_frame(request_digest: "req-a", stream: true)
      rotating.open_frame(request_digest: "req-b", stream: true)

      rotating.retry_block.call(env: env_with(frame: frame_a), retry_count: 0,
                                exception: Faraday::ConnectionFailed.new("x"), will_retry_in: 0.5)

      expect(frames).to eq(%w[req-a req-b req-a])
    end

    # RULING 3: the assembler reset and the frame rotation are registered on
    # two DIFFERENT context keys, so neither registration can displace the
    # other. Asserting both fire from one retry is what pins that -- a design
    # that folded the rotation into the attempt's rollback would still pass the
    # two examples above, and fail this one the moment either was replaced.
    it "abandons the attempt AND rotates the frame from the same retry" do
      frames = []
      rotating = described_class.new(channel:, spool: recording_spool(frames))
      abandoned = []
      attempt = rotating.open_attempt { abandoned << :discarded }
      frame = rotating.open_frame(request_digest: "d", stream: true)

      rotating.retry_block.call(env: env_with(attempt:, frame:), retry_count: 0,
                                exception: Faraday::ConnectionFailed.new("x"), will_retry_in: 0.5)

      expect(abandoned).to eq([:discarded])
      expect(frames).to eq(%w[d d])
      expect(channel.events.grep(Lain::Telemetry::ProviderRetry).size).to eq(1)
    end

    it "journals a retry on an env carrying a frame but no attempt" do
      frames = []
      rotating = described_class.new(channel:, spool: recording_spool(frames))
      frame = rotating.open_frame(request_digest: "d", stream: true)

      rotating.retry_block.call(env: env_with(frame:), retry_count: 0,
                                exception: Faraday::ConnectionFailed.new("x"), will_retry_in: 0.5)

      expect(channel.events.grep(Lain::Telemetry::ProviderRetry).map(&:attempt)).to eq([1])
    end
  end

  describe "#exhausted_block" do
    it "journals the exhausted run at the ordinal of the attempt that actually failed" do
      options = Data.define(:max).new(max: 3)
      tap.exhausted_block.call(env: { status: 503 }, exception: Faraday::ConnectionFailed.new("x"), options:)

      event = channel.events.grep(Lain::Telemetry::ProviderRetry).fetch(0)
      # max retries means max+1 real attempts (the original try plus each
      # retry) -- measured: a counting TCP listener saw 4 real attempts rendered
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

  # The server names its limit only on a refusal: a successful response carries
  # no rate-limit header, so a 429 is the one place the width can be learned.
  describe "#retry_block on a concurrency 429" do
    def refusal(body: '{"error":"too many concurrent requests"}', klass: Lain::Provider::HTTP::RateLimitError,
                **headers)
      response = Faraday::Env.from(status: 429, body:, response_headers: Faraday::Utils::Headers.new(headers))
      klass.new(response, body)
    end

    def limit_headers(max_concurrent)
      { "x-ratelimit-max-concurrent" => max_concurrent.to_s, "x-ratelimit-active" => "1",
        "x-ratelimit-queue-limit" => "10", "x-ratelimit-queued" => "10" }
    end

    def concurrency_refusal(max_concurrent) = refusal(**limit_headers(max_concurrent))

    def fire_refusal(exception, through:)
      tap.retry_block.call(env: env_for(tap.open_attempt.narrowing(through), status: 429), retry_count: 0,
                           exception:, will_retry_in: 0)
    end

    it "narrows the gate the retried request was admitted through to the server's limit" do
      admission = gate(3)

      fire_refusal(concurrency_refusal(1), through: admission)

      expect(admission.width).to eq(1)
    end

    it "journals the narrowing with the old width, the new width and the header values" do
      fire_refusal(concurrency_refusal(1), through: gate(3))

      expect(journal.events.grep(Lain::Telemetry::AdmissionNarrowed).map(&:to_h)).to eq(
        [{ endpoint: base, from_width: 3, to_width: 1, max_concurrent: 1, active: 1, queue_limit: 10, queued: 10 }]
      )
    end

    # The channel is the live frontend stream, which a TTY session drops and a
    # headless run nulls out; only the journal is the session's record.
    it "writes the narrowing to the journal, not the channel" do
      fire_refusal(concurrency_refusal(1), through: gate(3))

      expect(channel.events.grep(Lain::Telemetry::AdmissionNarrowed)).to be_empty
    end

    it "never widens, and journals nothing when the width did not move" do
      admission = gate(1)

      fire_refusal(concurrency_refusal(3), through: admission)

      expect([admission.width, journal.events.grep(Lain::Telemetry::AdmissionNarrowed)]).to eq([1, []])
    end

    it "keeps an explicit declared width as the ceiling" do
      declared = Lain::Provider::Ollama::Deployment.cloud(api_key: "k", admission_width: 2).admission_width
      admission = gate(declared)

      fire_refusal(concurrency_refusal(3), through: admission)

      expect(admission.width).to eq(2)
    end

    it "leaves the width alone on a 429 that names no concurrency limit" do
      admission = gate(3)

      fire_refusal(refusal(body: '{"error":"slow down"}'), through: admission)

      expect(admission.width).to eq(3)
    end

    it "ignores a limit header that is not a positive integer" do
      admission = gate(3)

      fire_refusal(refusal("x-ratelimit-max-concurrent" => "0"), through: admission)

      expect(admission.width).to eq(3)
    end

    it "leaves the width alone on a retry that was not a 429" do
      admission = gate(3)

      fire_refusal(Faraday::ConnectionFailed.new("x"), through: admission)

      expect(admission.width).to eq(3)
    end

    # Only a 429 names the plan's limit; a 5xx that happens to carry the header
    # is a server fault, not a plan, and must not shrink the session.
    it "leaves the width alone on a server error carrying the limit header" do
      admission = gate(3)

      fire_refusal(refusal(klass: Lain::Provider::HTTP::ServerError, **limit_headers(1)), through: admission)

      expect(admission.width).to eq(3)
    end

    it "raises nothing and stays unbounded when admission is disabled" do
      admission = Lain::Provider::Admission::Null.new(endpoint: base)

      expect { fire_refusal(concurrency_refusal(1), through: admission) }.not_to raise_error
      expect([admission.width, journal.events.grep(Lain::Telemetry::AdmissionNarrowed)])
        .to eq([Float::INFINITY, []])
    end

    it "narrows nothing for a round trip that was admitted through no gate" do
      expect do
        tap.retry_block.call(env: env_for(tap.open_attempt, status: 429), retry_count: 0,
                             exception: concurrency_refusal(1), will_retry_in: 0)
      end.not_to raise_error
      expect(journal.events.grep(Lain::Telemetry::AdmissionNarrowed)).to be_empty
    end
  end

  # The half a Hash env double cannot prove: that a REAL faraday-retry reaches
  # this request's attempt, which depends on {Transport} threading it onto the
  # Faraday request context. The assembler reset rides exactly this path, so
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

    context "with a hosted endpoint" do
      def hosted_transport
        config = zero_retry_config
        config.ollama_api_base = base
        config.retry_block = tap.retry_block
        Lain::Provider::Ollama::Transport.new(config)
      end

      it "narrows on a concurrency 429 and lets faraday-retry send the retry exactly once" do
        admission = gate(3)
        stub = stub_request(:post, "#{base}/api/chat")
               .to_return(status: 429, body: '{"error":"too many concurrent requests"}',
                          headers: { "Content-Type" => "application/json", "Retry-After" => "0",
                                     "x-ratelimit-max-concurrent" => "1" }).then
               .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{}")

        hosted_transport.sync_post({}, attempt: tap.open_attempt.narrowing(admission))

        expect(admission.width).to eq(1)
        expect(stub).to have_been_requested.twice
      end

      it "raises the context-length error as before and leaves the width alone" do
        admission = gate(3)
        stub_request(:post, "#{base}/api/chat")
          .to_return(status: 429, body: '{"error":"context length exceeded"}',
                     headers: { "Content-Type" => "application/json" })

        expect { hosted_transport.sync_post({}, attempt: tap.open_attempt.narrowing(admission)) }
          .to raise_error(Lain::Provider::HTTP::ContextLengthExceededError)
        expect(admission.width).to eq(3)
      end
    end
  end

  describe "the session record" do
    it "holds the retry and the display holds the same event" do
      fire_retry(env_for(tap.open_attempt, status: 500), retry_count: 0)

      expect(journal.events.grep(Lain::Telemetry::ProviderRetry)).to eq(channel.events.grep(Lain::Telemetry::ProviderRetry))
      expect(journal.events.grep(Lain::Telemetry::ProviderRetry).size).to eq(1)
    end

    it "holds the exhausted run too" do
      options = Data.define(:max).new(max: 3)
      tap.exhausted_block.call(env: { status: 503 }, exception: Faraday::ConnectionFailed.new("x"), options:)

      expect(journal.events.grep(Lain::Telemetry::ProviderRetry).map(&:attempt)).to eq([4])
    end
  end
end
