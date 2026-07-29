# frozen_string_literal: true

module Lain
  module CLI
    # `lain friction <session>`: resolves a session identifier through
    # {CLI::SessionFile} -- a name as `lain sessions` printed it, with or without
    # its suffix, or an explicit path -- and prints {Friction::Report}'s
    # rendering. `lain consolidate` and `lain improve` read through the same
    # resolver and raise the same refusal; `lain chat --resume` does NOT (it
    # prefix-matches instead, see {CLI::SessionFile}). Returns a String; only the
    # frontend prints (output discipline, {Bench::CLI}'s precedent).
    class Friction
      def initialize(paths: Paths.new)
        @paths = paths
      end

      # @param selector [String] an explicit path, a bare filename, or a
      #   filename missing its ".ndjson" suffix -- all resolved under this
      #   project's session dir ({CLI::Sessions}' `dir` accessor, the same
      #   `Paths#sessions_dir` root)
      # @return [String] the rendered friction report
      # @raise [SessionFile::SessionNotFound]
      def report(selector)
        records = Journal.records(File.foreach(SessionFile.resolve(selector, paths: @paths)))
        Lain::Friction::Report.new(records).render
      end
    end
  end
end
