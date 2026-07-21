# frozen_string_literal: true

module Lain
  module CLI
    # `lain friction <session>`: resolves a session identifier the same way a
    # user names one to `lain sessions`/`lain chat --resume` -- an explicit
    # path, or a bare filename under this project's session dir -- and prints
    # {Friction::Report}'s rendering. Returns a String; only the frontend
    # prints (output discipline, {Bench::CLI}'s precedent).
    class Friction
      # No file on disk answers to the given selector, under any of the
      # resolutions this class tries.
      class SessionNotFound < Error; end

      def initialize(paths: Paths.new)
        @paths = paths
      end

      # @param selector [String] an explicit path, a bare filename, or a
      #   filename missing its ".ndjson" suffix -- all resolved under this
      #   project's session dir ({CLI::Sessions}' `dir` accessor, the same
      #   `Paths#sessions_dir` root)
      # @return [String] the rendered friction report
      # @raise [SessionNotFound]
      def report_for(selector)
        Lain::Friction::Report.new(Journal.records(File.foreach(resolve(selector)))).render
      end

      private

      def dir = @dir ||= @paths.sessions_dir

      def resolve(selector)
        candidates = [selector, File.join(dir, selector), File.join(dir, "#{selector}.ndjson")]
        candidates.find { |path| File.file?(path) } ||
          raise(SessionNotFound, "no session found for #{selector.inspect} -- looked at #{candidates.join(", ")}")
      end
    end
  end
end
