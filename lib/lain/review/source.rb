# frozen_string_literal: true

module Lain
  module Review
    # The changeset-source port: where a reviewable changeset comes from.
    #
    # A source answers four messages -- {LocalBranch#diff}, {LocalBranch#commits},
    # {LocalBranch#base_ref} and {LocalBranch#head_ref} -- and the shared example
    # group `"a review changeset source"` (spec/support/shared_examples/review_source.rb)
    # is the contract, not this comment. A local branch and a GitHub pull request
    # are the two implementations, and everything downstream -- the parser, the
    # anchors, the marks -- reads only these four messages, so neither knows which
    # it has.
    #
    # == Refusals here are RAISED, unlike {Forge::Gh}'s
    #
    # Gh's doctrine is that a refusal is a VALUE, because a landing folds over
    # answers and journals them. This port is not that: a ref that does not
    # resolve is the caller naming something that does not exist, which is Gh's
    # OWN distinction on the other side of the line -- "gh answering no is data,
    # gh not existing is a broken machine". There is no review to be had and no
    # fold to carry a not-ok answer, so {UnknownRef} raises.
    module Source
      # A ref the source was built against does not resolve, or two refs share no
      # history so there is no merge base to anchor the old side to. Named per
      # the error-taxonomy convention: a refusal subclasses {Lain::Error} next to
      # the owner that raises it.
      class UnknownRef < Error
        def self.unresolved(role, ref, repo_root, shell)
          new("#{role} ref #{ref.inspect} does not resolve to a commit " \
              "in #{repo_root}#{because(shell)}")
        end

        def self.no_merge_base(base, head, repo_root)
          new("#{base.inspect} and #{head.inspect} share no merge base " \
              "in #{repo_root}, so there is no revision to anchor the old side to")
        end

        # git's own words, when it had any. `rev-parse --verify --quiet`
        # silences "unknown revision" but NOT "not a git repository" or "cannot
        # change to …", and those two are the ones a caller most needs -- without
        # them a missing or wrong `repo_root` reports only that HEAD did not
        # resolve, which sends the reader looking at the wrong thing. Scrubbed
        # because stderr arrives as bytes.
        def self.because(shell)
          detail = shell.stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip
          detail.empty? ? "" : ": #{detail}"
        end
      end

      # One file's line accounting within one commit.
      #
      # `added` and `deleted` are nil for a binary file rather than 0, because a
      # caller cannot tell 0/0 from an empty text change, and git itself spells
      # the distinction as `-` for exactly this reason.
      FileStat = Data.define(:path, :added, :deleted) do
        def binary? = added.nil? && deleted.nil?
      end

      # One commit in the walk, carrying its OWN numstat rather than the
      # cumulative one -- the sidebar's commit scope needs per-commit figures,
      # and §3.7 measured a cumulative view at 81,810 lines against one commit's
      # 2,727.
      Commit = Data.define(:sha, :subject, :body, :numstat)
    end
  end
end

# This file is the source/ subtree's index. LocalBranch reads UnknownRef, Commit
# and FileStat from the module above, so it loads AFTER the module body.
require_relative "source/local_branch"
