# frozen_string_literal: true

require "async"
require "faraday"

# F10, and its two halves are one defect: the stall clock was installed in a
# THREAD variable and raised into a THREAD, while the unit of work is a FIBER.
# Lain streams a parent turn and a subagent turn as sibling tasks on ONE reactor
# thread (`cli/repl.rb`'s `Sync`, `agent/tool_runner.rb#gather`'s fan-out), so
# two live streams shared one slot: the second `watch` displaced the first, the
# first's chunks then ticked the second's clock, and the displaced clock -- never
# ticked again -- fired against a stream that was perfectly healthy. `Thread#raise`
# then landed in the event loop's ROOT fiber, above every per-turn rescue, so one
# stalled stream ended the whole chat session rather than one turn.
#
# Fixing only the delivery leaves the displacement, and fixing only the scoping
# leaves the session kill, which is why both are pinned here together.
#
# The SLOT has moved once more since, off fiber storage and onto the Faraday
# request context, and the two describes below about WHOSE clock a chunk ticks
# are re-aimed at that. The reactor-shaped hazards are unchanged and are still
# pinned by the same real sockets -- what changed is that they are now
# structural. A clock is reached through the request its bytes belong to, so
# neither the reactor's scheduling nor the adapter's choice of dispatch fiber
# can decide which stream a tick belongs to, and an ownership check is no longer
# what stands between the two.
#
# Every example drives a REAL socket through {StreamingUpstream}, for the reason
# spec/lain/provider/http/stall_protection_spec.rb states: WebMock hands a
# stubbed body over as one chunk, and everything here is about the gaps between
# chunks. That sibling file owns the single-stream contract -- the grace, the
# first-byte exemption, the one connection, the shipped defaults. This file owns
# only what a reactor adds, and the last example is its control: the same stall,
# with no scheduler installed at all.
RSpec.describe "a stalled stream under an Async reactor", :seam do
  let(:grace) { 0.3 }
  let(:wire) { StreamingUpstream::Wire }
  let(:alpha) { wire.ollama_content("alpha") }
  let(:beta) { wire.ollama_content("beta") }
  let(:done) { wire.ollama_done(text_response("")) }
  let(:stall_error) { Lain::Provider::HTTP::Streaming::StalledStreamError }
  let(:clock_class) { Lain::Provider::HTTP::Streaming::StallClock }
  let(:api_error) { Lain::Provider::Ollama::APIError }
  let(:stalls) { StreamingUpstream.script.chunks(alpha, beta).stall }

  # The retry budget is spent to zero here on purpose, unlike the sibling file:
  # what a stall does to a RETRY is pinned there, and leaving the budget live
  # would only make a red run four request timeouts long.
  def ollama_config(url, stall: grace, request_timeout: 1.5)
    zero_retry_config(max_retries: 0).tap do |config|
      config.ollama_api_base = url
      config.request_timeout = request_timeout
      config.stream_stall_timeout = stall
    end
  end

  def transport(upstream, **) = Lain::Provider::Ollama::Transport.new(ollama_config(upstream.url, **))

  def payload = { "model" => "qwen3:4b", "messages" => [{ "role" => "user", "content" => "hi" }] }

  # A clock is installed on a REQUEST, so the examples that drive one directly
  # rather than through a socket need an env of their own -- shaped the way
  # `Faraday::Env#stream_response` hands one to `on_data`.
  def stream_env = Faraday::Env.from(status: 200, request: Faraday::RequestOptions.new)

  def streaming_request
    Lain::Request.new(model: "qwen3:4b", max_tokens: 16,
                      messages: [{ role: "user", content: "hi" }], stream: true)
  end

  # Whatever the block answered, or whatever ended it. Returned rather than
  # raised, because every question here is about which of two concurrent streams
  # an error belongs to -- and `raise_error` cannot say that.
  def settle
    yield
  rescue StandardError => e
    e
  end

  # @return [Array(StandardError, nil), String] what ended this stream, and the
  #   body a provider would decode from what reached the caller. Both halves
  #   matter: "the sibling survived" is a claim about its CONTENT, not merely
  #   about the absence of an exception.
  def stream(transport)
    chunks = []
    ended = settle do
      transport.stream(payload) { |chunk| chunks << chunk }
      nil
    end
    [ended, assembled(chunks)]
  end

  def assembled(chunks)
    assembler = Lain::Provider::Ollama::StreamAssembler.new
    chunks.each { |chunk| assembler.feed(chunk) }
    assembler.result.dig("message", "content")
  end

  # Two upstreams on two ports, two sibling tasks on ONE reactor -- the shape a
  # parent turn and a subagent turn have. The first script is watched first, so
  # its clock is the one the second displaced.
  def siblings(first_script, second_script)
    outcomes = nil
    StreamingUpstream.ndjson(first_script) do |one|
      StreamingUpstream.ndjson(second_script) do |two|
        outcomes = concurrently(transport(one), transport(two))
      end
    end
    outcomes
  end

  # ⚠️ The transports are built OUT HERE, and nothing inside a task may touch a
  # `let`. `ThreadsafeMemoized#fetch_or_store` holds its mutex across the whole
  # `let` BODY, so one `let` that blocks -- a socket read, a stalling stream --
  # serialises every other first-time `let` read on that thread, sibling fibers
  # included. Measured: a trivial `let` read from one fiber took the 0.4s a
  # blocking `let` in another was spending. Nothing about it is a re-entrancy
  # bug: `RSpec::Support::ReentrantMutex` gates on `Mutex#owned?` on every Ruby
  # >= 3.0, which is per-FIBER, so a sibling fiber waits its turn properly.
  #
  # The symptom is what to recognise it by, because none of the above appears in
  # it: a 30s watchdog strike whose backtrace names the reactor and never names
  # memoization. Once, here, it surfaced instead as `ThreadError: Attempt to
  # unlock a mutex which is locked by another thread/fiber` -- which is
  # `ReentrantMutex#exit`'s own raise when the fiber running the `ensure` does
  # not hold the lock. That was seen a single time and the path that produced it
  # was never pinned; it is recorded because it is what a reader may be staring
  # at, NOT because it follows from anything above.
  #
  # An artefact of the harness, not of the subject -- but one with no bound on
  # it, so keep every memoized read on the main fiber.
  def concurrently(*transports)
    Sync do |task|
      transports.map { |transport| task.async { stream(transport) } }.map(&:wait)
    end
  end

  describe "two concurrent streams, one of them stalling" do
    let(:healthy) { StreamingUpstream.script.chunk(alpha).pause(0.1).chunk(beta).pause(0.1).chunk(done).close }

    # A method rather than a `let`: its body opens two sockets and runs a whole
    # reactor session, which is the shape the ⚠️ above warns about one level up.
    def outcomes = siblings(stalls, healthy)

    it "raises the stall in the fiber that owns the dead stream" do
      expect(outcomes.first.first).to be_a(stall_error).and(have_attributes(message: /stalled stream/))
    end

    it "lets the sibling finish with all of its content" do
      expect(outcomes.last).to eq([nil, "alphabeta"])
    end
  end

  # The displacement on its own, with nothing stalled anywhere. Every gap in the
  # slow stream is well inside its grace, so the only thing that can end it is a
  # clock that stopped being ticked.
  #
  # NON-LIFO completion is what does it, and the order here is the whole point:
  # the BRIEF stream watches first, the slow one's watch displaces its clock, and
  # then the brief one finishes FIRST and restores what IT displaced -- which was
  # nothing. The slow stream's own clock is wiped out of the slot while it is
  # still streaming, never ticked again, and fires a grace later against a stream
  # that is alive and well. A single shared slot can only be restored correctly
  # when watches nest, and sibling tasks on one reactor do not nest.
  describe "a slow stream beside one that has already finished" do
    let(:grace) { 0.5 }
    let(:trickle) do
      StreamingUpstream.script
                       .chunk(alpha).pause(0.2).chunk(beta).pause(0.2)
                       .chunk(beta).pause(0.2).chunk(beta).pause(0.2).chunk(done).close
    end

    # Long enough that the slow stream is already armed when the slot is handed
    # back, which is what makes the wipe observable rather than merely present.
    let(:brief) { StreamingUpstream.script.pause(0.15).chunks(alpha, done).close }

    it "is not killed by the clock its sibling left behind" do
      expect(siblings(brief, trickle).last).to eq([nil, "alphabetabetabeta"])
    end
  end

  # A body callback does not have to arrive on the fiber that made the request,
  # and this is the pair of examples that used to say so the other way round.
  # While the clock lived in fiber storage the slot was INHERITED copy-on-write
  # by every fiber and thread born under a live watch, so a child held its
  # parent's clock without ever having watched it -- and the fix for that, an
  # ownership check keyed on the watching fiber, made the ADAPTER's choice of
  # dispatch fiber load-bearing. `faraday_adapter` is a configuration option, and
  # an adapter running the body callback somewhere of its own then answered Null
  # on every chunk: stall protection silently off, with a green suite, measured
  # at 0.4s of silence against a 0.15s grace and undetected.
  #
  # On the request context neither half is a question. A clock is found by the
  # request a caller HOLDS, so a child that holds the request finds it wherever
  # it is running, and a child that holds a different one finds nothing without
  # anybody having to check who watched what.
  describe "a clock reached from a fiber that never watched it" do
    # All three creation paths, because each is a real route rather than a
    # variation: `Thread.new` is the one the clock's own monitor takes,
    # `Fiber.new` is what an adapter would use, and `task.async` is the reactor's
    # own. `clock_class` is resolved before the reactor, for the reason the ⚠️
    # above gives.
    def through_every_child(klass)
      Sync do |task|
        request = stream_env
        child = -> { yield(klass, request) }
        klass.new(5).watch(request) do
          [task.async { child.call }.wait, Fiber.new { child.call }.resume, Thread.new { child.call }.value]
        end
      end
    end

    # Holding the streaming request, which is what an adapter dispatching
    # `on_data` elsewhere would be handed along with the chunk.
    def child_holding_the_request = through_every_child(clock_class) { |klass, request| klass.for(request) }

    # Holding somebody else's, which is every other fiber in the process.
    def child_holding_another = through_every_child(clock_class) { |klass, _request| klass.for(stream_env) }

    it "hands every child the watching clock, wherever the adapter ran it" do
      expect(child_holding_the_request).to all(be_a(clock_class))
    end

    it "hands a child carrying another request nothing at all" do
      expect(child_holding_another).to all(eq(clock_class::Null))
    end
  end

  # The property the two wrong slots were both getting wrong, stated where it is
  # real: two live streams whose chunks genuinely interleave on one reactor
  # thread. Neither clock fires, and neither stream is short of its own content
  # -- which together are "each stream ticked its own clock" as an observation of
  # the streams rather than as a peek at the storage holding their clocks.
  #
  # Every gap is well inside the grace, so nothing here is a race about time.
  describe "two healthy streams interleaving" do
    let(:grace) { 0.5 }
    let(:trickle) { StreamingUpstream.script.chunk(alpha).pause(0.15).chunk(beta).pause(0.15).chunk(done).close }
    let(:offset) do
      StreamingUpstream.script.pause(0.1).chunk(beta).pause(0.15).chunk(alpha).pause(0.15).chunk(done).close
    end

    it "lets both finish, each with its own content" do
      expect(siblings(trickle, offset)).to eq([[nil, "alphabeta"], [nil, "betaalpha"]])
    end
  end

  # The session kill. `Thread#raise` on a reactor thread lands wherever that
  # thread happens to be -- which, while the request fiber is parked in the
  # socket read, is the event loop's own root fiber, outside every rescue the
  # turn is wrapped in. The turn must fail; the reactor must not.
  describe "a stall inside a reactor" do
    let(:turn) { stalled_turn }

    def stalled_turn
      inner = nil
      escaped = nil
      StreamingUpstream.ndjson(stalls) do |up|
        provider = Lain::Provider::Ollama.new(config: ollama_config(up.url))
        escaped = settle do
          Sync { |task| inner = task.async { settle { provider.complete(streaming_request) } }.wait }
          nil
        end
      end
      { escaped:, inner: }
    end

    it "fails the turn through the arm's own error family, and not the reactor" do
      expect([turn[:escaped], turn[:inner].class]).to eq([nil, api_error])
    end

    it "surfaces as a Lain::Error still naming the stall" do
      expect(turn[:inner]).to be_a(Lain::Error).and(have_attributes(message: /stalled stream/))
    end
  end

  # `Fiber.scheduler#fiber_interrupt` is DEFERRED: the reactor delivers when it
  # next resumes the fiber, and a queued interrupt cannot be recalled. So a
  # stream that completes in the very instant its grace expires has an interrupt
  # in flight with nowhere legitimate to land -- and without a disarm it lands in
  # the fiber's NEXT piece of work, which is the next tool call or the next turn.
  #
  # The window is driven through the injected `clock:` seam: the monitor alone
  # reads "long past the grace", so it fires on the first sweep that finds the
  # delivery unsuspended. What makes THIS the uncollected case, and not the
  # thread-race the sibling file already pins, is the wait: the fiber spins on
  # `Thread.pass` instead of sleeping, so it never reaches the event loop between
  # the fire and the end of the teardown. A `sleep` here would take delivery of
  # the interrupt by accident and the example would pass with the disarm removed.
  describe "a stream that completes in the instant its grace expires" do
    # The monitor's own thread, captured from inside its first clock reading. It
    # fires and then leaves its loop, so "captured and no longer alive" is
    # exactly "the interrupt has been queued", read without a sleep.
    def expired_clock(monitor)
      lambda do
        monitor << Thread.current if monitor? && monitor.empty?
        monitor? ? 1_000_000.0 : 0.0
      end
    end

    def monitor? = Thread.current.name.to_s.start_with?(clock_class::THREAD_PREFIX)

    def fired?(monitor) = monitor.any? && !monitor.first.alive?

    # Bounded, because a spin that never ended would be a hang rather than a
    # failure -- and the deadline is far longer than the one poll interval this
    # actually takes.
    def spin_until_fired(monitor)
      giving_up = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      Thread.pass until fired?(monitor) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > giving_up
    end

    def raced_watch(clock, monitor)
      clock.watch(stream_env) do
        clock.receiving { nil }
        spin_until_fired(monitor)
        :stream_completed_normally
      end
    end

    # @return [Array] what the completed watch answered, and what the fiber's
    #   NEXT blocking work saw -- which is where an uncollected interrupt lands.
    def outcome
      Sync do
        monitor = []
        clock = clock_class.new(0.1, clock: expired_clock(monitor))
        [settle { raced_watch(clock, monitor) }, settle { later_work }]
      end
    end

    def later_work
      sleep(0.2)
      :later_work_finished
    end

    it "answers normally and leaves the fiber's later work alone" do
      expect(outcome).to eq(%i[stream_completed_normally later_work_finished])
    end
  end

  # The control, and the reason the fix is two branches rather than one: with no
  # scheduler installed there is no fiber to interrupt, the clock raises into the
  # thread exactly as it always did, and every promise the sibling file makes
  # still holds.
  describe "with no reactor at all" do
    it "still raises the arm's API error naming the stall" do
      error = nil
      StreamingUpstream.ndjson(stalls) do |up|
        provider = Lain::Provider::Ollama.new(config: ollama_config(up.url))
        error = settle { provider.complete(streaming_request) }
      end

      expect([Fiber.scheduler, error])
        .to match([nil, a_kind_of(api_error).and(having_attributes(message: /stalled stream/))])
      # T5: and the stall is still ON that error's cause chain, which is the ONLY
      # place it survives -- it is not a {Lain::Error}, so `wrapping_errors`
      # re-raises it as the arm's APIError and {CLI::Repl::Ask#refuse} classifies
      # off the chain. A re-raise that dropped the cause would leave `ask_spec`
      # green (it builds the caused error itself) while every stalled run in the
      # record read `:torn` and F26 went back to being untriageable.
      expect(Enumerator.produce(error, &:cause).take_while(&:itself)).to include(a_kind_of(stall_error))
    end
  end
end
