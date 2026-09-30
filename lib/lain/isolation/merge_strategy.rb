# frozen_string_literal: true

module Lain
  module Isolation
    MergeStrategy = Data.define(:conflict_style, :diff_algorithm)

    # How lain merges a worker's commits, spelled on git's own command line so
    # no config file -- the repository's or the user's -- changes what a
    # conflict looks like to the resolver reading it.
    #
    # `git merge` has no `--conflict=<style>` flag (checked on git 2.55), so
    # the style rides in as a `-c merge.conflictStyle` override, which outranks
    # every config file. zdiff3 is the default because its markers carry the
    # merge base, the one side a resolver otherwise has to guess.
    class MergeStrategy
      # @param isolation [Config::Isolation] the project's `[isolation]` table
      # @return [MergeStrategy]
      def self.from(isolation)
        new(conflict_style: isolation.conflict_style, diff_algorithm: isolation.diff_algorithm)
      end

      # The table's own rules, so a strategy built by hand refuses exactly what
      # a bad `config.rb` would.
      def initialize(conflict_style:, diff_algorithm:)
        Config::Isolation.check!({ "conflict_style" => conflict_style, "diff_algorithm" => diff_algorithm })
        super(conflict_style: -conflict_style, diff_algorithm: -diff_algorithm)
      end

      # What a handback's merge must do whatever the user's config says:
      # `merge.ff = false`/`only` would force a merge commit or refuse a
      # diverged worker, `branch.<b>.mergeOptions = --squash`/`--no-commit`
      # would exit 0 without landing anything, and `merge.verifySignatures`
      # would refuse an unsigned worker commit (all verified on git 2.55).
      BEHAVIOUR = %w[--ff --no-squash --commit --no-verify-signatures].freeze

      # @return [Array<String>] git's arguments after `git -C <dir>`
      def merge(ref) = [*style, "merge", *BEHAVIOUR, "--no-edit", *algorithm, ref]

      # @return [Array<String>] git's arguments after `git -C <dir>`
      def rebase(upstream) = [*style, "rebase", *algorithm, upstream]

      # A merge of `commit` into `tip` written as a tree and nothing else, so
      # asking whether a worker integrates moves no index and no working tree.
      # Spelt beside {#merge} because a probe with another style or algorithm
      # would predict conflicts the merge itself does not have.
      #
      # @return [Array<String>] git's arguments after `git -C <dir>`
      def probe(tip, commit)
        [*style, "merge-tree", "--write-tree", "-z", "--name-only", "--no-messages", *algorithm, tip, commit]
      end

      def to_s = "conflict_style=#{conflict_style} diff_algorithm=#{diff_algorithm}"

      DEFAULT = from(Config::Isolation.empty)

      private

      # rerere rides the same `-c`: a user's `rerere.autoupdate` replays and
      # stages an old resolution, so a real conflict comes back with nothing
      # unmerged and reads as a failure, and a resolver never sees it.
      def style = ["-c", "merge.conflictStyle=#{conflict_style}", "-c", "rerere.enabled=false"]

      def algorithm = ["-X", "diff-algorithm=#{diff_algorithm}"]
    end
  end
end
