# frozen_string_literal: true

require "async"
require "faraday"
require "pathname"
require "ripper"

# WHERE THE STALL CLOCK LIVES, which is a different question from what it does
# -- the grace, the first-byte exemption, the one connection and the shipped
# defaults are `spec/lain/provider/http/stall_protection_spec.rb`'s, and what a
# reactor adds is `spec/lain/seams/stall_under_reactor_spec.rb`'s. This file
# owns the SLOT.
#
# The slot is now the Faraday request context -- `env.request.context`, the same
# per-request hash `Ollama::Transport` threads `retry_attempt` through and
# `Anthropic::Transport` threads `wal_frame` through. `Faraday::Env#stream_response`
# calls `request.on_data.call(chunk, size, self)`, so a body chunk arrives
# carrying its own env and the clock can be read off the request the BYTES
# belong to.
#
# What that buys over the fiber storage it replaces is not concurrency -- fiber
# storage plus an ownership check already gave two sibling streams a clock each
# -- it is the removal of a load-bearing assumption nothing could enforce: that
# the Faraday adapter dispatches `on_data` on the fiber that called it. It is
# true of `:net_http` and `faraday_adapter` is a configuration option, so an
# adapter that ran the body callback on a fiber of its own turned stall
# protection silently OFF with a green suite. A context travels with the env
# rather than with the caller, so those examples are here as the statement that
# the question no longer exists.
#
# Nothing here opens a socket: the subject is which clock a chunk reaches, and
# the handler takes its env as an argument. The timed examples use graces an
# order of magnitude apart from their sleeps, because this box runs several
# suites at once.
RSpec.describe Lain::Provider::HTTP::Streaming::FaradayHandlers do
  let(:clock_class) { Lain::Provider::HTTP::Streaming::StallClock }
  let(:stall_error) { Lain::Provider::HTTP::Streaming::StalledStreamError }

  # Shaped the way `stream_response` hands one to `on_data`: a status, and a
  # RequestOptions of its own -- which IS a request's identity here, because it
  # is what carries the context. `Env.from` copies the options it is given, so
  # every caller reads `env.request` back rather than keeping its own reference.
  def env(status: 200)
    Faraday::Env.from(status:, request: Faraday::RequestOptions.new)
  end

  def handler(chunks: [], failures: [])
    described_class.build(on_chunk: ->(chunk, _env) { chunks << chunk },
                          on_failed_response: ->(chunk, _env) { failures << chunk })
  end

  # Returned rather than raised, so an example can assert on the error AND on
  # what the stream delivered in one breath.
  def capture
    yield
    nil
  rescue StandardError => e
    e
  end

  # A REAL clock that also says when it was ticked. A partial double rather than
  # a subclass, because everything else about it -- the monitor, the suspension
  # count, the teardown -- has to stay genuinely the clock's own for the timed
  # examples below to mean anything.
  def recording(clock, log)
    allow(clock).to receive(:receiving).and_wrap_original do |original, &block|
      log << :tick
      original.call(&block)
    end
    clock
  end

  describe "two streams alive at once" do
    # The property fiber storage could only approximate: attribution does not
    # depend on the caller at all, so ONE fiber delivering both streams' chunks
    # still charges each chunk to its own request. Under an ambient slot this
    # example is not even expressible -- there is one slot per fiber to ask.
    it "charges a chunk to the clock of the request it arrived with, not the caller's" do
      first = env
      second = env
      first_ticks = []
      second_ticks = []
      deliver = handler

      recording(clock_class.new(5), first_ticks).watch(first) do
        recording(clock_class.new(5), second_ticks).watch(second) do
          deliver.call("a", 1, first)
          deliver.call("b", 1, second)
          deliver.call("c", 1, first)
        end
      end

      expect([first_ticks.size, second_ticks.size]).to eq([2, 1])
    end

    # The card's scenario, run for real: two streams as sibling tasks on one
    # reactor, chunks interleaving because each gap is a scheduler yield. Neither
    # clock fires, and neither stream's bytes end up in the other's handler.
    it "lets two sibling tasks on one reactor interleave without either clock firing" do
      outcome = Sync do |task|
        [task.async { stream(%w[a b c]) }, task.async { stream(%w[x y z]) }].map(&:wait)
      end

      expect(outcome).to eq([[nil, %w[a b c]], [nil, %w[x y z]]])
    end

    # One whole stream: its own env, its own clock, its own chunks. The gap is a
    # twentieth of the grace, so nothing here is a race about time -- it is a
    # question about whose clock the sibling's chunk reset.
    def stream(chunks, grace: 1.0, gap: 0.05)
      delivered = []
      request = env
      deliver = handler(chunks: delivered)
      error = capture { clock_class.new(grace).watch(request) { trickle(deliver, chunks, request, gap) } }

      [error, delivered]
    end

    # The gap is a scheduler yield under `Sync`, which is what makes two streams'
    # chunks genuinely interleave rather than merely alternate.
    def trickle(deliver, chunks, request, gap)
      chunks.each do |chunk|
        deliver.call(chunk, 1, request)
        sleep(gap)
      end
    end
  end

  describe "a stream that goes silent" do
    # The teardown still happens, and still says which stream and for how long.
    # The sleep is well past the grace and gets interrupted, so the example costs
    # a fifth of a second rather than five.
    it "is torn down naming the stall and the silence" do
      request = env
      deliver = handler

      error = capture do
        clock_class.new(0.2).watch(request) do
          deliver.call("a", 1, request)
          sleep(5)
        end
      end

      expect(error).to be_a(stall_error)
        .and(have_attributes(message: /no bytes for \d+\.\ds, past the 0.2s stream_stall_timeout/))
    end
  end

  describe "a request nothing is watching" do
    # `Streaming#flush_stream` calls `on_data` AFTER `connection.post` returns,
    # and `Faraday::Response#finish` keeps the very Env the stack ran on -- so
    # the clock has to be taken back OUT of the context, not merely stopped.
    # Left in, a finished clock would be ticked by the flush and restart its own
    # monitor against a request that no longer exists.
    it "holds no clock once the watch that installed one has ended" do
      request = env
      clock_class.new(5).watch(request) { nil }

      expect(clock_class.for(request)).to be(clock_class::Null)
    end

    it "answers Null when no clock was ever installed" do
      expect(clock_class.for(env)).to be(clock_class::Null)
    end

    # The other `flush_stream` shape: `Faraday::Response#env` is nil until
    # `#finish` runs. The lookup answers Null rather than crashing, which leaves
    # the loud failure where `streaming_spec.rb` already pins it -- on the bare
    # `env.status` one line further down.
    it "answers Null for the nil env an unfinished response would hand the flush" do
      expect(clock_class.for(nil)).to be(clock_class::Null)
    end

    # And the caller's own context is handed back exactly as it was found, so a
    # clock cannot quietly delete a `retry_attempt` or a `wal_frame` a transport
    # put there.
    it "puts back the context it displaced, rather than a hash of its own" do
      request = env
      request.request.context = { wal_frame: :frame }

      clock_class.new(5).watch(request) { nil }

      expect(request.request.context).to eq({ wal_frame: :frame })
    end

    # The one above is not enough, because a REQUEST's context is not the
    # request's. `Connection#build_request` does `req.options = options.dup` and
    # `Faraday::Options` inherits Struct's SHALLOW dup, so every request shares
    # the CONNECTION's context object -- an in-place `context[KEY] = clock`
    # writes onto the connection, and the next request built from it starts life
    # holding a finished clock. Measured before this example existed: the leaked
    # key was present in a second request's context, and in the connection's own.
    #
    # Driven through the real middleware and a real Faraday stack, because the
    # thing under test is what `#call` does to the env Faraday handed it -- and
    # an in-place write is exactly the simplification a future reader will reach
    # for, so it has to fail here rather than look harmless.
    it "leaves the CONNECTION's own context alone, which every request shares by reference" do
      seeded = { wal_frame: :frame }
      connection = watched_connection(seeded)

      connection.get("/one")
      connection.get("/two")

      expect(connection.options.context).to eq(seeded)
    end

    def watched_connection(context)
      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.get("/one") { [200, {}, "a"] }
        stub.get("/two") { [200, {}, "b"] }
      end
      Faraday.new(request: { context: }) do |faraday|
        faraday.use(Lain::Provider::HTTP::Connection::MiddlewareStack::StallProtection, grace: 5)
        faraday.adapter(:test, stubs)
      end
    end
  end

  describe "an adapter that runs the body callback somewhere else" do
    # The assumption this card retires. Under fiber storage this answered Null on
    # every chunk and stall protection was silently off; the env carries the
    # clock, so where Faraday chose to run `on_data` stopped being a question.
    it "still finds the clock from a fiber that never watched anything" do
      request = env
      seen = nil

      clock_class.new(5).watch(request) { Fiber.new { seen = clock_class.for(request) }.resume }

      expect(seen).to be_a(clock_class)
    end

    # And the converse, which an ambient slot needed an ownership check to get
    # right: holding a clock is not contagious, because there is nothing ambient
    # to inherit.
    it "hands another request's env nothing, even inside a live watch" do
      watched = env
      stranger = env
      seen = nil

      clock_class.new(5).watch(watched) { seen = clock_class.for(stranger) }

      expect(seen).to be(clock_class::Null)
    end
  end

  # DECIDED, and pinned rather than left to be rediscovered: `stream_response`
  # ends a body that yielded nothing with `on_data.call(+"", 0, self)`, and that
  # empty chunk DOES tick the clock -- it goes through the same `#receiving` as
  # any other delivery, so it arms a monitor that has never been armed. It is
  # harmless because it arrives at the end of the body, milliseconds before
  # `#watch`'s ensure stops the clock, so the grace cannot elapse. Treating it as
  # liveness is also the honest reading: Faraday sends it exactly when the body
  # is over, which is the opposite of silence with the connection still open.
  # Unchanged by the move off fiber storage -- the old slot ticked it too.
  describe "the empty chunk that ends a body which yielded nothing" do
    it "ticks the clock as liveness, and nothing fires behind it" do
      request = env
      ticks = []
      clock = recording(clock_class.new(0.2), ticks)

      error = capture { clock.watch(request) { handler.call(+"", 0, request) } }

      expect([ticks.size, error]).to eq([1, nil])
    end
  end

  # A grep-shaped assertion, like `streaming_spec.rb`'s missing version
  # predicate: the absence IS the fact under test, and there is no code path left
  # to drive that would prove it. Comments are stripped first, so the prose above
  # explaining what the fiber slot cost is not banned from naming it.
  describe "the storage the clock uses" do
    def source_without_comments(file)
      Ripper.lex(file.read).each_with_object(+"") do |(_pos, type, tok, _state), stripped|
        stripped << (type == :on_comment ? tok.tr("^\n", " ") : tok)
      end
    end

    # Resolved from the LOADED method rather than by counting `..` up from
    # `__dir__`: a path walked by hand still points at a file when the file it
    # names is not the one running, so a stale-path version of this example stays
    # green against an implementation it never read.
    def handlers_source = Pathname(clock_class.instance_method(:watch).source_location.first)

    it "reaches for no fiber storage at all" do
      expect(source_without_comments(handlers_source)).not_to include("Fiber[")
    end
  end
end
