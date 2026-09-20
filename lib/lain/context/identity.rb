# frozen_string_literal: true

module Lain
  class Context
    # The monoid unit: composing it changes nothing, so a fold over an empty
    # combinator list (or an optional combinator slot) stays total instead of
    # special-casing nil. An INSTANCE, not a class, because the unit of a monoid
    # is a value you compose with -- the whole reason {Combinator} is
    # instantiable.
    Identity = Combinator.new.freeze
  end
end
