# frozen_string_literal: true

require "fileutils"
require "json"

# Records, per example, the GC time and objects allocated while it ran, one NDJSON file per worker, so GC
# cost can be pinned on files. Inert unless the gc lens set SUITE_PROFILE_LENS, because the support glob
# loads every file here into every run.
if ENV["SUITE_PROFILE_LENS"] == "gc"
  gc_dir = File.join(ENV.fetch("SUITE_PROFILE_DIR"), "gc")
  FileUtils.mkdir_p(gc_dir)
  gc_path = File.join(gc_dir, "w#{ENV.fetch("TEST_ENV_NUMBER", "")}x#{Process.pid}.ndjson")
  keys = %i[time total_allocated_objects minor_gc_count major_gc_count]
  record = ->(row) { File.write(gc_path, "#{row.to_json}\n", mode: "a") }

  RSpec.configure do |config|
    config.around do |example|
      before = GC.stat.slice(*keys)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      example.run
      after = GC.stat.slice(*keys)
      wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      record.call({ file: example.metadata[:file_path], wall: }.merge(after.to_h do |key, value|
        [key, value - before[key]]
      end))
    end

    config.after(:suite) { record.call({ suite_end: GC.stat.slice(*keys) }) }
  end
end
