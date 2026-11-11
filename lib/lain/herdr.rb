# frozen_string_literal: true

module Lain
  # herdr, the terminal multiplexer that shows each coding agent's state. lain reports to it the
  # way herdr's third-party agent contract asks, and only for a pane it can prove is its own: the
  # human runs other agents in herdr too, and a report must never overwrite one of theirs.
  module Herdr
    # The `--source` every report carries, so herdr can tell lain's reports from another
    # integration's.
    SOURCE = "lain"

    # The agent name lain reports under, alone or as the head of `lain-<role>-<spawn>`. `agent get`
    # shows the agent name and not the source, so the name is how lain knows a pane is its own.
    AGENT = "lain"
  end
end
