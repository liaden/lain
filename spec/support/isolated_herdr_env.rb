# frozen_string_literal: true

# A spec run inside a herdr pane inherits HERDR_*, and a resolver or a child reading them would
# report to the developer's real herdr. A spec that needs a herdr env injects its own.
RSpec.configure do |config|
  config.around do |example|
    saved = ENV.to_h.select { |name, _| name.start_with?("HERDR_") }
    saved.each_key { |name| ENV.delete(name) }
    example.run
  ensure
    saved.each { |name, value| ENV[name] = value }
  end
end
