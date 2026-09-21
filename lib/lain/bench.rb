# frozen_string_literal: true

module Lain
  # The study bench itself: replay a recorded session, re-run one against the
  # live API, and sweep a strategy across arms so two answers can be compared
  # rather than argued about. `dry_replay` is free and byte-diffable,
  # `live_replay` costs money, and the sweeps are the reason the harness
  # records anything at all.
  module Bench; end
end
