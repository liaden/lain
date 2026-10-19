# frozen_string_literal: true

module Lain
  module Epic
    # The commit an issue's red step makes: the failing tests alone, under one
    # subject. {.subject} is the only place that wording lives, so the step
    # that writes it and the landing that must recognise it cannot drift.
    class RedCommit
      # Prefix on purpose: any red-only commit is not an implementation, whatever its target or digest.
      PREFIX = "test: failing tests at "

      # @param target [String] the test file the commit holds
      # @param digest [String] the approved criteria's digest
      # @return [String]
      def self.subject(target, digest) = "#{PREFIX}#{target}, from criteria #{digest}"

      # @param git [Isolation::Checkout] the repository holding both refs
      # @param base [String] the epic branch ref the issue branch was cut from
      def initialize(git:, base:)
        @git = git
        @base = base
      end

      # An empty range is false: a sha at or behind the base holds no work at
      # all, and "every commit is red" must not be vacuously true of it.
      # @param sha [String] an issue branch tip
      # @return [Boolean]
      def only?(sha)
        subjects = subjects_past_base(sha)
        !subjects.empty? && subjects.all? { |line| line.start_with?(PREFIX) }
      end

      private

      def subjects_past_base(sha)
        base = @git.run("merge-base", @base, sha)
        return [] unless Shell::Out.ok?(base)

        log = @git.run("log", "--format=%s", "#{base.stdout.strip}..#{sha}")
        Shell::Out.ok?(log) ? log.stdout.split("\n") : []
      end
    end
  end
end
