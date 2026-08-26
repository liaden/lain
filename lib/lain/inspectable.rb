# frozen_string_literal: true

module Lain
  # `#inspect` as the class-tagged wrapper around `#to_s`. The two must not be
  # aliased: `to_s` stays the human-facing projection, this is the debug form.
  #
  # Four of the six value types that once wrote this by hand spelled their own
  # class name into the string, so a subclass inspected as its parent.
  # `self.class` is the whole reason to share the method.
  module Inspectable
    def inspect = "#<#{self.class} #{self}>"
  end
end
