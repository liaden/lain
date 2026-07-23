# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # The run-state walk: every FILE of a resume chain, oldest first. A
      # resumed session's reads, todos, and memory writes live in every file
      # of the chain, so {Resume#replay} folds the concatenated records this
      # class enumerates. A pre-existing, self-contained responsibility split
      # out of {Resume} the same way {Salvager} and {Selector} were (CLAUDE.md:
      # extract a real collaborator, never loosen `Metrics/*`).
      #
      # Carries its OWN visited-set guard (ResumeChain::GuardedResolver's
      # idiom) rather than trusting that the Loader -- which also refuses
      # cycles -- ran first: that would be an ordering invariant a reorder of
      # {Resume}'s statements silently breaks, reintroducing the
      # SystemStackError the guard exists to prevent (panel fix round).
      class ChainWalk
        # @param dir [String] the project's session directory chain basenames
        #   resolve within
        def initialize(dir:)
          @dir = dir
        end

        # @return [Array<String>] every line of every file, oldest file first
        def entries(path)
          paths(path).flat_map { |file| File.foreach(file).to_a }
        end

        # @return [Array<String>] the chain's file paths, oldest first
        # @raise [Refusal] on a cyclic `resumed_from`
        def paths(path, visited = [])
          basename = File.basename(path)
          revisit!(basename, visited)
          prior = prior_basename(path)
          prior.nil? ? [path] : paths(File.join(@dir, prior), visited + [basename]) + [path]
        end

        private

        def prior_basename(path)
          Journal.records(File.foreach(path), type: SessionRecord::HEADER_TYPE)
                 .first&.dig("resumed_from", "file")
        end

        def revisit!(basename, visited)
          return unless visited.include?(basename)

          raise Refusal, "resumed_from revisits #{basename.inspect} " \
                         "(walk: #{[*visited, basename].join(" -> ")}); a resume chain must not cycle"
        end
      end
    end
  end
end
