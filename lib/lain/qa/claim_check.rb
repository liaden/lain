# frozen_string_literal: true

require "shellwords"

module Lain
  module QA
    # The ladder's free rung: what the work CLAIMED against what the changeset
    # PERFORMED, with no model asked.
    #
    # It runs first because it is the cheapest defect there is to find and the
    # most expensive to find late. A card whose named spec file never appeared
    # is a card whose acceptance criteria were never turned into anything that
    # can fail; no model needs to read a line to know that.
    #
    # Pure over two lists. Where they came from -- a plan's claims, an
    # implementer's hand-back, {Changeset} -- is the caller's, and the range is
    # only quoted back so each finding carries the command that reproduces it.
    class ClaimCheck
      # A claim is a PATHSPEC, which {PlanCards} argues: plans state template
      # and generated files as globs, brace lists and bare directories, and an
      # exact match would report work that was done as a card that never did
      # it. `FNM_PATHNAME` so a plain wildcard stops at a directory boundary,
      # `FNM_EXTGLOB` for the brace lists.
      GLOB = File::FNM_PATHNAME | File::FNM_EXTGLOB

      # @param claims [Hash{String=>Array<String>}] claimant (a card id) to the
      #   pathspecs it says it changed
      # @param changed [Array<String>] the paths the changeset really touches
      # @param range [String] the revision range `changed` was read over
      # @raise [MalformedFinding] for a claim, a path or a range that names
      #   nothing -- see the `named` note below
      def initialize(claims:, changed:, range:)
        @claims = claims.transform_values { |paths| paths.map { |path| named(path, :claim) } }
        @changed = changed.map { |path| named(path, :path) }
        @range = named(range, :range)
      end

      # @return [Array<Finding>] unperformed claims first, then unclaimed work
      def findings = unperformed + unclaimed

      private

      # {Finding}'s own refusal cannot see this one: a nil claim scrubs to ""
      # and the prose around it keeps the summary non-blank, so the finding is
      # filed, holds the work, and names no path at all.
      def named(value, field) = QA.word!(value, field:, refusal: MalformedFinding)

      def unperformed
        @claims.flat_map do |card, pathspecs|
          pathspecs.reject { |pathspec| performed?(pathspec) }.map { |pathspec| unperformed_finding(card, pathspec) }
        end
      end

      # Scope creep is carried, never held on: a shared file an orchestrator
      # wired is exactly this shape and is not a defect.
      def unclaimed = @changed.reject { |path| claimed?(path) }.map { |path| unclaimed_finding(path) }

      def claimed?(path) = @claims.values.flatten.any? { |pathspec| matches?(pathspec, path) }

      def performed?(pathspec) = @changed.any? { |path| matches?(pathspec, path) }

      def matches?(pathspec, path)
        pathspec == path || under?(pathspec, path) || File.fnmatch?(pathspec, path, flags(pathspec))
      end

      # git's own leading-directory rule, which is what an author writing
      # `spec/support/nulls/` or `lib/lain/algebra` means: a pathspec matches
      # any path beneath it. The boundary is part of the prefix, so `lib` does
      # not claim `library/`.
      def under?(pathspec, path) = path.start_with?("#{pathspec.delete_suffix("/")}/")

      # `**` is how a plan asks to recurse, spelled as git's `:(glob)` magic
      # spells it. Under `FNM_PATHNAME` a trailing `**` silently means `*` and
      # stops at the first boundary, so a claim that asks for it gives the
      # wildcard the whole path.
      def flags(pathspec) = pathspec.include?("**") ? File::FNM_EXTGLOB : GLOB

      # Every quoted command is one a human is invited to paste, so a path
      # holding a space is two pathspecs that print nothing whatever the truth
      # is, and a `$(...)` in either is a command nobody meant to run.
      def shell(word) = Shellwords.escape(word)

      def unperformed_finding(card, pathspec)
        Finding.new(severity: "major", criterion: "#{card}/Files", tier: "t0",
                    summary: "#{card} claims #{pathspec}, and the changeset never touches it",
                    evidence: "`git diff --name-only #{shell(@range)}` lists #{@changed.size} paths, none matching it",
                    reproduction: "git diff --name-only #{shell(@range)} -- #{shell(pathspec)}   # prints nothing")
      end

      def unclaimed_finding(path)
        Finding.new(severity: "minor", criterion: "plan/Files", tier: "t0",
                    summary: "#{path} changed, and no card's Files names it",
                    evidence: "`git diff --name-only #{shell(@range)}` lists it; no card's claimed paths match it",
                    reproduction: "git diff --stat #{shell(@range)} -- #{shell(path)}")
      end
    end
  end
end
