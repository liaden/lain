# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lain
  module Review
    # Its own object, because "what does this string mean" is a separate
    # question from "present a review of it", and the ambiguity refusal needs
    # a git call that has nothing to do with rendering.
    class Target
      # A bare number that is also a branch name. Refused rather than resolved
      # by a precedence rule nobody chose: both readings are ordinary, they
      # review different things, and the two unambiguous spellings are cheap.
      class Ambiguous < Error; end

      HEADLINE = "reviewing %<label>s at %<scope>s scope: %<base>s..%<head>s"

      # One resolved target: the source, what to call it on screen, and the
      # pull request a review of it can be posted back to.
      #
      # `number` is nil for a BRANCH, decided here rather than asked of the
      # source later, so nothing downstream has to type-test a source to find
      # out whether a review of it has anywhere to go.
      # {Submit::Outbox} turns the nil into a refusal naming {#label}.
      Resolved = Data.define(:source, :label, :number) do
        # The name the round is JOURNALED under, derived from the source's
        # class rather than written as a literal: a literal goes on naming
        # `local_branch` after the class is renamed, and
        # {ChangesetOpened} validates this field for presence only,
        # so nothing downstream would catch it.
        def name = source.class.name.split("::").last.underscore
      end

      # @param repo_root [String] the repository every git call reads
      # @param shell_out_factory [#call] builds the subprocess runner
      # @param ledger [Lain::Sensitivity::Ledger] the region ledger a resolved
      #   source masks a note's evidence against; a fresh one masks everything
      def initialize(repo_root:, shell_out_factory:, ledger: Lain::Sensitivity::Ledger.new)
        @repo_root = File.expand_path(repo_root)
        @shell_out_factory = shell_out_factory
        @git = Isolation::Checkout.of(@repo_root, shell_out_factory:)
        @projection = Lain::Survey::Projection.new(ledger:)
      end

      # @param target [String]
      # @param base [String, nil]
      # @return [Resolved]
      # @raise [Ambiguous] for a pull request spelling that also names a branch
      # @raise [Error] for `--base` against a pull request
      # @raise [Source::UnknownRef] for a ref or pull request that resolves to
      #   nothing -- {Source}'s own doctrine, and the one this class inherits
      #   rather than restates
      def resolve(target, base: nil)
        return branch(target, base) unless pull_request?(target)
        # `--base` against a pull request, said apart from the {Ambiguous} below
        # because the remedy is nothing alike: this one is a flag that does not
        # apply, not a target that reads two ways.
        raise Error, base_message(target) unless base.nil?
        raise Ambiguous, ambiguous_message(target) if branch?(target)

        pull_request(target)
      end

      private

      def pull_request(target)
        source = Lain::Review::Source::GithubPr.new(pull_request: target, repo_root: @repo_root,
                                                    shell_out_factory: @shell_out_factory)
        source.projection = @projection
        Resolved.new(source:, label: "pull request #{source.number}", number: source.number)
      end

      def branch(target, base)
        source = Lain::Review::Source::LocalBranch.new(base: base || default_base, head: target,
                                                       repo_root: @repo_root,
                                                       shell_out_factory: @shell_out_factory)
        source.projection = @projection
        Resolved.new(source:, label: "branch #{target}", number: nil)
      rescue Lain::Review::Source::UnknownRef => e
        raise e unless base.nil? && e.role == "base"

        raise Error, "#{e.message} -- this repository has no default base to review a branch against; " \
                     "name one with --base <ref>"
      end

      # The base a LANDING targets, because what a review reviews is what is
      # going to be landed. A repository whose trunk is called something else
      # refuses loudly naming the ref, with `--base` in the same help output.
      def default_base = Lain::Forge::Landing::BASE

      # READ from {Source::GithubPr::Remote} rather than restated: a target
      # this class calls a pull request and that class then finds no number
      # in would refuse in the wrong words.
      def pull_request?(target)
        remote = Lain::Review::Source::GithubPr::Remote
        [remote::BARE_NUMBER, remote::URL_NUMBER].any? { |spelling| spelling.match?(target) }
      end

      # `refs/heads/` and never the bare name: `rev-parse --verify 4821`
      # resolves an OBJECT whose sha begins with those digits, so the bare
      # form would call a coincidence a branch and refuse a perfectly
      # ordinary pull request.
      def branch?(target)
        Shell::Out.ok?(@git.run("rev-parse", "--verify", "--quiet", "--end-of-options",
                                "refs/heads/#{target}"))
      end

      def ambiguous_message(target)
        number = target.delete_prefix("#")
        "#{target.inspect} names both pull request #{number} and the branch refs/heads/#{target} in " \
          "#{@repo_root}, and this will not guess between them -- they review different changesets. " \
          "Say \"refs/heads/#{target}\" for the branch, or the pull request's URL (.../pull/#{number}) " \
          "for the pull request."
      end

      def base_message(target)
        "--base cannot override the base of pull request #{target.inspect}: GitHub names the base " \
          "branch itself and the review is anchored to the merge base of that branch and the head, " \
          "so a base chosen here would present a range GitHub is not showing. Review a branch to " \
          "choose a base."
      end
    end
  end
end
