# frozen_string_literal: true

module Lain
  class Toolset
    class Disclosure
      # The default arm: the toolset's full schema, upfront, at position 0 --
      # exactly {Lain::Toolset#to_schema}'s existing output. This delegates
      # rather than re-deriving it: two implementations of "sorted +
      # Canonical.normalize" could drift, and a drift here is a silent
      # prompt-cache break with no error anywhere (see Toolset's own comment).
      # Reuse is what keeps this arm byte-identical by construction.
      class Upfront < Disclosure
        def render(toolset)
          toolset.to_schema
        end
      end
    end
  end
end
