# frozen_string_literal: true

require "faraday"

# F7a, bounded: a model server that stops emitting mid-body and holds the socket
# open used to cost `request_timeout` per attempt, four attempts deep, printing
# nothing. Measured here on this branch before the fix, with the 300s budget
# scaled down to 1.5s so the suite could survive it: **Faraday::TimeoutError
# after 6.02s across FOUR connections** -- exactly 4 x request_timeout, which at
# the shipped number is twenty minutes.
#
# Every example drives a REAL socket through {StreamingUpstream}, because the
# subject is time between TCP reads and WebMock hands a stubbed body over as one
# chunk (spec/lain/provider/ollama/streamed_failure_spec.rb:5-9). Untagged with
# `:vcr` and never inside `VCR.use_cassette`, deliberately -- a replaying
# cassette makes `permit_loopback` inert (spec/support/network_access.rb), and
# the same rule is why connection counts here ask `upstream.requests.size`
# rather than `assert_requested`.
#
# The numbers are scaled, not chosen: the shipped grace is 30s and the shipped
# first-byte budget is `request_timeout`, both pinned in "the shipped defaults"
# below. What the timed examples prove is the SHAPE -- error at the grace, not
# at the timeout; silence before the first byte exempt; one connection, not four.
RSpec.describe "stalled-stream protection", :seam do
  let(:grace) { 0.3 }
  let(:wire) { StreamingUpstream::Wire }
  let(:alpha) { wire.ollama_content("alpha") }
  let(:beta) { wire.ollama_content("beta") }
  let(:done) { wire.ollama_done(text_response("")) }
  let(:stall_error) { Lain::Provider::HTTP::Streaming::StalledStreamError }
  let(:clock_class) { Lain::Provider::HTTP::Streaming::StallClock }
  let(:stalls_after_two_chunks) { StreamingUpstream.script.chunks(alpha, beta).stall }

  # The shipped envelope with only this card's two numbers moved: a request
  # timeout short enough that "well before it" is observable inside the
  # watchdog's 30s budget, and a grace short enough to trip once per example.
  # `zero_retry_config` keeps the production retry BUDGET (3) while sleeping
  # zero between attempts -- so "one connection" below is a live budget going
  # unspent, not a disabled one.
  def ollama_config(url, stall: grace, request_timeout: 5, max_retries: nil)
    zero_retry_config(max_retries:).tap do |config|
      config.ollama_api_base = url
      config.request_timeout = request_timeout
      config.stream_stall_timeout = stall
    end
  end

  def ollama_transport(upstream, **) = Lain::Provider::Ollama::Transport.new(ollama_config(upstream.url, **))

  def ollama_payload = { "model" => "qwen3:4b", "messages" => [{ "role" => "user", "content" => "hi" }] }

  # @return [Hash] what ended the stream, how long it took, and the chunks that
  #   reached the caller. All three matter: a stall is a claim about WHEN an
  #   error arrives, and an error with no chunks behind it is a different defect
  #   from one that arrived mid-generation.
  def stream_outcome(transport, payload = ollama_payload)
    chunks = []
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = capture { transport.stream(payload) { |chunk| chunks << chunk } }
    { error:, seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, chunks: }
  end

  # Whatever ended the round trip, or nil. Returned rather than raised, so an
  # example can assert on the error AND on the time it took to arrive -- which
  # `expect { }.to raise_error` cannot do in one breath.
  def capture
    yield
    nil
  rescue StandardError => e
    e
  end

  # Through the real NDJSON assembler, so "the stream completed" means the body
  # a provider would decode, not merely that bytes arrived.
  def assembled(chunks)
    assembler = Lain::Provider::Ollama::StreamAssembler.new
    chunks.each { |chunk| assembler.feed(chunk) }
    assembler.result.dig("message", "content")
  end

  describe "a stream that stops emitting" do
    it "raises an error naming the stalled stream" do
      outcome = nil
      StreamingUpstream.ndjson(stalls_after_two_chunks) { |up| outcome = stream_outcome(ollama_transport(up)) }

      expect(outcome[:error]).to be_a(stall_error).and(have_attributes(message: /stalled stream/))
    end

    it "errors at the grace rather than waiting out the request timeout" do
      outcome = nil
      StreamingUpstream.ndjson(stalls_after_two_chunks) do |up|
        outcome = stream_outcome(ollama_transport(up, request_timeout: 5))
      end

      expect(outcome[:seconds]).to be_between(grace, 2.0)
    end

    it "still hands over the chunks that arrived before the silence" do
      outcome = nil
      StreamingUpstream.ndjson(stalls_after_two_chunks) { |up| outcome = stream_outcome(ollama_transport(up)) }

      expect(outcome[:chunks]).to eq([alpha, beta])
    end

    # The card's central decision, proved behaviourally: the retry budget is the
    # shipped 3 and `:post` is in `retry_options[:methods]`, so a stall raised as
    # a listed exception would show four connections here -- F7a multiplied
    # rather than fixed.
    it "makes exactly one connection, because a stall is not retried" do
      connections = nil
      StreamingUpstream.ndjson(stalls_after_two_chunks) do |up|
        stream_outcome(ollama_transport(up))
        connections = up.requests.size
      end

      expect(connections).to eq(1)
    end
  end

  describe "a slow but living stream" do
    let(:trickle) { StreamingUpstream.script.chunk(alpha).pause(0.1).chunk(beta).pause(0.1).chunk(done).close }

    it "completes when every gap is under the grace" do
      outcome = nil
      StreamingUpstream.ndjson(trickle) { |up| outcome = stream_outcome(ollama_transport(up)) }

      expect([outcome[:error], assembled(outcome[:chunks])]).to eq([nil, "alphabeta"])
    end
  end

  # The decided split, and the reason this card cannot regress a slow start: all
  # of a local model's legitimate silence falls BEFORE the first token, so the
  # clock arms on the first byte and nothing sooner.
  describe "a long silence before the first byte" do
    let(:thinks_first) { StreamingUpstream.script.pause(0.9).chunks(alpha, done).close }

    it "streams normally after a silence three times the inter-chunk grace" do
      outcome = nil
      StreamingUpstream.ndjson(thinks_first) { |up| outcome = stream_outcome(ollama_transport(up)) }

      expect([outcome[:error], assembled(outcome[:chunks])]).to eq([nil, "alpha"])
    end

    # Without this the example above passes whether or not the pause is real,
    # and the whole first-byte/inter-chunk distinction goes untested.
    it "really did spend that silence waiting" do
      outcome = nil
      StreamingUpstream.ndjson(thinks_first) { |up| outcome = stream_outcome(ollama_transport(up)) }

      expect(outcome[:seconds]).to be >= 0.9
    end
  end

  describe "when stall protection is disabled" do
    # `nil` is the off switch, and it takes the middleware out of the stack
    # entirely rather than arming a clock that never fires. The dwell below is
    # five graces, and what finally ends it is the request timeout -- exactly
    # what ended it before this card existed.
    def disabled_outcome(upstream)
      stream_outcome(ollama_transport(upstream, stall: nil, request_timeout: 1.5, max_retries: 0))
    end

    it "raises no stalled-stream error while the socket stays quiet" do
      outcome = nil
      StreamingUpstream.ndjson(stalls_after_two_chunks) { |up| outcome = disabled_outcome(up) }

      expect(outcome[:error]).to be_a(Faraday::TimeoutError)
    end

    it "waits several times the grace before anything ends it" do
      outcome = nil
      StreamingUpstream.ndjson(stalls_after_two_chunks) { |up| outcome = disabled_outcome(up) }

      expect(outcome[:seconds]).to be >= 1.5
    end
  end

  # Two operator inputs that the generated setter would have accepted and the
  # clock would then have answered catastrophically. `0` is the universal "no
  # timeout" idiom, so it is the value an operator reaches for to turn this OFF
  # -- under `idle > grace` it would instead have killed every stream at its
  # first byte. A non-numeric would have raised a bare ArgumentError from inside
  # the Faraday stack, above `wrapping_errors` and below every `rescue` in the
  # codebase: the exact escape the stall error's own ancestry was chosen to
  # avoid.
  describe "an operator's mistakes at the knob" do
    let(:config) { Lain::Provider::HTTP::Configuration.new }

    it "reads a non-positive grace as OFF rather than as instant death" do
      config.stream_stall_timeout = 0
      negative = Lain::Provider::HTTP::Configuration.new
      negative.stream_stall_timeout = -5

      expect([config.stream_stall_timeout, negative.stream_stall_timeout]).to eq([nil, nil])
    end

    it "keeps a stream alive when the grace is zeroed, rather than killing it at the first byte" do
      outcome = nil
      script = StreamingUpstream.script.chunk(alpha).pause(0.05).chunk(done).close
      StreamingUpstream.ndjson(script) { |up| outcome = stream_outcome(ollama_transport(up, stall: 0)) }

      expect([outcome[:error], assembled(outcome[:chunks])]).to eq([nil, "alpha"])
    end

    it "refuses a grace that is not a number, where a human is still looking" do
      config.stream_stall_timeout = 12

      expect { config.stream_stall_timeout = "soon" }
        .to raise_error(ArgumentError, /LAIN_STREAM_STALL_TIMEOUT=0 disables/)
      expect(config.stream_stall_timeout).to eq(12)
    end

    it "takes a numeric string, because that is how the environment hands one over" do
      config.stream_stall_timeout = "45"

      expect(config.stream_stall_timeout).to eq(45.0)
    end
  end

  # The off switch has to be reachable: nothing outside `lib/` constructs a
  # Configuration, and unlike `request_timeout` -- which only fires when the
  # server never answered -- this knob can end a working generation.
  describe "the environment override" do
    it "takes its grace from LAIN_STREAM_STALL_TIMEOUT" do
      graces = with_env("LAIN_STREAM_STALL_TIMEOUT" => "7") do
        Lain::Provider::HTTP::Configuration.new.stream_stall_timeout
      end

      expect(graces).to eq(7.0)
    end

    it "reads zero there as the off switch" do
      disabled = with_env("LAIN_STREAM_STALL_TIMEOUT" => "0") do
        Lain::Provider::HTTP::Configuration.new.stream_stall_timeout
      end

      expect(disabled).to be_nil
    end
  end

  describe "the exception type" do
    # The structural half of "not retried": `retry_exceptions` holds
    # Faraday::TimeoutError and Timeout::Error, and `retry_options` retries
    # `:post`. Asserting the ancestry rather than the identity is what makes a
    # future subclass of a listed error fail here instead of in production.
    it "matches nothing in the stack's retry allowlist" do
      allowlist = Lain::Provider::HTTP::Connection::MiddlewareStack
                  .new(nil, Lain::Provider::HTTP::Configuration.new, sink: Lain::Sink::Null.new, log_level: :info)
                  .send(:retry_exceptions)

      expect(allowlist.select { |klass| stall_error <= klass }).to be_empty
    end

    # And the other side of the same choice: it IS a transport failure, so every
    # arm's `wrapping_errors` already covers it and a stalled summarizer degrades
    # like an unreachable one instead of escaping as a novel type.
    it "is a transport error the arms' own error contract already covers" do
      expect(stall_error.ancestors).to include(Lain::Provider::HTTP::Error)
    end
  end

  describe "the shipped defaults" do
    it "bounds inter-chunk silence at thirty seconds" do
      expect(Lain::Provider::HTTP::Configuration.new.stream_stall_timeout).to eq(30)
    end

    # Untouched on purpose. A local model that thinks for six minutes is a real
    # shape (provider/ollama.rb), and that silence is all pre-first-byte.
    it "leaves the first-byte budget at the request timeout it always had" do
      expect(Lain::Provider::HTTP::Configuration.new.request_timeout).to eq(300)
    end
  end

  # The grace measures the UPSTREAM's silence, and the consumer block runs on
  # the same thread between two chunks arriving. Measured before the clock
  # ticked on the way out as well as in: a body already sitting whole in the
  # receive queue was reported as "no bytes for 0.5s, with the connection still
  # open" purely because the caller slept inside `on_chunk`. The chunk callback
  # reaches the frontend, so this is a live path, not a hypothetical.
  describe "time the CALLER spends" do
    it "is not charged to the upstream" do
      outcome = nil
      dawdled = []
      script = StreamingUpstream.script.chunks(alpha, done).close
      StreamingUpstream.ndjson(script) do |up|
        transport = ollama_transport(up, stall: 0.2)
        outcome = capture { transport.stream(ollama_payload) { |_chunk| dawdle(dawdled) } }
      end

      expect([outcome, dawdled.size]).to eq([nil, 1])
    end

    # Once, on the first chunk, for well over the grace -- the rest of the body
    # is already in the receive queue by then, so the only silence is ours.
    def dawdle(record)
      record << sleep(0.5) if record.empty?
    end

    # The suspension is a COUNT rather than a flag, and this is the difference:
    # with a flag the inner delivery's `ensure` un-suspends the outer one, and
    # the monitor fires while the caller is still holding the chunk. Unreachable
    # from today's `on_data`, which never nests -- but a wrapper that fed a
    # sub-stream through the same clock would reach it, and an untested change is
    # what this chunk keeps finding.
    it "stays suspended through a NESTED delivery" do
      clock = clock_class.new(0.05)

      outcome = capture do
        clock.watch do
          clock.receiving do
            clock.receiving { nil }
            sleep(0.2)
          end
        end
      end

      expect(outcome).to be_nil
    end
  end

  # `Thread#raise` is asynchronous, so the monitor can fire in the instant
  # between the block returning and `#stop` taking the mutex. Both examples
  # drive that window deterministically through the injected `clock:` seam: the
  # lambda answers by THREAD, and parks the monitor's first reading -- which is
  # taken inside `sweep`, holding the same mutex `#stop` wants.
  describe "the teardown race" do
    # Reading by thread rather than by call count, because the monitor's first
    # sweep can land either side of `#receiving`'s resume and a counted gate
    # would be seed-dependent. The request thread always reads "no time has
    # passed"; the monitor reads "long past the grace", after parking once.
    def gated_clock(parked, release)
      parked_once = []
      lambda do
        monitor = Thread.current.name.to_s.start_with?(clock_class::THREAD_PREFIX)
        park(parked, release, parked_once) if monitor && parked_once.empty?
        monitor ? 1_000_000.0 : 0.0
      end
    end

    def park(parked, release, parked_once)
      parked_once << :parked
      parked << :parked
      release.pop
    end

    # Returns [what #watch answered, what the thread variable holds afterwards].
    def race_outcome
      parked = Queue.new
      release = Queue.new
      clock = clock_class.new(1.0, clock: gated_clock(parked, release))
      answer = capture_value(clock, parked, release)
      [answer, Thread.current.thread_variable_get(clock_class::VARIABLE)]
    end

    def capture_value(clock, parked, release)
      clock.watch do
        clock.receiving { nil }
        parked.pop
        release_once_the_request_is_in_stop(release)
        :stream_completed_normally
      end
    rescue StandardError => e
      e
    end

    # The block has returned by the time this fires, so the request thread is
    # blocked in #stop on the very mutex the parked monitor is holding.
    def release_once_the_request_is_in_stop(release)
      Thread.new do
        sleep(0.15)
        release << :go
      end
    end

    it "does not report a stream that COMPLETED as a stalled one" do
      expect(race_outcome.first).to eq(:stream_completed_normally)
    end

    # The mechanical half, and the one that must not regress: #stop raising
    # would otherwise abort #watch's ensure before the restore, leaking this
    # clock into the thread variable for the life of the thread -- and
    # Streaming#flush_stream calls on_data AFTER connection.post returns, so it
    # would tick a finished request's clock.
    it "restores the thread variable even when the teardown is what raised" do
      leaked = race_outcome.last
      unprotected = clock_class.watching(nil) { clock_class.current }

      expect([leaked, unprotected]).to eq([nil, clock_class::Null])
    end
  end

  describe "the monitor thread" do
    def live_clock_threads
      Thread.list.select { |thread| thread.name.to_s.start_with?(clock_class::THREAD_PREFIX) }
    end

    # The join is load-bearing HERE and nowhere else, which an earlier version
    # of this example got wrong: on the STALLED path the monitor has already
    # fired and left its own loop, so there is nothing to join and removing the
    # join is invisible. On a healthy stream the monitor is still asleep in
    # `sleep(poll_interval)` when the body ends -- a grace of 5 clamps the poll
    # to 0.5s and the body finishes well inside it -- so only `#watch`'s ensure
    # can have reaped it.
    #
    # No settle sleep, deliberately: the question is whether the thread is gone
    # at the instant the stream call RETURNS, which is exactly what the ensure
    # promises.
    it "is joined before a HEALTHY request returns, while it is still asleep" do
      survivors = nil
      script = StreamingUpstream.script.chunk(alpha).chunk(done).close
      StreamingUpstream.ndjson(script) do |up|
        stream_outcome(ollama_transport(up, stall: 5))
        survivors = live_clock_threads
      end

      expect(survivors).to be_empty
    end

    # A different property, and worth its own line: a monitor that FIRED leaves
    # its loop rather than sweeping on forever.
    it "leaves nothing behind after it has fired" do
      survivors = nil
      StreamingUpstream.ndjson(stalls_after_two_chunks) do |up|
        stream_outcome(ollama_transport(up))
        survivors = live_clock_threads
      end

      expect(survivors).to be_empty
    end

    # A survivor in a watchdog dump is unattributable when every clock thread in
    # the process shares one name. Read deterministically from inside the
    # monitor's own first clock reading, so there is no naming race to sleep on.
    def reporting_clock(observed)
      lambda do
        name = Thread.current.name.to_s
        observed << name if name.start_with?(clock_class::THREAD_PREFIX)
        0.0
      end
    end

    def monitor_name
      observed = Queue.new
      clock = clock_class.new(0.1, clock: reporting_clock(observed))
      clock.watch do
        clock.receiving { nil }
        observed.pop
      end
    end

    # Both halves matter. The request thread's id is what attributes a survivor
    # to a request; the clock's own is what keeps two SEQUENTIAL requests on one
    # thread apart -- and under `rake pspec` a worker is one process with one
    # main thread, so without it every clock thread in the worker collides.
    it "names itself after the request thread it is watching" do
      expect(monitor_name).to start_with("#{clock_class::THREAD_PREFIX} #{Thread.current.object_id}.")
    end

    it "gives two streams on the same thread different names" do
      expect(monitor_name).not_to eq(monitor_name)
    end
  end

  describe "what an operator sees" do
    it "surfaces through the arm's own error family, still naming the stall" do
      error = nil
      StreamingUpstream.ndjson(stalls_after_two_chunks) do |up|
        provider = Lain::Provider::Ollama.new(config: ollama_config(up.url))
        error = capture { provider.complete(streaming_request) }
      end

      expect(error).to be_a(Lain::Provider::Ollama::APIError).and(have_attributes(message: /stalled stream/))
    end

    def streaming_request
      Lain::Request.new(model: "qwen3:4b", max_tokens: 16,
                        messages: [{ role: "user", content: "hi" }], stream: true)
    end
  end

  # Both transports install their `on_data` through the same
  # FaradayHandlers.build and take their connection from the same
  # MiddlewareStack, so the clock is not an Ollama feature. This is the
  # difference stated as a test rather than as a comment.
  describe "the Anthropic transport" do
    let(:opening_frame) { wire.sse_frame("type" => "message_start", "message" => { "id" => "msg_stall" }) }

    def anthropic_transport(upstream)
      config = zero_retry_config.tap do |settings|
        settings.anthropic_api_key = "test-key"
        settings.anthropic_api_base = upstream.url
        settings.request_timeout = 5
        settings.stream_stall_timeout = grace
      end
      Lain::Provider::Anthropic::Transport.new(config)
    end

    it "bounds a stalled SSE stream the same way, on one connection" do
      outcome = nil
      connections = nil
      StreamingUpstream.sse(StreamingUpstream.script.chunk(opening_frame).stall) do |up|
        transport = anthropic_transport(up)
        outcome = capture { transport.stream({ "model" => "claude-probe", "messages" => [] }) { |_event| nil } }
        connections = up.requests.size
      end

      expect([outcome.class, connections]).to eq([stall_error, 1])
    end
  end
end
