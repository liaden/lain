# frozen_string_literal: true

module Lain
  # Post-initialize `freeze` for a PLAIN value class, named because "freeze once
  # our ivars are set" is the shape every hand-frozen value object repeats.
  # `prepend Freezable` puts this initialize ahead of the class's own, so `super`
  # runs the real constructor and then this freezes -- in one place.
  #
  # Deliberately freeze-ONLY. It does not validate, for two reasons. (1) A frozen
  # value must never carry ActiveModel's ivars (see {Lain::Guard}), so validation
  # is a throwaway carrier called inside the real initialize, not folded in here.
  # (2) On a `Data.define` value `super` has ALREADY frozen the instance by the
  # time this method resumes, so a `validate!` here would try to write `@errors`
  # onto a frozen object and raise -- which is also why Data values don't use
  # this at all: they auto-freeze when their own initialize returns, and
  # prepending Freezable would only add a redundant second freeze.
  #
  # It is a plain module, not an `ActiveSupport::Concern`: Concern earns its keep
  # for `ClassMethods` and dependency ordering, and this has neither -- it only
  # wraps `initialize`, which is exactly what `prepend` is for.
  module Freezable
    def initialize(...)
      super
      freeze
    end
  end
end
