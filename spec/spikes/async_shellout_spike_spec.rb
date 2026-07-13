# frozen_string_literal: true

require "async"
require "mixlib/shellout"

# 5-0.1: does Mixlib::ShellOut's internal IO.select (unix.rb ~line 282) and
# Process.waitpid2 (unix.rb ~line 406) stall the single OS thread an Async
# reactor runs on, or does Ruby's fiber scheduler hook those calls so other
# tasks keep making progress? This is measured, not assumed -- see
# docs/concurrency.md for the reasoning that made the question load-bearing.
#
# Both scenarios below run the SAME workload: one task shells out to `sleep
# 1s`, a second task ticks a monotonic timestamp into an array every 50ms.
# Only one can be true of a given (ruby, async, mixlib-shellout) triple, so
# only one scenario is committed passing; see the pinned versions below.
RSpec.describe "Async x Mixlib::ShellOut", :spike do
  # Pinned at measurement time (see docs/concurrency.md for the dated entry):
  #   ruby 4.0.5, async 2.42.0, mixlib-shellout 3.4.10
  let(:tick_interval) { 0.05 }
  let(:tick_count) { 30 }

  # Runs the shellout task and returns its [start, finish] monotonic
  # timestamps, bracketing the `sleep 1` child process's entire
  # run_command call.
  def run_shellout
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Mixlib::ShellOut.new("sleep 1").run_command
    [start, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
  end

  # Ticks a monotonic timestamp into `ticks` every tick_interval, tick_count
  # times -- the pure-Ruby task racing the shellout task above.
  def run_ticker(ticks)
    tick_count.times do
      ticks << Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep tick_interval
    end
  end

  # Runs the workload once and returns [ticks, shellout_window].
  def run_workload
    ticks = []
    window = nil

    Async do |task|
      shellout_task = task.async { run_shellout }
      ticker_task = task.async { run_ticker(ticks) }
      window = shellout_task.wait
      ticker_task.wait
    end

    [ticks, window]
  end

  it "keeps the pure-Ruby ticker making progress throughout the shellout window" do
    ticks, window = run_workload
    start, finish = window
    ticks_during_window = ticks.count { |t| t.between?(start, finish) }

    # A cooperative reactor delivers ticks at ~TICK_INTERVAL throughout the
    # ~1s window (~20 of them); a starved one delivers ~0, because the
    # shellout task never yields the OS thread back to the reactor. The
    # threshold sits far below the cooperative count and far above zero, so
    # it distinguishes the two regimes without being timing-fragile.
    expect(ticks_during_window).to be >= (tick_count / 3)
  end

  # MEASURED, not assumed: five consecutive runs on ruby 4.0.5 + async 2.42.0
  # + mixlib-shellout 3.4.10 (2026-07-13) each recorded ~20/20 expected ticks
  # inside the shellout window, with inter-tick gaps holding at ~50ms (max
  # observed 51.4ms -- no gap resembling the full 1s window). That is the
  # cooperative outcome, so the starvation scenario below did not occur and
  # is skipped as the documented, empirically-rejected alternative. See
  # docs/concurrency.md's dated 5-0.1 entry for the full measurement.
  it "starves the ticker while the shellout blocks the reactor's one OS thread",
     skip: "measured cooperative, not starved: ruby 4.0.5 + async 2.42.0 + " \
           "mixlib-shellout 3.4.10 (2026-07-13) -- ticker recorded ~20/20 ticks " \
           "throughout the shellout window across 5 runs, no stall observed; " \
           "see docs/concurrency.md" do
    ticks, window = run_workload
    start, finish = window
    ticks_during_window = ticks.count { |t| t.between?(start, finish) }

    expect(ticks_during_window).to be <= 1
  end
end
