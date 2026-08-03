# frozen_string_literal: true

# A stuck example is indistinguishable from a slow one, and that is the whole
# problem: a hung worker under `parallel_rspec` reports as FEWER EXAMPLES, ZERO
# FAILURES -- the same shape a healthy run has, only smaller. This suite has
# been bitten by that twice over: an editor example that ran 7m28s at ~0% CPU
# before a human noticed, and an async example that could only pass or wedge,
# whose killed run printed `1 example, 0 failures`.
#
# Note what the first one cost, because it is the argument for this file. Two
# confident diagnoses were offered and BOTH were wrong -- a mutex cycle across
# the RPC boundary, then a fiber parked in epoll -- and it took a third pass to
# find that a gem call made from inside an `Async` task takes a
# fiber-ownership branch that RAISES, swallowed and retried. Nobody had a stack
# to read, because the run never ended. That is the whole point: the report
# below is a thread dump taken while everything is still standing where it
# stopped.
#
# The budget is NOT a performance gate. Real examples here run in milliseconds
# -- p99 is comfortably under a second, and the slowest single example in the
# heaviest file is ~0.6s -- so anything near 30 seconds is not slow, it is
# stuck. This converts an unbounded hang into a bounded, LOUD failure that names
# what everything was waiting on.
#
# It is deliberately the OUTERMOST `around` hook, which is why spec_helper
# requires this file before the support glob: `around` hooks nest in definition
# order, and the hooks that spawn editors and daemons are themselves `around`s.
# A watchdog inside those would time the example body and miss a hang in the
# spawn.
module SpecWatchdog
  # Seconds. Overridable for runs that legitimately wait on somebody else's
  # network -- `:api_integration` hits a real API -- but never as a way to make a
  # slow example pass.
  BUDGET = Float(ENV.fetch("LAIN_SPEC_BUDGET", "30"))

  # Not a StandardError: a `rescue => e` inside an example must not be able to
  # swallow the report and let the run continue pretending.
  class Stuck < Exception; end # rubocop:disable Lint/InheritException

  # ONE supervisor for the whole process, watching a single slot the hook
  # rewrites per example -- not a thread per example, which would be thousands
  # of spawns to answer a question asked once a second. The slot needs no lock:
  # `parallel_tests` forks PROCESSES, so exactly one example is ever in flight
  # here, and the supervisor only ever reads.
  class Sentry
    # How often to look. Granularity against a 30s budget, and cheap.
    TICK = 1.0

    # Frames per thread: enough to see who holds what and who waits on it, short
    # enough that seven threads do not bury the sentence that matters.
    FRAMES = 25

    # What the hook publishes and the supervisor reads, swapped whole so a read
    # is one consistent snapshot rather than three fields that can disagree.
    Watch = Struct.new(:example, :started, :thread)

    def initialize(budget:)
      @budget = budget
      @watch = nil
      @supervisor = nil
    end

    def watch(example)
      @watch = Watch.new(example, now, Thread.current).freeze
      supervisor
      yield
    ensure
      @watch = nil
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def elapsed(watch) = now - watch.started

    # Started on the first example rather than at load, so a run that never
    # reaches one (a syntax error in a spec, `--dry-run`) spawns nothing. Ruby
    # kills it at exit, so it never holds the process open.
    def supervisor
      @supervisor ||= Thread.new do
        Thread.current.name = "spec-watchdog"
        loop do
          sleep(TICK)
          overdue = @watch
          strike(overdue) if overdue && elapsed(overdue) > @budget
        end
      end
    end

    # Cleared BEFORE raising, so a budget expiring again while the example
    # unwinds cannot fire twice into a thread already carrying the first. The
    # report is built here, in the supervisor, because raising unwinds the very
    # stacks worth reading.
    def strike(watch)
      @watch = nil
      watch.thread.raise(Stuck, diagnosis(watch))
    end

    def diagnosis(watch)
      ["STUCK: #{watch.example.location} ran #{elapsed(watch).round(1)}s against a #{@budget.round}s budget.",
       "This is a hang, not slowness -- p99 in this suite is under a second.",
       *editors, *threads].join("\n")
    end

    # The usual other half of a deadlock here. A live editor means the spawn
    # succeeded and the wait is on the wire, not on the process.
    def editors
      found = `ps -o pid,etimes,args -C nvim 2>/dev/null`.lines.drop(1)
      return ["No nvim child is alive, so the wait is not on the editor."] if found.empty?

      ["Live editors (pid, seconds, argv):", *found.map { |line| "  #{line.strip}" }]
    end

    def threads = Thread.list.flat_map { |thread| dump(thread) }

    def dump(thread)
      frames = thread.backtrace || ["(no backtrace -- never started, or already dead)"]
      ["Thread #{thread.name || thread.object_id} [#{thread.status || "dead"}]:",
       *frames.first(FRAMES).map { |frame| "  #{frame}" }]
    end
  end

  SENTRY = Sentry.new(budget: BUDGET)
end

RSpec.configure do |config|
  config.around { |example| SpecWatchdog::SENTRY.watch(example) { example.run } }
end
