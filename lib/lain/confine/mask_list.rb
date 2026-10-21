# frozen_string_literal: true

require "find"

module Lain
  module Confine
    # The files or directories a sandbox hides from a command, kept current for a session whose
    # tree changes under it. Listing is one `git ls-files` per ask; classifying
    # is the slow part, so only a name that is new, or whose file changed
    # identity since it was classified, is classified. A swap keeps the name,
    # so the listing alone cannot see a plain file become a link to a secret.
    #
    # Not covered: files below the top level of a tmp, vendor, target or
    # node_modules directory at any depth, whether reached by name or through
    # a link, and a nested repo there included. Their own top-level files are
    # listed. Nor what lies beneath a link out of the root. A 2,000-level tree
    # costs about 1 s a refresh, since each lstat resolves the whole path:
    # accepted, as no real project nests so deep.
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
        # Bytes, as git lists a name and Linux holds one, so a name and the root always join.
        @root = root.b
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
        @state.masks.values.uniq(&:path).select { File.exist?(_1.path) }.map { _1.with(path: outward(_1.path)) }
      end

      # @param path [String] a resolved path from {#masks}
      # @return [Array<String>] the listed names that landed on it
      def landed_on(path) = @state.masks.filter_map { |name, mask| outward(name) if mask.path.b == path.b }

      private

      # Held as bytes, handed out in the filesystem's encoding, which is what
      # every caller compares a path in.
      def outward(bytes) = bytes.dup.force_encoding(Encoding.find("filesystem")).freeze

      def join_priming
        priming = @priming
        @priming = nil
        priming&.value
      end

      # Every name a listing held, as it was when judged, and the masks those names landed on.
      State = Data.define(:identities, :masks)
      private_constant :State

      # A link's target is part of it: replacing a link often reuses its inode.
      Identity = Data.define(:dev, :ino, :link, :target, :dir) do
        def self.of(path)
          stat = File.lstat(path)
          new(stat.dev, stat.ino, stat.symlink?, stat.symlink? ? target(path) : nil, stat.directory?)
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

      # A failed listing keeps the last state, since an empty one would unmask
      # everything. The policy is read only once the listing answered, and
      # before the walk, which asks it which directory names a rule matches.
      def refresh
        listed = listing
        return if listed.nil?

        policy = @policy.call
        identities = walked(listed, policy)
        changed = identities.keys.reject { @state.identities.key?(_1) && @state.identities[_1] == identities[_1] }
        masks = @state.masks.slice(*identities.keys).except(*changed).merge(judged(policy, changed, identities))
        @state = State.new(identities: identities.freeze, masks: masks.freeze)
      end

      def walked(listed, policy)
        Beneath.new(@root, policy).with(listed.to_h { [_1, Identity.of(File.join(@root, _1))] })
      end

      def judged(policy, names, identities)
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
          File.realpath(name, @root).b == landing.b
        rescue SystemCallError
          false
        end
      end
      private_constant :Landings

      # git lists a nested repo, a submodule and a link to a directory each as 1
      # leaf, so the names beneath one are read off the disk, under the leaf's
      # own spelling, since that is the name a command reads them by.
      #
      # A link is a way down only where the policy marks its spelling and its
      # landing's real path apart, since only then can a name through the link
      # judge unlike the same file by its real name, which the listing or a
      # walk already reaches. A mark only the spelling has is a rule reading
      # the link's route. The 2nd way is an exemption only the landing's real
      # path carries, which a name through the link escapes, so it judges by
      # the rule the exemption lifts. A landing is walked once per mark it
      # gains, which bounds the walks and ends every loop.
      class Beneath
        GIT_DIR = ".git"
        SEPARATOR = File::SEPARATOR
        # Its own mark, so a listed directory is walked once by its real name.
        LISTED = :listed

        Walk = Data.define(:spelling, :real)

        # @param root [String] the project root
        # @param policy [#marks] see {Sensitivity#marks}
        def initialize(root, policy)
          @root = root
          @policy = policy
          @walked = Set.new
        end

        # @param identities [Hash{String => Identity, nil}] by listed name
        # @return [Hash{String => Identity, nil}] each name, followed by every file beneath it when it is a directory
        def with(identities)
          identities.each_with_object({}) do |(name, identity), all|
            all[name] = identity
            walk(start(name.chomp(SEPARATOR), identity), all)
          end
        end

        private

        def real_root = @real_root ||= File.realpath(@root).b

        # A worklist rather than recursion, so no depth of tree runs out of stack.
        def walk(first, found)
          pending = [first].compact
          until pending.empty?
            each_file(pending.pop) do |name, identity|
              found[name] = identity
              pending.concat([start(name, identity)].compact)
            end
          end
        end

        def start(spelling, identity)
          real = landing(spelling, identity)
          return nil unless real && walkable?(spelling, real)

          gained = identity.link ? gained(spelling, relative(real)) : [LISTED]
          fresh = gained.select { @walked.add?([real, _1]) }
          fresh.empty? ? nil : Walk.new(spelling:, real:)
        rescue SystemCallError, EncodingError
          nil
        end

        # An unreadable side is gained wherever it is, so 2 never cancel.
        def gained(spelling, real)
          spelled = ask(:marks, spelling)
          own = ask(:marks, real)
          (spelled - own) | (ask(:lifts, real) - ask(:lifts, spelling)) | ((spelled | own) & Sensitivity::UNREADABLE_MARKS)
        end

        def ask(question, name) = @policy.public_send(question, File.join(@root, name))

        def landing(spelling, identity)
          if identity&.dir
            File.realpath(spelling, @root).b
          elsif identity&.link && identity.target.is_a?(String) && File.directory?(identity.target)
            identity.target.b
          end
        end

        def walkable?(spelling, real) = inside_root?(real) && !pruned?(spelling) && !pruned?(relative(real))

        def inside_root?(real) = real == real_root || real.start_with?("#{real_root}#{SEPARATOR}")

        def relative(real) = real.delete_prefix(real_root).delete_prefix(SEPARATOR)

        # Find reads with lstat, so a link beneath is a name here and {#start}
        # decides whether it is a way down. Its paths keep the bytes of `top`.
        def each_file(walking, &)
          top = walking.real
          Find.find(top) do |path|
            rest = path.byteslice(top.bytesize..)
            visit(walking, path, rest, &) unless rest.empty?
          end
        end

        # A `.git` that is a link is a name like any other, which judge reads by.
        def visit(walking, path, rest)
          identity = Identity.of(path)
          return yield("#{walking.spelling}#{rest}", identity) unless identity&.dir

          Find.prune if File.basename(rest) == GIT_DIR || pruned?("#{walking.spelling}#{rest}") ||
                        pruned?(relative(path.b))
        end

        def pruned?(name) = name.b.split(SEPARATOR)[0...-1].any? { PRUNED.include?(_1) }
      end
      private_constant :Beneath

      # No `--exclude-standard`: the secrets a mask exists for are usually the ignored ones.
      def listing
        shell = Isolation::Checkout.new(@root, shell_out_factory: @shell_out)
                                   .run("ls-files", "-z", "-co", "--", ".", *EXCLUDES, timeout: TIMEOUT)
        Shell::Out.ok?(shell) ? shell.stdout.b.split("\0").uniq : nil
      rescue Shell::Out::Timeout, SystemCallError
        nil
      end
    end
  end
end
