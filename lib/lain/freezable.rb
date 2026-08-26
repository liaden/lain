# frozen_string_literal: true

module Lain
  # Post-initialize `freeze` for a PLAIN value class. `prepend` puts this
  # initialize ahead of the class's own, so `super` runs the real constructor
  # and then this freezes.
  #
  # Deliberately freeze-ONLY, for two reasons. A frozen value must never carry
  # ActiveModel's ivars (see {Lain::Declarative::Carrier}), so validation is a
  # throwaway carrier called inside the real initialize. And on a `Data.define`
  # value `super` has ALREADY frozen the instance by the time this method
  # resumes, so a `validate!` here would try to write `@errors` onto a frozen
  # object and raise -- which is also why Data values do not use this at all.
  #
  # A plain module rather than an `ActiveSupport::Concern`: no ClassMethods and
  # no dependency ordering, so there is nothing Concern would earn.
  module Freezable
    def initialize(...)
      super
      freeze
    end
  end
end
