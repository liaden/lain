# frozen_string_literal: true

module Lain
  # The provider/model/sampler resolution the CLI's chat and bench-record paths
  # share, lifted out of the thin Thor executable so it carries specs the way
  # lib/ does.
  module CLI
    # A {Lain::Error} and NOT a Thor::Error, because thor never crosses below
    # the frontend; the exe layer maps this to a Thor::Error exactly as it maps
    # every other lib refusal.
    class UnknownProvider < Error; end
  end
end

# Loaded first because exe/lain reads these in `method_option` defaults, which
# evaluate while the Thor class body loads -- before any command runs.
