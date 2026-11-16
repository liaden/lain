# frozen_string_literal: true

module Lain
  module CLI
    # `qa-lain verify SESSION`: resolves a session through {CLI::SessionFile} and says
    # whether its record chain holds, offline. The words are for a person, and the
    # status for a script: 1 only when something was edited, inserted or removed,
    # or the last line fails a tip kept elsewhere. A file that predates chaining
    # and a crash tail are not tampering, so neither fails.
    class JournalVerify
      # @param sink [#puts] where the report goes
      # @param paths [Paths] resolves this project's session dirs
      # @param project [Project] whose sessions are searched
      def initialize(sink:, paths: Paths.new, project: Project::Resolver.default_project)
        @sink = sink
        @paths = paths
        @project = project
      end

      # @param selector [String] as {CLI::SessionFile.resolve} takes it
      # @param tip [String, nil] a tip a previous run printed
      # @return [Integer] the exit status
      # @raise [SessionFile::SessionNotFound]
      def run(selector, tip: nil)
        report = Journal::Verify.new(SessionFile.resolve(selector, paths: @paths, project: @project)).call(tip:)
        @sink.puts(describe(report, tip))
        report.reason.then { |reason| %i[edited tip_mismatch].include?(reason) ? 1 : 0 }
      end

      private

      def describe(report, kept)
        case report.reason
        when :intact then intact(report, kept)
        when :unchained then "unchained: #{report.lines} lines (written before record chaining)"
        when :edited then edited(report)
        when :tip_mismatch then mismatch(report, kept)
        when :torn_tail then torn(report)
        else raise ArgumentError, "no words for the verify reason #{report.reason.inspect}"
        end
      end

      def intact(report, kept)
        [
          "chain intact: #{report.lines} lines, tip #{report.tip}",
          *tip_held(report, kept),
          *started_late(report),
          *report.covered.map { |line| sealed(line) },
          *report.unvouched.map { |line| unvouched(line) },
          "the last line is held only by a tip kept elsewhere: keep this one and check it with --tip"
        ].join("\n")
      end

      def started_late(report)
        return [] if report.chained_from == 1

        ["chained from line #{report.chained_from}; the lines before it were written before chaining"]
      end

      def tip_held(report, kept)
        return [] if kept.nil? || report.tip_line == report.lines

        ["tip held by line #{report.tip_line}; lines #{report.tip_line + 1}..#{report.lines} are after it " \
         "and unchecked by the tip"]
      end

      def unvouched(line) = "line #{line} is held by nothing: line #{line + 1} carries no link"

      def sealed(line) = "sealed crash line #{line}: unparseable, and the line after it vouches for its bytes"

      def edited(report)
        "chain broken at line #{report.first_break}: its link does not match the line before it, " \
          "so a line before it was edited, inserted or removed"
      end

      def mismatch(report, kept)
        return "tip mismatch: the file is empty, and the kept tip #{kept} is not the origin" if report.lines.zero?

        "tip mismatch: the last line (#{report.first_break}) does not match the kept tip #{kept}; " \
          "it was edited, or lines at the end were removed"
      end

      def torn(report)
        "chain intact up to line #{report.first_break - 1}; line #{report.first_break} is a torn tail " \
          "(a crash mid-write, not an edit), tip #{report.tip}; a crash and a cut last record look the same, " \
          "and only a kept tip tells them apart"
      end
    end
  end
end
