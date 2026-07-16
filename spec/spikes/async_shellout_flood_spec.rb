# frozen_string_literal: true

require "async"
require "mixlib/shellout"
require "rbconfig"

# 5-0.3 re-verify: 5-0.1 proved Mixlib::ShellOut cooperates with the fiber
# scheduler for an *idle* child (its IO.select / Process.waitpid2 wait), but
# explicitly did NOT measure a stdout-FLOODING child -- chunked read_nonblock
# under pipe-buffer backpressure, a different code path in unix.rb. This spec
# closes that gap: a child streams ~10MB to stdout inside the reactor while a
# heartbeat fiber ticks every 50ms, and we assert the heartbeat's latency stays
# under a PINNED bound rather than stalling for the flood's duration.
#
# The bound, and its rationale (see docs/concurrency.md's dated 5-0.3 entry):
# the ticker's baseline period is 50ms (the 5-0.1 interval). A cooperative
# reactor delivers ticks at ~50ms throughout the flood; a reactor STARVED by a
# non-yielding read loop delivers one tick, then a single gap the size of the
# whole flood window (~1.2s here). The pinned ceiling is 150ms == 3x the 50ms
# baseline: above measured scheduler jitter (worst observed ~72ms, ~1.5x) with
# ~2x headroom, and an order of magnitude below the ~1.2s stall a starved
# reactor would show. So it fails loudly on a real stall without flaking on
# jitter. "Bounded" is thus a number, not a mood.
RSpec.describe "Async x Mixlib::ShellOut under stdout flood", :spike do
  # Pinned at measurement time (see docs/concurrency.md's 5-0.3 entry):
  #   ruby 4.0.5, async 2.42.0, mixlib-shellout 3.4.10
  let(:tick_interval) { 0.05 }
  let(:tick_count) { 40 }
  let(:latency_ceiling_ms) { 150 }

  # ~10MB streamed to stdout as a sustained trickle over ~1.2s: 200 chunks of
  # 50KB (each larger than the ~64KB pipe buffer's drain granularity) with a 5ms
  # pause between them. This keeps Mixlib::ShellOut's chunked read_nonblock loop
  # under real backpressure across a window many ticks wide -- long enough that a
  # starved reactor would show an unmistakable multi-tick stall. A one-shot 10MB
  # write drains in ~30ms, shorter than a single tick, so it could not tell a
  # cooperative reactor from a starved one; the trickle is what makes the bound
  # non-vacuous, and it also mirrors how real `bash` output arrives (a trickle
  # over a pipe -- see docs/concurrency.md's opening).
  def flood_command
    %(#{RbConfig.ruby} -e '200.times { STDOUT.write("x" * 50_000); sleep 0.005 }')
  end

  # Streams the flood and returns [start, finish] monotonic timestamps
  # bracketing the child's entire run_command call, plus the bytes captured.
  def run_flood
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    shell = Mixlib::ShellOut.new(flood_command, timeout: 30)
    shell.run_command
    [start, Process.clock_gettime(Process::CLOCK_MONOTONIC), shell.stdout.bytesize]
  end

  # The heartbeat: ticks a monotonic timestamp into `ticks` every tick_interval,
  # tick_count times -- the pure-Ruby fiber racing the flooding shellout.
  def run_heartbeat(ticks)
    tick_count.times do
      ticks << Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep tick_interval
    end
  end

  def run_workload
    ticks = []
    outcome = nil
    Async do |task|
      flood = task.async { run_flood }
      heartbeat = task.async { run_heartbeat(ticks) }
      outcome = flood.wait
      heartbeat.wait
    end
    [ticks, outcome]
  end

  it "keeps heartbeat latency under the pinned ceiling while ~10MB floods stdout" do
    ticks, (start, finish, bytes) = run_workload
    during = ticks.grep(start..finish)
    gaps_ms = during.each_cons(2).map { |a, b| (b - a) * 1000 }

    expect(bytes).to be >= 10_000_000

    # Non-vacuous distinguishing check: a cooperative reactor lands many ticks
    # inside the flood window (~25 of them here); a starved one lands ~1, because
    # the read loop never yields the OS thread back. Mirrors 5-0.1's threshold.
    expect(during.size).to be >= (tick_count / 3)

    # The pinned latency bound. Every inter-tick gap during the flood stays
    # within 3x the 50ms baseline; a starved reactor would show one gap the size
    # of the whole flood window (~1.2s), which is ~8x this ceiling.
    expect(gaps_ms.max).to be <= latency_ceiling_ms
  end
end
