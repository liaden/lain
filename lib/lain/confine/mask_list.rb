# frozen_string_literal: true

module Lain
  module Confine
    # The files a sandbox hides from a command, kept current for a session whose
    # tree changes under it. Listing is one `git ls-files` per ask; classifying
    # is the slow part, so only a name that is new, or whose file changed
    # identity since it was classified, is classified. A swap keeps the name,
    # so the listing alone cannot see a plain file become a link to a secret.
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
        @state = State.new(identities: {}, masks: {})
        @priming = nil
      end

      # Starts the first classification off the caller's thread, so a slow one
      # does not land on the first command. {#masks} joins it. Call it only once
      # the policy can be built: a failure there comes back from {#masks}.
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
        @state.masks.values.uniq(&:path).select { File.exist?(_1.path) }
      end

      private

      def join_priming
        priming = @priming
        @priming = nil
        priming&.value
      end

      # Every name a listing held, as it was when judged, and the masks those names landed on.
      State = Data.define(:identities, :masks)
      private_constant :State

      # A link's target is part of it: replacing a link often reuses its inode.
      Identity = Data.define(:dev, :ino, :link, :target) do
        def self.of(path)
          stat = File.lstat(path)
          new(stat.dev, stat.ino, stat.symlink?, stat.symlink? ? target(path) : nil)
        rescue SystemCallError
          nil
        end

        def self.target(path)
          File.realpath(path)
        rescue SystemCallError
          :dangling
        end
      end
      private_constant :Identity

      # A failed listing keeps the last state, since an empty one would unmask everything.
      def refresh
        identities = listing&.to_h { [_1, Identity.of(File.join(@root, _1))] }
        return if identities.nil?

        changed = identities.keys.reject { @state.identities.key?(_1) && @state.identities[_1] == identities[_1] }
        masks = @state.masks.slice(*identities.keys).except(*changed).merge(judged(changed, identities))
        @state = State.new(identities: identities.freeze, masks: masks.freeze)
      end

      # Read before the empty check: an empty listing's first ask must still
      # surface a policy that cannot be built.
      def judged(names, identities)
        policy = @policy.call
        return {} if names.empty?

        landings = Landings.new(names, identities, @root)
        policy.mask_paths(names, cwd: @root).each_with_object({}) do |mask, by_name|
          landings.of(mask.path).each { by_name[_1] = mask }
        end
      end

      # Only a link or a name sharing the path's basename can resolve to it,
      # so few names pay a realpath.
      class Landings
        def initialize(names, identities, root)
          @links = names.select { identities[_1]&.link }
          @by_basename = names.group_by { File.basename(_1) }
          @root = root
        end

        # @param landing [String] a resolved path
        # @return [Array<String>] the names that resolve to it
        def of(landing)
          (@links | @by_basename.fetch(File.basename(landing), [])).select { lands?(_1, landing) }
        end

        private

        def lands?(name, landing)
          File.realpath(name, @root) == landing
        rescue SystemCallError
          false
        end
      end
      private_constant :Landings

      # No `--exclude-standard`: the secrets a mask exists for are usually the ignored ones.
      def listing
        shell = Isolation::Checkout.new(@root, shell_out_factory: @shell_out)
                                   .run("ls-files", "-z", "-co", "--", ".", *EXCLUDES, timeout: TIMEOUT)
        Shell::Out.ok?(shell) ? shell.stdout.split("\0").uniq : nil
      rescue Shell::Out::Timeout, SystemCallError
        nil
      end
    end
  end
end
