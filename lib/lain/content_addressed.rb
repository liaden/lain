# frozen_string_literal: true

module Lain
  # The Regular-equality trio for content-addressed values. Normalization and
  # digest derivation stay the includer's own job; this module owns only ==,
  # eql? and hash. Stateless by design -- it adds no ivars, so including it
  # cannot disturb an includer's deep freeze or its Ractor shareability.
  #
  # @note the content address is +#digest+, deliberately not +#hash+. Ruby uses
  # +Object#hash+ for Hash and Set bucketing and requires an Integer; returning
  # a hex String there would silently break every Hash lookup. +hash+ is
  # therefore +digest.hash+ while +==+ is +is_a?+ plus digest equality -- both
  # keyed on the same digest, which is what makes equal values hash equal.
  #
  # Two deliberate refusals, each pinned by a spec in content_addressed_spec.rb:
  #
  # * +is_a?(self.class)+ is NOT redundant. Without it a digest collision across
  #   types collapses an Item and a Node sharing a digest into one value. The
  #   guard is receiver-class-directional -- under subclassing, parent == child
  #   holds while child == parent does not -- but no production subclass of an
  #   includer exists today, so the asymmetry is latent.
  # * No +rescue NoMethodError+ around +other.digest+. It was proposed and
  #   rejected: it swallows a NoMethodError raised *inside* a broken
  #   +other.digest+ -- a genuine bug in the collaborator -- as a silent
  #   +false+, inverting this codebase's loud-failure premise.
  module ContentAddressed
    def ==(other)
      other.is_a?(self.class) && digest == other.digest
    end
    alias eql? ==

    def hash
      digest.hash
    end
  end
end
