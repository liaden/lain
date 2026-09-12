# frozen_string_literal: true

# Reads {Forcer::VALUE} while ITS OWN class body runs -- the shape the
# negative control exists to prove `BootWithout` catches: installing this
# file into a boot copy WITHOUT also installing and requiring `forcer.rb`
# (its sibling in this directory) is a NameError at boot, with nothing to
# grep for, because the name is exactly what is missing. See `forcer.rb` for
# why this is a fixture SOURCE rather than something the suite itself loads.
module Lain
  module Review
    module DeletabilityControl
      class Dependent
        VALUE = Forcer::VALUE
      end
    end
  end
end
