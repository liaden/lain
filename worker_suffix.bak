# frozen_string_literal: true

# Loaded by RUBYOPT into every Ruby a profiled run starts: test-prof names its dump per mode only, so
# without a per-worker suffix the 12 workers overwrite one file. Gated on the dir, not the lens, because the
# dump is wanted for every lens that sets one.
if ENV["SUITE_PROFILE_DIR"] && ENV["TEST_ENV_NUMBER"]
  ENV["TEST_PROF_REPORT"] ||= "w#{ENV.fetch("TEST_ENV_NUMBER")}x#{Process.pid}"
end
