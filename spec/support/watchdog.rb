# frozen_string_literal: true

require "etc"

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
# stuck... ON AN UNSTARVED BOX. This converts an unbounded hang into a bounded,
# LOUD failure that names what everything was waiting on -- and, since
# 2026-08-23, says WHETHER it is a hang at all.
#
# That premise is FALSE under contention, and it produced exactly the
# misdiagnosis this file exists to prevent, one layer up: `git commit` runs
# rubocop and `parallel_rspec` together (`rake check`'s `multitask`, one rspec
# worker per core), which is real, structural CPU contention with no other
# agent required, and a `git` subprocess in a fixture's own setup was measured
# stalling 61s+ under it -- STARVED, not stuck. Because {Sentry} is
# deliberately the OUTERMOST `around` (below), that stall gets attributed to
# whichever example is CURRENT, which can be one whose own body never touches
# the code that actually stalled -- `docs/toolchain-traps.md` carries the two
# names this happened to. {Sentry::Starvation} is the fix: CPU time consumed
# across the watch window, against the box's own 1-minute load average, is the
# cheap signal that tells "nobody scheduled this process" apart from "this
# thread is genuinely wedged" -- and the report says which, then prints the
# dump either way, because it costs nothing and might be both.
#
# It is deliberately the OUTERMOST `around` hook, which is why spec_helper
# requires this file before the support glob: `around` hooks nest in definition
# order, and the hooks that spawn editors and daemons are themselves `around`s.
# A watchdog inside those would time the example body and miss a hang in the
# spawn. It is also why a stall in ANOTHER example's shared fixture setup (an
# `around` block nested inside this one) gets reported under THIS example's
# name -- the outermost position that makes the watchdog see everything is the
# same position that makes its report name whoever it was watching, not
# whoever was slow.
module SpecWatchdog
  # Seconds. Overridable for runs that legitimately wait on somebody else's
  # network -- `:api_integration` hits a real API -- but never as a way to make a
  # slow example pass. An example may carry its own `budget:` metadata, but only to
  # RAISE its limit: the larger of the two wins, so this env var is a floor.
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
    # is one consistent snapshot rather than fields that can disagree.
    # `cpu_started` rides beside `started` (wall clock) so a strike can charge
    # the WHOLE watch window's CPU consumption to the one example it watched,
    # the same way `started` already charges it the wall time.
    Watch = Struct.new(:example, :started, :cpu_started, :thread, :budget, :memory_started)

    # Answers one question a `Stuck` report could not ask before: did this
    # process get to RUN during the window it was charged for? A thread
    # genuinely wedged on a lock and a thread that was simply never scheduled
    # both show ~0 CPU, so that alone proves nothing -- {#reading} also reads
    # the box's own 1-minute load average, and calls it starvation only when
    # BOTH say so: little CPU consumed AND more runnable work than the box has
    # cores for. Either signal alone is not decisive (a genuinely wedged
    # process on an otherwise-idle box also shows ~0 CPU; a loaded box does not
    # mean THIS process was denied a core), which is why this is a
    # conjunction, not either check alone.
    #
    # Its own class, and injected into {Sentry} rather than read inline in
    # {Sentry#diagnosis}, so a spec can prove the verdict against a controlled
    # clock and a controlled load average without making a real thread starve
    # for 30 real seconds.
    class Starvation
      # Logical processors. A starvation heuristic does not need the
      # physical/logical distinction {Rakefile#physical_cores} draws for
      # worker-count tuning -- it only needs an order of magnitude to compare
      # `loadavg` against.
      CORES = Etc.nprocessors

      # A process that averaged less than a fifth of a core across the whole
      # watch window did not meaningfully run. Necessary, not sufficient --
      # see the class doc.
      CPU_SHARE_FLOOR = 0.2

      # "Multiples of the core count" (the diagnosis that started this): more
      # runnable work than the box has cores for is what actually denies a
      # process its turn, as opposed to a box that is merely busy.
      LOAD_FACTOR = 1.5

      # Percent of the watch window in which some task stalled on memory. A process in reclaim
      # shows the same near-zero CPU as one never scheduled, with an idle load average. Measured over
      # the window, not the kernel's avg10, which has already forgotten a stall that ended 10s ago.
      MEMORY_PRESSURE_FLOOR = 20.0

      # One verdict, carrying the numbers the report quotes rather than
      # forcing {Sentry} to re-derive them from a second call.
      Reading = Struct.new(:starved, :cpu_elapsed, :wall_elapsed, :load1, :cores, :memory_stall_percent,
                           keyword_init: true)

      # @param cores [Integer] overridable so a spec can name a small number
      #   and cross {LOAD_FACTOR} with an ordinary-looking `loadavg`
      # @param cpu_clock [#call] returns the process's consumed CPU seconds;
      #   real default is {Process::CLOCK_PROCESS_CPUTIME_ID}, whole-process
      #   rather than per-thread because `parallel_tests` forks PROCESSES and
      #   one example runs at a time in each -- the process's own CPU IS this
      #   example's CPU
      # @param load1_reader [#call] returns the 1-minute load average; real
      #   default reads `/proc/loadavg` and is Linux-only, guarded in
      #   {#read_load1} rather than here so the default stays a plain lambda
      # @param memory_reader [#call] returns the cumulative seconds some task has stalled on memory; real
      #   default reads the `some` total of `/proc/pressure/memory`, microseconds
      def initialize(cores: CORES,
                     cpu_clock: -> { Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) },
                     load1_reader: -> { File.read("/proc/loadavg").split.first.to_f },
                     memory_reader: lambda {
                       File.read("/proc/pressure/memory")[/^some .*total=(\d+)/, 1].to_i / 1_000_000.0
                     })
        @cores = cores
        @cpu_clock = cpu_clock
        @load1_reader = load1_reader
        @memory_reader = memory_reader
      end

      # @return [Float] CPU seconds the process has consumed so far, through
      #   the injected clock -- called once when a watch is armed and once
      #   when it strikes, so {Sentry} can charge the difference to the
      #   example it watched
      def cpu_now = @cpu_clock.call

      # @return [Float] cumulative memory stall seconds; 0.0 where the file is unreadable, so the
      #   window delta reads as no stall rather than as starvation
      def memory_now
        @memory_reader.call
      rescue SystemCallError
        0.0
      end

      # @param cpu_elapsed [Float] CPU seconds consumed across the watch
      #   window (the caller's `cpu_now` delta)
      # @param wall_elapsed [Float] wall seconds the watch ran
      # @param memory_elapsed [Float] memory stall seconds across the window (the `memory_now` delta)
      # @return [Reading]
      def reading(cpu_elapsed:, wall_elapsed:, memory_elapsed:)
        load1 = read_load1
        stall = memory_elapsed / wall_elapsed * 100
        Reading.new(cpu_elapsed:, wall_elapsed:, load1:, cores: @cores, memory_stall_percent: stall,
                    starved: starved?(cpu_elapsed:, wall_elapsed:, load1:, stall:))
      end

      private

      # An unreadable load average is `nil`, which reads as 0 here: it cannot prove load starvation,
      # but memory stalls are measured separately and may still prove it.
      def starved?(cpu_elapsed:, wall_elapsed:, load1:, stall:)
        (cpu_elapsed / wall_elapsed) < CPU_SHARE_FLOOR &&
          (load1.to_f > (@cores * LOAD_FACTOR) || stall >= MEMORY_PRESSURE_FLOOR)
      end

      # No `/proc` on a platform without it (macOS), and no standing on a box
      # where it is unreadable -- either way, "cannot tell" must not be read
      # as "yes it is starved", so {#starved?} treats a nil `load1` as no.
      def read_load1
        @load1_reader.call
      rescue SystemCallError
        nil
      end
    end

    def initialize(budget:, tick: TICK, starvation: Starvation.new)
      @budget = budget
      @tick = tick
      @starvation = starvation
      @watch = nil
      @supervisor = nil
    end

    def watch(example)
      budget = [example.metadata.fetch(:budget, 0), @budget].max
      @watch = Watch.new(example, now, @starvation.cpu_now, Thread.current, budget, @starvation.memory_now).freeze
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
          sleep(@tick)
          overdue = @watch
          strike_safely(overdue) if overdue && elapsed(overdue) > overdue.budget
        end
      end
    end

    # The supervisor is memoised, so an exception escaping it would leave every later hang unwatched;
    # a report that cannot be built still has to end the example.
    def strike_safely(watch)
      strike(watch)
    rescue StandardError => e
      watch.thread.raise(Stuck, "STUCK: #{watch.example.location} overran its budget; the report failed: " \
                                "#{e.class}: #{e.message}")
    end

    # Cleared BEFORE raising, so a budget expiring again while the example
    # unwinds cannot fire twice into a thread already carrying the first. The
    # report is built here, in the supervisor, because raising unwinds the very
    # stacks worth reading.
    def strike(watch)
      @watch = nil
      reading = reading(watch)
      excused = reading.starved && watch.example.metadata[:starvable]
      RSpec::Core::Pending.mark_pending!(watch.example, pending_message(watch, reading)) if excused
      watch.thread.raise(Stuck, diagnosis(watch, reading))
    end

    def pending_message(watch, reading) = "#{starved_line(reading)} Starvable: #{watch.example.metadata[:starvable]}"

    def diagnosis(watch, reading)
      [headline(watch), verdict(reading), *editors, *threads].join("\n")
    end

    def reading(watch)
      @starvation.reading(cpu_elapsed: @starvation.cpu_now - watch.cpu_started, wall_elapsed: elapsed(watch),
                          memory_elapsed: @starvation.memory_now - watch.memory_started)
    end

    def headline(watch)
      "STUCK: #{watch.example.location} ran #{elapsed(watch).round(1)}s against a #{watch.budget.round}s budget."
    end

    # The one sentence the report used to state as fact -- "this is a hang" --
    # now asked of {Starvation} first, because it is sometimes wrong. Either
    # way the numbers behind the verdict are printed, so a reader can check
    # the claim rather than take it on faith.
    def verdict(reading)
      reading.starved ? starved_line(reading) : hang_line(reading)
    end

    def starved_line(reading)
      format("STARVED, not necessarily stuck: this process used %<cpu>.1fs of CPU across %<wall>.1fs of wall " \
             "time (%<pct>d%% of one core), and the box's 1-minute load average is %<load1>.1f against " \
             "%<cores>d cores%<memory>s -- there was nowhere for this thread to run, genuinely blocked or not. " \
             "The dump below may say nothing about why.", cpu: reading.cpu_elapsed, wall: reading.wall_elapsed,
                                                          pct: cpu_percent(reading), load1: reading.load1.to_f,
                                                          cores: reading.cores, memory: memory_clause(reading))
    end

    def memory_clause(reading)
      return "" unless reading.memory_stall_percent >= Starvation::MEMORY_PRESSURE_FLOOR

      format(", and memory pressure had some task stalled for %<memory>.0f%% of the window",
             memory: reading.memory_stall_percent)
    end

    def hang_line(reading)
      "This is a hang, not slowness -- p99 in this suite is under a second. #{reading_detail(reading)}"
    end

    def reading_detail(reading)
      unless reading.load1
        return format("(%<cpu>.1fs CPU / %<wall>.1fs wall.)", cpu: reading.cpu_elapsed,
                                                              wall: reading.wall_elapsed)
      end

      format("(%<cpu>.1fs CPU / %<wall>.1fs wall, load1 %<load1>.1f/%<cores>d cores.)",
             cpu: reading.cpu_elapsed, wall: reading.wall_elapsed, load1: reading.load1, cores: reading.cores)
    end

    def cpu_percent(reading) = (reading.cpu_elapsed / reading.wall_elapsed * 100).round

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
