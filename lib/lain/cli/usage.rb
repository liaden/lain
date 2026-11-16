# frozen_string_literal: true

module Lain
  module CLI
    # `qa-lain usage SESSION`: what a session spent, by the command and role that paid it, read offline
    # from its turn_usage records.
    class Usage
      HEADER = %w[COMMAND ROLE INPUT OUTPUT].freeze
      NO_COMMAND = "-"
      JUDGE = Approval::Judge::ROLE.to_s
      JUDGE_NOTE = "#{JUDGE} spend is not split by command: it has no view of the command the chat is running".freeze

      # @param selector [String] as {CLI::SessionFile.resolve} takes it
      # @param sink [#puts] where the table goes
      # @param paths [Paths] resolves this project's session dirs
      # @param project [Project] whose sessions are searched
      def initialize(selector:, sink:, paths: Paths.new, project: Project::Resolver.default_project)
        @selector = selector
        @sink = sink
        @paths = paths
        @project = project
      end

      # @return [Integer] the exit status
      # @raise [SessionFile::SessionNotFound]
      def run
        spent = folded
        @sink.puts(table(spent))
        @sink.puts("", JUDGE_NOTE) if spent.keys.any? { |(_command, role)| role == JUDGE }
        0
      end

      private

      def folded
        file = SessionFile.resolve(@selector, paths: @paths, project: @project)
        Journal::Projection::Usage.over(Journal.records(File.foreach(file), type: "turn_usage", typed: true)).value
      end

      def table(spent)
        lines = [HEADER, *rows(spent).sort_by { _1.first(2) }].map { |row| row.map(&:to_s) }
        widths = lines.transpose.map { |column| column.map(&:size).max }
        lines.map { |row| row.zip(widths).map { |cell, width| cell.ljust(width) }.join("  ").rstrip }
      end

      def rows(spent)
        spent.map do |(command, role), usage|
          [command || NO_COMMAND, role, usage.input_tokens, usage.output_tokens]
        end
      end
    end
  end
end
