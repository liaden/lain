# frozen_string_literal: true

# The forced half of a synthetic coupling. Read ONLY by `dependent.rb` in this
# same directory -- see it for why the pair exists at all.
#
# Under `spec/fixtures/`, not `spec/support/`: `spec_helper.rb`'s glob requires
# every `.rb` under `support/` into the SUITE's own process, and this file
# must never be that -- it is a SOURCE `BootWithout#install`
# (`spec/lain/review/deletability_spec.rb`) copies into the throwaway tree it
# boots, never a file this process itself loads.
module Lain
  module Review
    module DeletabilityControl
      class Forcer
        VALUE = "deletability-control-forcer"
      end
    end
  end
end
