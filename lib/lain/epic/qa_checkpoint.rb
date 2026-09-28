# frozen_string_literal: true

module Lain
  module Epic
    # A QA checkpoint: an issue in the blocking graph whose work is QA itself.
    # Blocked by a cluster, it becomes ready exactly when that cluster has
    # landed; blocking the next cluster, it holds it until QA passes. The graph
    # therefore says everything a checkpoint means, and no new concept is needed.
    #
    # MARKED BY ITS ID, because an id is the one thing the epic markdown, the
    # issue's filename and the digest all carry already. A new {Issue} member
    # would be the honest marker and moves the digest of every issue in every
    # existing epic; a new {STAGES} member cannot sit BETWEEN two clusters of one
    # stage, which is the whole shape of a checkpoint.
    module QaCheckpoint
      # RESERVED, not merely recognised: every id under this prefix is a
      # checkpoint, so an ordinary issue called `qa-gate-keeper-refactor` is run as
      # QA and never implemented -- and it holds whatever it blocks until QA
      # releases it. Nothing enforces that, because the prefix IS the declaration;
      # what can be done is to say it here, where the convention lives.
      PREFIX = "qa-gate-"

      # The fix issues a failing pass files open with this instead, and the two
      # prefixes are DISJOINT: a fix whose id read as a checkpoint would be run
      # as QA rather than implemented, and -- since each fix blocks the
      # checkpoint that found it -- would block itself forever.
      FIX_PREFIX = "qa-fix-"

      # @param issue [Issue] any issue in the graph
      def self.of?(issue) = issue.id.start_with?(PREFIX)

      # The fix ids past every one +taken+ already holds, so a second failing
      # pass files beside the first rather than colliding with it.
      #
      # @param checkpoint_id [String] the checkpoint that found the findings
      # @param taken [Array<String>] every id the graph holds
      # @return [Enumerator::Lazy<String>] fresh ids in order, unbounded because
      #   only the caller knows how many findings it has to file
      def self.fix_ids(checkpoint_id, taken)
        stem = "#{FIX_PREFIX}#{checkpoint_id.delete_prefix(PREFIX)}-"
        (1..).lazy.map { |n| "#{stem}#{n}" }.reject { |id| taken.include?(id) }
      end
    end
  end
end
