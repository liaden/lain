# frozen_string_literal: true

# A spec run inside tmux inherits TMUX, and the default TmuxMessage would then display a
# message on the developer's real server. A spec that needs a tmux env injects its own.
RSpec.configure do |config|
  config.around do |example|
    saved = ENV.to_h.slice("TMUX", "TMUX_PANE")
    ENV.delete("TMUX")
    ENV.delete("TMUX_PANE")
    example.run
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
