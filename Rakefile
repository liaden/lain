# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# The parallel spec run: one worker per core. The suite is parallel-safe by
# construction (tmpdirs, per-pid sockets, injected env), and the untagged
# posture guards live in a real spec file (spec/network_posture_spec.rb), so
# no worker re-runs what another already owns.
desc "Run the spec suite across CPU cores"
task :pspec do
  sh "bundle exec parallel_rspec spec"
end

# pre-commit runs its HOOKS serially -- overlap between checks has to happen
# inside one hook. `rake compile check` is that hook's entry: compile once
# (both need the extension), then rubocop and the parallel spec run fan out
# together. Their streamed output may interleave; each tool's summary block
# still lands intact at its end.
multitask check: %i[pspec rubocop]

require "rubocop/rake_task"

RuboCop::RakeTask.new

require "rb_sys/extensiontask"

task build: :compile

GEMSPEC = Gem::Specification.load("lain.gemspec")

RbSys::ExtensionTask.new("lain", GEMSPEC) do |ext|
  ext.lib_dir = "lib/lain"
end

task default: %i[compile spec rubocop]
