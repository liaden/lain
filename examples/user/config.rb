# frozen_string_literal: true

# ~/.config/lain/config.rb. Run `lain trust --user` after editing it.

theme response: %w[green], tool_header: %w[magenta bold]

attention delay: 30

# The phone relay listens on this machine's tailscale address. See docs/users/remote.md.
remote relay: "100.64.0.7:7820", ntfy: "http://100.64.0.7:2586/lain-your-long-random-topic"
