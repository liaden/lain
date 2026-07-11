# frozen_string_literal: true

module Lain
  # The Regular-equality trio for content-addressed values: two are the same
  # value exactly when they are the same kind of thing naming the same digest.
  # Normalization and digest derivation stay the includer's own job -- they
  # differ per class, and the differences are load-bearing. This module owns
  # only ==, eql? and hash.
  #
  # Stateless by design: it adds no ivars, so including it cannot disturb an
  # includer's deep freeze or its Ractor shareability.
  #
  # NOTE: the content address is +#digest+, deliberately not +#hash+. Ruby uses
  # +Object#hash+ for Hash and Set bucketing and requires an Integer; returning
  # a hex String there would silently break every Hash lookup.
  module ContentAddressed
    # Regular: equality is structural, and structural equality is digest equality.
    def ==(other)
      other.is_a?(self.class) && digest == other.digest
    end
    alias eql? ==

    def hash
      digest.hash
    end
  end
end
