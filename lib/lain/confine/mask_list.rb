# frozen_string_literal: true

require "digest"

module Lain
  module Confine
    # The files a sandbox hides from a command, kept current for a session whose
    # tree changes under it. Listing is one `git ls-files` per ask; classifying
    # is the slow part, so only names the previous listing lacked are classified.
    #
    # Not covered: files below the top level of a tmp, vendor, target or
    # node_modules directory at any depth. Their own top-level files are listed.
    class MaskList
      # Large and ignored by design; `/*/**` prunes below the directory's top level only.
      PRUNED = %w[tmp vendor target node_modules].freeze
      EXCLUDES = PRUNED.map { ":(exclude,glob)**/#{_1}/*/**" }.freeze
      TIMEOUT = 10

      # @param root [String] absolute project root; names are listed and masked under it
      # @param policy [#call] returns the session's one {Sensitivity::Policy}; called on
      #   first use, because the toolset holding this list is built before the policy
      # @param shell_out [#call] `(*argv, **opts) -> Shell::Out`
      def initialize(root:, policy:, shell_out: Shell::Out.method(:new))
        @root = root
        @policy = policy
        @shell_out = shell_out
        @digest = nil
        @names = []
        @masks = {}
        @priming = nil
      end

      # Starts the first classification off the caller's thread, so a slow one
      # does not land on the first command. {#masks} joins it.
      #
      # @return [self]
      def prime
        @priming ||= Thread.new { refresh }.tap { _1.report_on_exception = false }
        self
      end

      # @return [Array<Sensitivity::Policy::Mask>] resolved paths that exist now, in listing order
      def masks
        join_priming
        refresh
        @masks.values.select { File.exist?(_1.path) }
      end

      private

      def join_priming
        priming = @priming
        @priming = nil
        priming&.value
      end

      def refresh
        names = listing
        digest = Digest::SHA256.digest(names.join("\0"))
        return if digest == @digest

        @policy.call.mask_paths(names - @names, cwd: @root).each { @masks[_1.path] = _1 }
        @names = names
        @digest = digest
      end

      # No `--exclude-standard`: the secrets a mask exists for are usually the ignored ones.
      def listing
        shell = @shell_out.call("git", "-C", @root, "ls-files", "-z", "-co", "--", ".", *EXCLUDES,
                                environment: Isolation::Worktree::GIT_CONTEXT_SCRUB, timeout: TIMEOUT)
        shell.run_command
        Shell::Out.ok?(shell) ? shell.stdout.split("\0").uniq : []
      rescue Shell::Out::Timeout, SystemCallError
        []
      end
    end
  end
end
