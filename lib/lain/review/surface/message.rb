# frozen_string_literal: true

module Lain
  module Review
    module Surface
      # One message in the conversation a `thread` opens: who said it, and what
      # they said.
      #
      # It lives at the PORT rather than on either side of it, and that is the
      # whole reason it is here. The object that builds these and the object that
      # renders them must agree on one shape, and NEITHER MAY NAME THE OTHER --
      # nor may this file name either of them, or its own docstring becomes the
      # dangling reference the next deletion leaves behind. Tying two separately
      # deletable capabilities to each other would mean deleting either takes the
      # other with it; a value both depend on belongs to the abstraction they
      # already depend on, and it outlives both.
      #
      # Deeply frozen, which the two `Data` shapes it replaces were not: both
      # members are interned, so `Ractor.shareable?` holds for a rendered
      # conversation on its way across a thread boundary to an editor.
      Message = Data.define(:speaker, :text) do
        def initialize(speaker:, text:) = super(speaker: -speaker.to_s, text: -text.to_s)
      end
    end
  end
end
