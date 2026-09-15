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

      # The lineages come from the file rather than from its records: only a
      # path can follow a resumed session's chain, and a refusal names it.
      #
      # @param selector [String] an explicit path, a bare filename, or a
      #   filename missing its ".ndjson" suffix -- all resolved under this
      #   project's session dir ({CLI::Sessions}' `dir` accessor, the same
      #   `Paths#sessions_dir` root)
      # @return [String] the rendered friction report
      # @raise [SessionFile::SessionNotFound]
      # @raise [Lain::Error] naming the file, for a session that cannot be read
      def report(selector)
        path = SessionFile.resolve(selector, paths: @paths)
        lineages = Bench::Session::Lineages.read(path)
        render(path, Journal.records(File.foreach(path)).to_a, lineages)
      end

      private

      # {Bench::Session::Lineages.read} already names the file in its own
      # refusals; this names it in the graders'.
      def render(path, records, lineages)
        Lain::Friction::Report.new(records, lineages:).render
      rescue Lain::Error => e
        raise Lain::Error, "#{path}: #{e.message}"
      end
    end
  end
end
