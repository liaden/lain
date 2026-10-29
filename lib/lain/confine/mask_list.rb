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
    #
    # Each related directory the policy names is listed the same way under its
    # own root, and is read only while its last listing answered: one that is
    # not a repository never is, since no listing can find its secrets. Below a
    # related root, each directory the prune skips is masked whole instead,
    # whether git's listing or the walk below a nested repo skipped it, so the
    # gap above stays the project's alone.
    class MaskList
      # Large and ignored by design; `/*/**` prunes below the directory's top level only.
      PRUNED = %w[tmp vendor target node_modules].freeze
      EXCLUDES = PRUNED.map { ":(exclude,glob)**/#{_1}/*/**" }.freeze
      PRUNES = PRUNED.map { ":(glob)**/#{_1}/*/**" }.freeze
      TIMEOUT = 10
      PRUNED_REASON = :pruned

      Related = Data.define(:roots, :masks)

      # What a reader may read beyond the project, answered as 1 value so no
      # refresh can fall between a root and its masks.
      class Related
        NONE = new(roots: [].freeze, masks: [].freeze)
      end

      # @param root [String] absolute project root; names are listed and masked under it
      # @param policy [#call] returns the session's one {Sensitivity::Policy}; called on
      #   first use, because the toolset holding this list is built before the policy
      # @param shell_out [#call] `(*argv, **opts) -> Shell::Out`
      def initialize(root:, policy:, shell_out: Shell::Out.method(:new))
        @policy = policy
        @shell_out = shell_out
        @project = Tree.new(root, shell_out)
        @priming = nil
        @related = {}
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

      # @return [Array<Sensitivity::Policy::Mask>] the project's: resolved paths that exist now, in listing order
      def masks
        join_priming
        refresh
        @project.current
      end

      # As the last {#masks} left it, without listing again.
      #
      # @return [Related] each related directory whose last listing answered, as the policy names it, and its masks
      def related
        join_priming
        listed = @related.values.select(&:listed?)
        Related.new(roots: listed.map(&:root).freeze, masks: listed.flat_map(&:current).uniq(&:path).freeze)
      end

      # The session's own policy on one path, which a grant outside the project asks before it reads one.
      #
      # @param path [String] absolute
      # @return [Sensitivity::Verdict]
      def classify(path) = @policy.call.classify(path)

      # @param path [String] a resolved path from {#masks} or {#related}
      # @return [Array<String>] the listed names that landed on it; a related directory's joined to its root
      def landed_on(path)
        related = @related.values.flat_map { |tree| tree.landed_on(path).map { File.join(tree.root, _1) } }
        [*@project.landed_on(path), *related]
      end

      private

      # A failed project listing unlists every related directory, since none was listed this time.
      def refresh
        policy = @project.refresh(@policy)
        policy ? relate(policy) : @related.each_value(&:unlist)
      end

      # A directory the policy would hide is never read whole, whatever its listing masks.
      def relate(policy)
        dirs = policy.related_directories.select { File.directory?(_1) && policy.classify(_1).ordinary? }
        @related = dirs.to_h { |dir| [dir, @related.fetch(dir) { Tree.new(dir, @shell_out, whole_pruned: true) }] }
        @related.each_value { _1.refresh(-> { policy }) }
      end

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
          @pruned = []
        end

        # @return [Array<String>] each directory the walk did not enter for lying below a pruned one, by real path
        attr_reader :pruned

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

        def inside_root?(real) = Landing.under?(real, real_root)

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

          return Find.prune if File.basename(rest) == GIT_DIR
          return unless pruned?("#{walking.spelling}#{rest}") || pruned?(relative(path.b))

          @pruned << path.b
          Find.prune
        end

        def pruned?(name) = name.b.split(SEPARATOR)[0...-1].any? { PRUNED.include?(_1) }
      end
      private_constant :Beneath

      # One root's listing and the masks judged from it. A failed listing keeps
      # the last masks, since an empty set would unmask everything, and says
      # it was not listed, which is what keeps a related directory unread.
      class Tree
        # @param root [String] absolute
        # @param shell_out [#call]
        # @param whole_pruned [Boolean] whether each directory the prune skips is masked whole
        def initialize(root, shell_out, whole_pruned: false)
          # Bytes, as git lists a name and Linux holds one, so a name and the root always join.
          @root = root.b
          @shell_out = shell_out
          @whole_pruned = whole_pruned
          @state = State.new(identities: {}, masks: {})
          @pruned = []
          @listed = false
        end

        # @return [String]
        def root = outward(@root)

        # @return [Boolean] whether the last listing answered
        def listed? = @listed

        # @return [void]
        def unlist
          @listed = false
        end

        # The policy is read only once the listing answered, and before the
        # walk, which asks it which directory names a rule matches.
        #
        # @param policy [#call]
        # @return [Sensitivity::Policy, nil] the policy read, or nil when the listing failed
        def refresh(policy)
          listed = listing
          pruned = @whole_pruned ? pruned_dirs : []
          @listed = !(listed.nil? || pruned.nil?)
          return unless @listed

          read = policy.call
          beneath = Beneath.new(@root, read)
          @state = restated(listed, read, beneath)
          @pruned = @whole_pruned ? [*pruned, *beneath.pruned.filter_map { pruned_mask(_1) }] : []
          read
        end

        # @return [Array<Sensitivity::Policy::Mask>] resolved paths that exist now, in listing order
        def current
          [*@state.masks.values, *@pruned].uniq(&:path).select { File.exist?(_1.path) }
                                          .map { _1.with(path: outward(_1.path)) }
        end

        # @param path [String]
        # @return [Array<String>] the listed names that landed on it
        def landed_on(path) = @state.masks.filter_map { |name, mask| outward(name) if mask.path.b == path.b }

        private

        # Held as bytes, handed out in the filesystem's encoding, which is what
        # every caller compares a path in.
        def outward(bytes) = bytes.dup.force_encoding(FILESYSTEM).freeze

        def restated(listed, policy, beneath)
          identities = beneath.with(listed.to_h { [_1, Identity.of(File.join(@root, _1))] })
          changed = identities.keys.reject { @state.identities.key?(_1) && @state.identities[_1] == identities[_1] }
          masks = @state.masks.slice(*identities.keys).except(*changed).merge(judged(policy, changed, identities))
          State.new(identities: identities.freeze, masks: masks.freeze)
        end

        def judged(policy, names, identities)
          return {} if names.empty?

          landings = Landings.new(names, identities, @root)
          policy.mask_paths(names, cwd: @root).each_with_object({}) do |mask, by_name|
            landings.of(mask.path).each { by_name[_1] = mask }
          end
        end

        # No `--exclude-standard`: the secrets a mask exists for are usually the ignored ones.
        def listing
          shell = git("ls-files", "-z", "-co", "--", ".", *EXCLUDES)
          Shell::Out.ok?(shell) ? shell.stdout.b.split("\0").uniq : nil
        rescue Shell::Out::Timeout, SystemCallError
          nil
        end

        # git lists what lies below a pruned directory's top as the directories
        # it would walk, each masked whole at the level below the prune.
        def pruned_dirs
          shell = git("ls-files", "-z", "-co", "--directory", "--", *PRUNES)
          return nil unless Shell::Out.ok?(shell)

          below = shell.stdout.b.split("\0").filter_map { below_prune(_1) }.uniq
          below.filter_map { pruned_mask(File.join(@root, _1)) }
        rescue Shell::Out::Timeout, SystemCallError
          nil
        end

        def below_prune(name)
          segments = name.chomp(File::SEPARATOR).split(File::SEPARATOR)
          index = segments[0...-1].index { PRUNED.include?(_1) }
          segments[0..(index + 1)].join(File::SEPARATOR) if index
        end

        # Only a directory still inside the root, by its real path, which bwrap needs.
        def pruned_mask(path)
          real = File.realpath(path).b
          return unless File.directory?(real) && Landing.under?(real, File.realpath(@root).b)

          Sensitivity::Policy::Mask.new(path: real.freeze, reason: PRUNED_REASON)
        rescue SystemCallError
          nil
        end

        # Run before every call, outside the sandbox, in a tree the last call wrote: no fsmonitor its config
        # names runs, and a clone lain cut is read only through its own git dir.
        def git(*, **)
          Isolation::Checkout.of(@root, shell_out_factory: @shell_out)
                             .run(*, timeout: TIMEOUT, pins: FileWalk::FSMONITOR_OFF, **)
        end
      end
      private_constant :Tree
    end
  end
end
