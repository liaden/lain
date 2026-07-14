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
  #
  # == The equality convention (binding across content-addressed values)
  #
  # +==+/+eql?+/+hash+ MUST agree: equal values hash equal, so a value type
  # dedupes in a Set and works as a Hash key. That is why +hash+ is +digest.hash+
  # while +==+ is +is_a?+ plus digest equality -- both keyed on the same digest.
  #
  # Two deliberate refusals, each pinned by a spec in content_addressed_spec.rb:
  #
  # * +is_a?(self.class)+ is NOT redundant. A digest collision across types must
  #   not collapse an Item and a Node that happen to share a digest into one
  #   value -- see "does not equate instances of different classes sharing a
  #   digest". Dropping the guard for duck-typed equality reintroduces exactly
  #   that collision. Caveat: the guard is receiver-class-directional -- under
  #   subclassing, parent == child holds while child == parent does not; no
  #   production subclass of an includer exists today, so the asymmetry is latent.
  # * No +rescue NoMethodError+ around +other.digest+. That rescue was proposed
  #   and rejected: it swallows a NoMethodError raised *inside* a broken
  #   +other.digest+ -- a genuine bug in the collaborator -- turning it into a
  #   silent +false+. That inverts this codebase's loud-failure premise, and the
  #   "raises rather than swallowing a NoMethodError from a broken #digest"
  #   example holds the line.
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
