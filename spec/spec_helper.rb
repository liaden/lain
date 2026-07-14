# frozen_string_literal: true

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

# Every spec-suite concern is one file under spec/support. Parallel branches ADD a file here
# rather than editing this one, which is why this file is allowed to be boring. `Dir[]` has
# sorted its results since Ruby 3.0, so the order is stable without an explicit `.sort`.
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }
