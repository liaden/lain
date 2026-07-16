# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # Resolves `--resume [SELECTOR]` to one path under the project's session
      # dir: nil/"" picks the newest, an exact filename or unique prefix picks
      # that session. Split out of {Resume} (a pre-existing, self-contained
      # responsibility -- "which file does --resume mean") the same way
      # {Salvager} is: {Resume} grew past `Metrics/ClassLength` once T18's
      # salvage wiring landed, and CLAUDE.md's rule is to extract a real
      # collaborator, never loosen the limit.
      class Selector
        # @param dir [String] the project's session directory
        def initialize(dir:)
          @dir = dir
        end

        # @param selector [String, nil]
        # @return [String] the chosen file's full path
        # @raise [Refusal]
        def call(selector)
          names = session_names
          raise Refusal, "no sessions to resume under #{@dir}" if names.empty?

          File.join(@dir, chosen(names, selector.to_s))
        end

        private

        # UTC-timestamped filenames sort chronologically, so `.last` is the
        # newest -- also what makes resume idempotent: an exited-immediately
        # resumed session is itself the newest file, so a second `--resume`
        # continues the head of the CHAIN, never forking the original.
        def session_names
          Dir.children(@dir).select { |name| name.end_with?(".ndjson") }.sort
        end

        def chosen(names, selector)
          return names.last if selector.empty?
          return selector if names.include?(selector)

          matched(names, selector)
        end

        def matched(names, selector)
          matches = names.select { |name| name.start_with?(selector) }
          return matches.first if matches.size == 1

          raise Refusal, "no session matching #{selector.inspect} under #{@dir}" if matches.empty?

          raise Refusal, "#{selector.inspect} is ambiguous under #{@dir}: #{matches.join(", ")}"
        end
      end
    end
  end
end
