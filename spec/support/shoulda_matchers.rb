# frozen_string_literal: true

# Only :rspec + :active_model -- no :rails, no :active_record. This project has
# no models and no DB; Lain::Tool::Input (lib/lain/tool/input.rb) is a plain
# ActiveModel::Model + ActiveModel::Attributes class, and that is the only
# library shoulda-matchers needs to know about. `library :active_model` does
# reach for `ActiveSupport::TestCase` internally (an autoloaded constant, not
# a Rails railtie) purely to extend it for Minitest users; confirmed this
# resolves cleanly under plain ActiveModel + RSpec with no Rails present.
require "shoulda-matchers"

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :active_model
  end
end
