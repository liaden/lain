# frozen_string_literal: true

module Lain
  # `#inspect` as the class-tagged wrapper around `#to_s` -- the convention
  # {Capability::DegradedSet} named and five other value types then wrote out by hand.
  # `to_s` stays the human-facing projection; this is the debug-oriented form, and the
  # two must not be aliased.
  #
  # Four of those six spelled their own class name into the string, so a subclass
  # inspected as its parent. `self.class` is the whole reason to share the method.
  #
  # A plain module rather than an `ActiveSupport::Concern`, for the reason
  # {Lain::Freezable} gives: no ClassMethods, no dependency ordering, nothing to hook.
  module Inspectable
    def inspect = "#<#{self.class} #{self}>"
  end
end
