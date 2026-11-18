# frozen_string_literal: true

module RuboCop
  module Cop
    module Lain
      # A spec that spawns git must pass SeedRepo::SCRUB as the environment.
      #
      # A commit hook in a linked worktree exports GIT_DIR, and a fixture's bare `git init`
      # under it reinitializes the worktree's admin dir as a BARE repository in the config
      # every worktree shares; a fixture's `update-index` rewrites that worktree's index.
      # On main the hook exports no GIT_DIR, so nothing shows until a commit is made from a
      # worktree. The call site must show the scrub constant itself, so an env built from it
      # elsewhere is not seen. Backticks, %x and Open3.pipeline* are not checked.
      #
      # @example
      #   # bad
      #   Open3.capture3("git", "status")
      #
      #   # good
      #   Open3.capture3(SeedRepo::SCRUB, "git", "status")
      class GitFixtureScrub < Base
        MSG = "Spawning `git` without `SeedRepo::SCRUB` inherits the commit hook's GIT_DIR and " \
              "GIT_INDEX_FILE, which redirect the fixture onto the real repository. Pass " \
              "`SeedRepo::SCRUB` as the environment, whole: a partial one is not judged."

        RESTRICT_ON_SEND = %i[popen capture2 capture2e capture3 popen2 popen2e popen3 system spawn].freeze

        def on_send(node)
          add_offense(node.loc.selector) if unscrubbed_git?(node)
        end

        alias on_csend on_send

        private

        def unscrubbed_git?(node)
          first, second = node.arguments
          env, program = literal_program?(first) ? [nil, first] : [first, second]
          git_program?(program) && !scrubbed?(env)
        end

        def literal_program?(arg) = arg&.str_type? || arg&.array_type?

        def git_program?(arg)
          arg = arg.children.first if arg&.array_type?
          arg&.str_type? && arg.value == "git"
        end

        def scrubbed?(env) = !env.nil? && env.each_node(:const).any? { |const| const.short_name.end_with?("SCRUB") }
      end
    end
  end
end
