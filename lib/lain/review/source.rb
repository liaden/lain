# frozen_string_literal: true

module Lain
  module Review
    # The changeset-source port: where a reviewable changeset comes from.
    #
    # A source answers six messages -- {LocalBranch#diff}, {LocalBranch#commits},
    # {LocalBranch#base_ref}, {LocalBranch#head_ref}, {LocalBranch#diff_origin}
    # and {LocalBranch#file_at} -- and the shared example
    # group `"a review changeset source"` (spec/support/shared_examples/review_source.rb)
    # is the contract, not this comment. A local branch and a GitHub pull request
    # are the two implementations, and everything downstream -- the parser, the
    # anchors, the marks -- reads only these five messages, so neither knows which
    # it has.
    #
    # == The fifth message, and why it is on the PORT
    #
    # {DiffOrigin} began as {GithubPr}'s alone, and its first consumer
    # ({CLI::Review}) therefore asked `respond_to?(:diff_origin)` -- a type test
    # in duck costume, and the one place a consumer branched on WHICH source it
    # was handed. The answer is not a defter conditional: it is that a source
    # which never asks an API still has an answer to "where did these bytes come
    # from", and {LocalBranch} gives it. The conditional is gone, and with it a
    # live defect -- the guard was tested on one leg only, and an ordinary pull
    # request rendered a fallback note with an empty reason.
    #
    # == The sixth message, and why a diff is not enough
    #
    # {LocalBranch#file_at} is the one message about a single PATH rather than
    # about the whole changeset, and it is here because a unified diff cannot be
    # DRAWN from. An editor showing the old side beside the new needs the whole
    # old file; a diff carries the hunks and three lines around them. Every
    # consumer of that is a renderer, so the read belongs to the source that
    # already knows where the bytes live rather than to a renderer that would
    # have to be handed a repository to find out.
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

      # Where {LocalBranch#diff} came from, and why. The requirement is that a
      # fallback be REPORTED rather than silent, and this is the report: a value
      # a caller renders or journals, carrying gh's own words rather than a
      # paraphrase of them.
      #
      # On the PORT rather than under {GithubPr}, where it was first written --
      # see the module doc for what asking one source and not the other cost.
      DiffOrigin = Data.define(:origin, :reason, :message, :fell_back) do
        # The object database could answer, so no API was ever asked. Both
        # sources reach it: {GithubPr} when the head was already fetched (or an
        # earlier message fetched it), and {LocalBranch} always -- a branch
        # review has no API in it at all, and "the objects are here and nobody
        # was asked" is the same fact for both.
        def self.already_local
          new(origin: "object_database", reason: "already_local", message: "", fell_back: false)
        end

        def self.served = new(origin: "combined_diff_api", reason: "served", message: "", fell_back: false)

        # @param reason [String] `too_large` when GitHub named its own
        #   ceiling, `refused` or `timeout` otherwise
        # @param message [String] what gh said. SCRUBBED, not verbatim: this
        #   value is journalled, the Journal is NDJSON, and stderr is bytes --
        #   one line `JSON.generate` refuses breaks the parse of the whole
        #   experiment record. {UnknownRef.because} and {LocalBranch#text}
        #   scrub for the same reason.
        def self.fallback(reason:, message:)
          new(origin: "object_database", reason:,
              message: message.to_s.dup.force_encoding(Encoding::UTF_8).scrub.freeze,
              fell_back: true)
        end

        def fell_back? = fell_back
      end

      # Where a chat's `implementation` review reads its diff from: this
      # repository, at whatever base the model named, against the working tree's
      # own head.
      #
      # The `changesets:` seam {Tools::RequestReview} takes, and the only
      # implementation of it in the tree -- {Tools::RequestReview::NoChangesets}
      # is its null, and until this existed that null was the only thing any
      # production wiring passed, so every `implementation` call in every real
      # process refused with `no_changeset`.
      #
      # A FACTORY and not a source, because `base` is the model's argument and
      # arrives per call: {LocalBranch} resolves its refs in its constructor and
      # refuses an unresolvable one there, so one built at wiring time would have
      # to guess a base -- the guess that tool's `base` field exists to refuse.
      #
      # `source` and not `call`, deliberately: {Tools::RequestReview#live} treats
      # anything answering `call` as a thunk to be read with no arguments, so a
      # callable seam here would be invoked as one.
      class Repository
        # @param repo_root [String] the repository every git call reads
        def initialize(repo_root: Dir.pwd)
          @repo_root = repo_root
        end

        # @param base [String] the ref the changeset is reviewed against
        # @param head [String] the ref under review
        # @return [LocalBranch]
        # @raise [UnknownRef] for a ref that does not resolve, or two that share
        #   no history -- which {Tools::RequestReview::Implementation#hold}
        #   answers as a refusal rather than letting out of the tool
        def source(base:, head:) = LocalBranch.new(base:, head:, repo_root: @repo_root)
      end
    end
  end
end

# This file is the source/ subtree's index. LocalBranch reads UnknownRef, Commit
# and FileStat from the module above, so it loads AFTER the module body, and
# GithubPr reads LocalBranch's constants, so it loads after LocalBranch.
require_relative "source/local_branch"
require_relative "source/github_pr"
