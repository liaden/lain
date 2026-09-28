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
  #   holds while child == parent does not, and both hash alike, so a Hash
  #   holding one of each would answer by insertion order. There is one
  #   production subclass, +Workspace::Snapshot::Blob+ over
  #   +ContentAddressed::Blob+, and what keeps the asymmetry out of reach there
  #   is the tag: the subclass closes the tag keyword, so the only parent that
  #   could equal it is one built with +tag: "blob"+, which nothing constructs.
  #   Out of reach is not the same as fixed -- making the guard symmetric is the
  #   real answer, and it moves the refusals pinned below, so it goes in its own
  #   commit rather than riding a change that merely gained a subclass.
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
