# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# The parallel spec run: one worker per PHYSICAL core, files knapsack-packed
# by recorded runtime. The suite is parallel-safe by construction (tmpdirs,
# per-pid sockets, injected env), and the untagged posture guards live in a
# real spec file (spec/network_posture_spec.rb), so no worker re-runs what
# another already owns.
#
# Both knobs are measured, not guessed (2026-07-17, 8-core/16-thread):
#   * Worker count: boot and specs are CPU-bound, and SMT siblings share
#     execution units, so 16 workers ran SLOWER than 8 (3.4s vs 2.7s wall)
#     at more than twice the CPU (32s vs 14s).
#   * Grouping: parallel_tests' default groups by file SIZE, and this suite's
#     slowest files are small ones that are slow for reasons size cannot see
#     (a real subprocess kill, a sweep build). RuntimeLogger re-records per-file
#     runtimes into the gitignored tmp log on every run; the next run packs by
#     them. A fresh clone has no log yet and --group-by runtime raises ENOENT
#     rather than falling back, so the fallback lives here.
desc "Run the spec suite across physical CPU cores"
task :pspec do
  runtime_log = "tmp/parallel_runtime_rspec.log"
  group_by = File.exist?(runtime_log) ? "--group-by runtime " : ""
  sh "bundle exec parallel_rspec spec -n #{physical_cores} #{group_by}--test-options " \
     "'--format progress --format ParallelTests::RSpec::RuntimeLogger --out #{runtime_log}'"
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
