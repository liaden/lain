# frozen_string_literal: true

require "open3"

module TestMap
  # Never requires lain: the commit hook runs before `rake compile` has built lain.so.
  module Git
    # Mirrors Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB; a spec keeps the two equal.
    SCRUB = %w[
      GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_COMMON_DIR
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
      GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_REPLACE_REF_BASE
      GIT_NO_REPLACE_OBJECTS GIT_GRAFT_FILE GIT_SHALLOW_FILE GIT_IMPLICIT_WORK_TREE
      GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    ].freeze

    def self.run(*args, repo:, scrub: true)
      env = scrub ? SCRUB.to_h { |key| [key, nil] } : {}
      out, err, status = Open3.capture3(env, "git", "-C", repo.to_s, *args)
      raise "git #{args.join(" ")} failed: #{err}" unless status.success?

      out.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
