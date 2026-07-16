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
require_relative "cli/shutdown"
