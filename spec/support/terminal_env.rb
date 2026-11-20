# frozen_string_literal: true

# Notifier.sequence_for reads these from the real ENV, so a runner inside kitty or iTerm would
# change which escape a spec sees. A spec that wants a terminal stubs ENV itself.
RSpec.configure do |config|
  config.before(:suite) do
    ENV.delete("KITTY_WINDOW_ID")
    ENV.delete("TERM_PROGRAM")
  end
end
