# frozen_string_literal: true

module Lain
  # The provider/model/sampler resolution the CLI's chat and bench-record paths
  # share, lifted out of the thin Thor executable so it carries specs the way
  # lib/ does. The exe stays thin wiring; {Backend} owns the choices.
  module CLI
    # A `--provider` name that is not one of {Backend::PROVIDERS}. A {Lain::Error}
    # -- NOT a Thor::Error -- because thor never crosses below the frontend; the
    # exe layer maps this to a Thor::Error (message, nonzero exit, no backtrace),
    # exactly as it maps every other lib refusal.
    class UnknownProvider < Error; end
  end
end

require_relative "cli/backend"
require_relative "cli/chronicle"
require_relative "cli/journal_tee"
require_relative "cli/resume"
require_relative "cli/sessions"
require_relative "cli/watch"
require_relative "cli/friction"
require_relative "cli/improvements"
require_relative "cli/consolidate"
require_relative "cli/improve"
require_relative "cli/shutdown"
require_relative "cli/signals"
require_relative "cli/prompt_breaker"
require_relative "cli/conductor"
require_relative "cli/up"
require_relative "cli/tmux_surface"
require_relative "cli/repl_middleware"
require_relative "cli/live_views"
require_relative "cli/human_replies"
require_relative "cli/repl"
require_relative "cli/wiring"
