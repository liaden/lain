# frozen_string_literal: true

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Order-dependent specs are a lie we tell ourselves. Surface them.
  config.order = :random
  Kernel.srand config.seed
end
