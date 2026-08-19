# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# The parallel spec run: files knapsack-packed by recorded runtime. The suite is
# parallel-safe by construction (tmpdirs, per-pid sockets, injected env), and the
# untagged posture guards live in a real spec file (spec/network_posture_spec.rb),
# so no worker re-runs what another already owns.
#
# GROUPING is measured and still holds: parallel_tests' default groups by file
# SIZE, and this suite's slowest files are small ones that are slow for reasons
# size cannot see (a real subprocess kill, a sweep build). RuntimeLogger
# re-records per-file runtimes into the gitignored tmp log on every run; the next
# run packs by them. A fresh clone has no log yet and `--group-by runtime` raises
# ENOENT rather than falling back, so the fallback lives here.
#
# The WORKER-COUNT reasoning that used to sit here is RETIRED rather than deleted,
# because a deleted number invites someone to re-derive it. It said boot and specs
# were CPU-bound and that 16 workers beat 8 on CPU but not on wall (3.4s vs 2.7s).
# That was genuinely measured -- on a 5518-example suite running in ~3s. This suite
# is 10865 examples at 21-35s and is subprocess-bound, so the measurement no longer
# transfers. What replaced it is beside `spec_workers` below.
desc "Run the spec suite in parallel"
task :pspec do
  runtime_log = "tmp/parallel_runtime_rspec.log"
  group_by = File.exist?(runtime_log) ? "--group-by runtime " : ""
  sh "bundle exec parallel_rspec spec -n #{spec_workers} #{group_by}--test-options " \
     "'--format progress --format ParallelTests::RSpec::RuntimeLogger --out #{runtime_log}'"
end

namespace :spec do
  # Deliberately NOT wired into `check` or the pre-commit hook. This is a hunt,
  # not a gate: it runs the whole suite sixteen times and takes tens of minutes,
  # and its answer is a list to investigate rather than a pass/fail on a commit.
  #
  # It does not use `pspec`. `parallel_rspec` packs whole FILES into groups, so a
  # worker there sees a SLICE of the suite -- which is the one thing that cannot
  # find leakage between two examples that never met. Every run here is the whole
  # suite, in one process, in a random order; the parallelism is across RUNS.
  # See bin/spec-flakes for why each run is a fork of one preload rather than a
  # fresh `rspec`.
  #
  #     rake spec:flakes        # 4 concurrent lanes x 4 full suites = 16 runs
  #     rake spec:flakes[8]     # ...x 8 = 32 (quote it in zsh: 'spec:flakes[8]')
  #     LAIN_FLAKE_LANES=6 LAIN_FLAKE_RUNS=2 rake spec:flakes
  desc "Hunt order-dependent and state-leaking specs: N full suites in randomized orders"
  task :flakes, [:runs] do |_task, args|
    sh({ "LAIN_FLAKE_RUNS" => args[:runs] }.compact, "bundle exec ruby bin/spec-flakes")
  end
end

# A deliberately CONSERVATIVE default, and not the fastest count -- which is the
# one thing the previous version of this comment got right for the wrong reason.
#
# It used to say the constraint is MEMORY rather than CPU. Measured 2026-08-05 on
# an 8-physical/15.9G box, neither is: at `physical - 1` the machine is 52.6%
# idle, because a worker blocked in `git` holds no core, and memory never came
# near binding -- zero swap growth at every count, memory pressure 0.35%, 6.9G
# still available. What actually stops the count paying is kernel spawn cost;
# past ~11 workers the marginal one buys system time rather than throughput. The
# measured optimum there was 12-14 workers, with `physical - 1` the WORST count
# tried (median 31.8s against 24.4s). CLAUDE.md carries the readings.
#
# The default stays below that anyway, because those are ONE box's numbers and
# generalising from one box is the error this reasoning is being corrected for.
# The two risks are not symmetric either: guessing low costs wall time a developer
# can see and fix with `LAIN_SPEC_WORKERS`, while guessing high risks an OOM kill,
# and parallel_tests does not fail loudly when that happens -- the run reports only
# the examples that SURVIVED (4523 of 5518 on the run that prompted the original
# note) and exits non-zero, which reads as a broken commit rather than a starved
# machine. So: a floor for hardware nobody has measured, not a recommendation.
# On a box you know, set `LAIN_SPEC_WORKERS` above it.
def spec_workers
  override = Integer(ENV.fetch("LAIN_SPEC_WORKERS", ""), exception: false)
  return override if override&.positive?

  [physical_cores - 1, 1].max
end

# `lscpu -p=core` yields one line per LOGICAL cpu naming its physical core;
# the unique count is the physical-core count. Logical count as the fallback
# for platforms without lscpu -- over-provisioned beats zero workers.
def physical_cores
  require "etc"
  cores = `lscpu -p=core 2>/dev/null`.lines.grep_v(/\A#/).map(&:to_i).uniq.size
  cores.positive? ? cores : Etc.nprocessors
end

# pre-commit runs its HOOKS serially -- overlap between checks has to happen
# inside one hook. `rake compile check` is that hook's entry: compile once
# (both need the extension), then rubocop and the parallel spec run fan out
# together. Their streamed output may interleave; each tool's summary block
# still lands intact at its end.
multitask check: %i[pspec rubocop]

# The out-of-process exec daemon the :core-tagged specs drive. A plain `cargo
# build` (not rb_sys -- lain-core is a standalone workspace binary, no Ruby
# linkage) into the workspace target dir, which is exactly where
# Lain::Core::Child::BINARY looks.
#
#     bundle exec rake core:build && bundle exec rspec --tag core
namespace :core do
  desc "Compile the lain-core exec daemon for the :core-tagged specs"
  task :build do
    sh "cargo build -p lain-core"
  end
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

require "rb_sys/extensiontask"

task build: :compile

GEMSPEC = Gem::Specification.load("lain.gemspec")

RbSys::ExtensionTask.new("lain", GEMSPEC) do |ext|
  ext.lib_dir = "lib/lain"
end

task default: %i[compile spec rubocop]
