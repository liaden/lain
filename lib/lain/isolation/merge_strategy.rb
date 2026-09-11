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
      # a bad `config.toml` would.
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

      def to_s = "conflict_style=#{conflict_style} diff_algorithm=#{diff_algorithm}"

      DEFAULT = from(Config::Isolation.empty)

      private

      def style = ["-c", "merge.conflictStyle=#{conflict_style}"]

      def algorithm = ["-X", "diff-algorithm=#{diff_algorithm}"]
    end
  end
end
