# frozen_string_literal: true

# Bootsnap first: everything below -- lain and the whole gem graph it pulls
# in -- loads through its iseq cache. See spec/bootsnap_setup.rb.
require_relative "bootsnap_setup"

require "lain"

# The universal stdlib set: these appear across ten-plus spec files (Ruling 8 of the
# 2026-07-14 review plan), so they load once here; rarer stdlib requires stay in their
# leaf specs, mirroring the lib-side policy.
require "json"
require "stringio"
require "tmpdir"

# `webmock/rspec` is required HERE, not from spec/support, because the support glob loads
# in `Dir[]`'s sorted order and `vcr_configuration.rb` sorts before `webmock_configuration.rb`.
# VCR's `hook_into :webmock` needs WebMock already loaded, so the load order cannot be left
# to alphabetical luck. Configuration -- as opposed to loading -- lives in spec/support.
require "webmock/rspec"

# Profiling lenses for the suite itself -- dormant until asked for via env:
#   TEST_STACK_PROF=1 bundle exec rspec ...   sampling profile -> flamegraph
#   TAG_PROF=type     bundle exec rspec ...   time per example type
#   EVENT_PROF=...    bundle exec rspec ...   time per instrumented event
require "test_prof"

# The stuck-example watchdog is required HERE, ahead of the glob, for the same class of reason
# webmock is above: `around` hooks nest in DEFINITION order, and the support files that spawn
# editors and daemons register `around`s of their own. Loaded alphabetically it would sit inside
# those and time only the example body, missing a hang in the spawn -- so it goes first, and is
# outermost.
require_relative "support/watchdog"

# Every spec-suite CONCERN is one file under spec/support -- VCR, WebMock, the watchdog, tag
# policy. Parallel branches ADD a file there rather than editing this one. Core RSpec
# configuration is the exception and lives below, where the community convention puts it.
# `Dir[]` has sorted its results since Ruby 3.0, so the order is stable without an explicit
# `.sort`.
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end

  # Stubbing a method the real object lacks is a spec for an object that cannot exist.
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # Opt out with `aggregate_failures: false` where a later expectation would raise on
  # state an earlier one guards.
  config.define_derived_metadata do |meta|
    meta[:aggregate_failures] = true unless meta.key?(:aggregate_failures)
  end

  # Order-dependent specs are a lie we tell ourselves. Surface them.
  config.order = :random
  Kernel.srand config.seed
end
