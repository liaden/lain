# frozen_string_literal: true

# A real {Lain::Provider::Ollama::RetryTap} that additionally registers a
# rollback on every attempt it opens, and records which round trip opened and
# abandoned one.
#
# It exists because the link T10 stands on -- Provider opens an attempt ->
# Transport puts it on the request context -> retry_block finds it THERE -- has
# no other observer. Nothing in `lib/` registers a rollback yet (T10 is what
# will), so without a tap that registers one for itself, every line of that
# chain can be deleted and the suite stays green. Measured: it did.
#
# INJECTED, never patched on afterwards. The Faraday middleware stack --
# `retry_block` included -- is snapshotted when the transport is built
# (`Connection#initialize`; its own docstring notes Faraday's builder is
# StackLocked after the first request), so a tap swapped onto a constructed
# Provider is never the one faraday-retry calls. That is why
# {Lain::Provider::Ollama} takes a `retries:`.
class TracingRetryTap < Lain::Provider::Ollama::RetryTap
  # Releases only once `count` round trips have opened, so an overlap is FORCED
  # rather than raced for. Measured why it has to be: under WebMock a severed
  # attempt fails with no I/O at all, so faraday-retry calls `retry_block` about
  # 5ms after the round trip opened and the sibling has not opened yet
  # (timeline: open alpha 17ms, retry alpha 22ms, open beta 23ms). A
  # sleep-and-hope example therefore passes against the instance-state design it
  # is supposed to refuse -- verified by mutating the tap and watching it stay
  # green.
  #
  # `count: 1` releases on arrival, which is the Null Object every non-concurrent
  # example gets.
  #
  # A miscounted latch RAISES, and it has to compute a deadline to do it.
  # `ConditionVariable#wait(lock, 5)` inside a `while` is not a bound: each
  # timeout re-enters the wait, so an arrival that never comes waits forever
  # (measured: still blocked at 14s with one arrival missing). What used to stop
  # it was {SpecWatchdog}'s 30s thread dump -- a loud outcome for the wrong
  # reason, and 30s of a suite that runs in 42. A monotonic deadline gives the
  # example an ordinary failure naming the count that was wrong.
  class Latch
    TIMEOUT_SECONDS = 5

    def initialize(count)
      @expected = count
      @count = count
      @lock = Mutex.new
      @released = ConditionVariable.new
    end

    def arrive
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT_SECONDS
      @lock.synchronize do
        @count -= 1
        @released.broadcast unless @count.positive?
        wait_until_released(deadline)
      end
    end

    private

    def wait_until_released(deadline)
      while @count.positive?
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise_miscount unless remaining.positive?

        @released.wait(@lock, remaining)
      end
    end

    def raise_miscount
      raise "TracingRetryTap::Latch expected #{@expected} round trips to open; " \
            "#{@expected - @count} did within #{TIMEOUT_SECONDS}s"
    end
  end

  attr_reader :opened, :abandoned

  # @param channel [#push] where the retry telemetry lands, as for the tap this
  #   subclasses; a {RecordingChannel} by default, since an example that traces
  #   rollbacks usually wants the events too.
  # @param arrivals [Integer] how many round trips must open before any of them
  #   proceeds; 1 for the ordinary single-round-trip case.
  def initialize(channel: RecordingChannel.new, arrivals: 1)
    super(channel:)
    @latch = Latch.new(arrivals)
    @opened = []
    @abandoned = []
    @lock = Mutex.new
  end

  # `Thread.current[:lain_spec_round_trip]` labels which round trip opened this
  # attempt, so a rollback firing against the WRONG one is visible as a tally
  # rather than merely as a count.
  def open_attempt(&on_abandon)
    label = Thread.current[:lain_spec_round_trip]
    @lock.synchronize { @opened << label }
    attempt = super(&-> { record_abandon(label, &on_abandon) })
    @latch.arrive
    attempt
  end

  private

  def record_abandon(label, &on_abandon)
    @lock.synchronize { @abandoned << label }
    on_abandon&.call
  end
end
