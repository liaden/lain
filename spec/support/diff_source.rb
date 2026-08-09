# frozen_string_literal: true

require "delegate"

# A source over hand-written diff bytes, for the many specs that need a
# changeset without a repository behind it.
#
# It exists because `Source` hands the changeset MODEL VALUES: a bare
# `instance_double(LocalBranch, diff: …)` no longer answers what a changeset
# reads. Stubbing `files:` and `identity:` on the double instead would work and
# would be wrong -- every digest example would then be asserting about its own
# stub rather than about the composition `Source::Diffed` performs, which is
# exactly the shape that lets an address quietly move.
#
# So this wraps the verifying double and includes the PRODUCTION module. The
# three answers a repository would have given (`diff`, `commits`, the refs) stay
# stubbed and stay verified; `files` and `identity` are the real ones.
module DiffSource
  # The wrapper itself. `SimpleDelegator` forwards everything the module reaches
  # for -- `diff`, `base_ref` -- to the double behind it, and the two messages
  # {Lain::Review::Source::Diffed} defines win over `method_missing` because a
  # defined method always does.
  class OverBytes < SimpleDelegator
    include Lain::Review::Source::Diffed
  end

  # @param double [Object] anything answering `#diff` and `#base_ref`
  # @return [OverBytes]
  def self.over(double) = OverBytes.new(double)
end
