# frozen_string_literal: true

require "find"

module Lain
  module Confine
    # The files or directories a sandbox hides from a command, kept current for a session whose
    # tree changes under it. Listing is one `git ls-files` per ask, or where git
    # does not answer, the project's own entries with a walk beneath each; classifying
    # is the slow part, so only a name that is new, or whose file changed
    # identity since it was classified, is classified. A swap keeps the name,
    # so the listing alone cannot see a plain file become a link to a secret.
    # A listed plain name is identified again only once its directory moves,
    # and a walk beneath a name only once a directory it read moves; a link
    # is identified every ask. So a filesystem that can change a directory and
    # leave its mtime and ctime unchanged, as NFS and overlayfs may, is not covered.
    #
    # Not covered: anything in or under a `.venv`, `venv`, `__pycache__`, `.tox`,
    # `.mypy_cache` or `.pytest_cache` directory, the directory itself included:
    # at any depth where git lists, but only at the top level where the walk
    # stands in, so a deeper one is walked and masked. Nor files below the top level of a tmp, vendor, target or
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
      # Tooling directories that hold no project secret and run to tens of thousands of files.
      PRUNED_WHOLE = %w[.venv venv __pycache__ .tox .mypy_cache .pytest_cache].freeze
      EXCLUDES = (PRUNED.map { ":(exclude,glob)**/#{_1}/*/**" } +
                  PRUNED_WHOLE.flat_map { [":(exclude,glob)**/#{_1}/**", ":(exclude,glob)**/#{_1}"] }).freeze
      PRUNES = PRUNED.map { ":(glob)**/#{_1}/*/**" }.freeze
      TIMEOUT = 10
      PRUNED_REASON = :pruned
      # Follows a link, so a name is stamped by the directory it lives in, whatever its parent's spelling.
      DIRECTORY_STAT = File.method(:stat)
      private_constant :DIRECTORY_STAT

      Related = Data.define(:roots, :masks, :reads, :execs)

      # A project's names as git lists them, for every reader of a project's files, over a tree a sandboxed call
      # wrote. No `--exclude-standard`: the secrets a mask exists for are usually the ignored ones.
      module Listing
        # @param root [String] absolute
        # @param shell_out [#call] `(*argv, **opts) -> Shell::Out`
        # @return [Array<String>, nil] binary names relative to the root; nil when git did not answer
        def self.of(root, shell_out) = names(listed(root, shell_out))

        # @param root [String] absolute
        # @param shell_out [#call]
        # @return [Shell::Out, Isolation::Checkout::Done, nil] the listing's run, its stderr included; nil when
        #   git could not be run
        def self.listed(root, shell_out)
          git(root, shell_out, "ls-files", "-z", "-co", "--", ".", *EXCLUDES)
        rescue Shell::Out::Timeout, SystemCallError
          nil
        end

        # @param shell [Shell::Out, Isolation::Checkout::Done, nil] see {.listed}
        # @return [Array<String>, nil] as {.of}
        def self.names(shell) = shell && Shell::Out.ok?(shell) ? shell.stdout.b.split("\0").uniq : nil

        # No fsmonitor a checkout's config names runs, and a clone lain cut is read only through its own git dir.
        #
        # @return [Shell::Out, Isolation::Checkout::Done]
        def self.git(root, shell_out, *argv)
          Isolation::Checkout.of(root, shell_out_factory: shell_out)
                             .run(*argv, timeout: TIMEOUT, pins: Isolation::Checkout::FSMONITOR_OFF)
        end
      end

      # What a call may read beyond the project, answered as 1 value so no
      # refresh can fall between a root and its masks. `reads` are the
      # session's read roots: no listing stands behind them, because a call
      # reaches the reader only once its words' bytes were checked. `execs`
      # are the build output the session's bounds run.
      class Related
        def initialize(roots:, masks:, reads: [].freeze, execs: ExecRules::NONE) = super

        NONE = new(roots: [].freeze, masks: [].freeze)
      end

      # @param root [String] absolute project root; names are listed and masked under it
      # @param policy [#call] returns the session's one {Sensitivity::Policy}; called on
      #   first use, because the toolset holding this list is built before the policy
      # @param shell_out [#call] `(*argv, **opts) -> Shell::Out`
      # @param stat [#call] `(path) -> File::Stat`, how a directory read for names is stamped
      # @param taint [#call] returns the session's {Sensitivity::Taint}, read on each ask, as the policy is
      def initialize(root:, policy:, shell_out: Shell::Out.method(:new), stat: DIRECTORY_STAT,
                     taint: -> { Sensitivity::Taint::NONE })
        @policy = policy
        @taint = taint
        @shell_out = shell_out
        @stat = stat
        @project = Tree.new(root, shell_out, stat:, walks_unlisted: true)
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

      # A tainted file keeps its name and inode, so no stamp moves for it, and it is joined on every ask.
      #
      # @return [Array<Sensitivity::Policy::Mask>] the project's: resolved paths that exist now, in listing
      #   order, then each tainted file not among them
      def masks
        join_priming
        refresh
        tainted(@project.current)
      end

      # As the last {#masks} left it, without listing again.
      #
      # @return [Related] each related directory whose last listing answered, as the policy names it, and its
      #   masks, beside each read root that exists now and the exec rules of the policy's bounds
      def related
        join_priming
        listed = @related.values.select(&:listed?)
        policy = @policy.call
        Related.new(roots: listed.map(&:root).freeze, masks: listed.flat_map(&:current).uniq(&:path).freeze,
                    reads: policy.read_roots.select { File.directory?(_1) }.freeze, execs: policy.bounds.execs)
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
        @related = dirs.to_h { |dir| [dir, @related.fetch(dir) { related_tree(dir) }] }
        @related.each_value { _1.refresh(-> { policy }) }
      end

      def related_tree(dir) = Tree.new(dir, @shell_out, stat: @stat, whole_pruned: true)

      # By bytes, since a held name that is not valid UTF-8 may be tagged apart from the listing's spelling of it.
      def tainted(listed)
        paths = @taint.call.paths
        return listed if paths.empty?

        masked = listed.to_set { _1.path.b }
        added = paths.reject { masked.include?(_1.b) }.select { File.exist?(_1) }
        [*listed, *added.map { Sensitivity::Policy::Mask.new(path: _1, reason: Sensitivity::Taint::REASON) }].freeze
      end

      def join_priming
        priming = @priming
        @priming = nil
        priming&.value
      end

      # Every name a listing held, as it was when judged, the masks those names landed on, the
      # directories they were read in, and each walk beneath a listed name.
      State = Data.define(:identities, :masks, :stamps, :leaves)
      private_constant :State

      # A directory as an ask found it. A new name, a removed one or a swap
      # moves it. ctime too, since a command can set mtime back and not ctime.
      Stamp = Data.define(:mtime, :ctime, :ino, :dev) do
        def self.of(path, stat)
          found = stat.call(path)
          new(found.mtime.dup.freeze, found.ctime.dup.freeze, found.ino, found.dev) if found.directory?
        rescue SystemCallError
          nil
        end

        def changed_at = [mtime, ctime].max
      end
      private_constant :Stamp

      # The directories one ask read names in. A stamp within a tick of the ask
      # cannot tell a change later in the same tick, the racy window of git's
      # index, so it vouches for nothing until a later ask stamps it clear.
      class Stamps
        # A whole-second filesystem stamps no nanoseconds; a kernel without
        # fine-grained timestamps stamps by clock tick, at most 10 ms.
        COARSE_TICK = 2.0
        FINE_TICK = 0.01

        # @param paths [Enumerable<String>] absolute
        # @param stat [#call] `(path) -> File::Stat`
        # @return [Stamps]
        def self.take(paths, stat)
          asked_at = Time.now
          new(asked_at, paths.to_h { [_1, Stamp.of(_1, stat)] })
        end

        # @param asked_at [Time] taken before any directory is stamped
        # @param by_path [Hash{String => Stamp, nil}]
        def initialize(asked_at, by_path)
          @asked_at = asked_at.dup.freeze
          @by_path = by_path.freeze
          freeze
        end

        # @param path [String]
        # @param now [Stamps] the current ask's
        # @return [Boolean] whether the directory is as this ask found it, and this ask could tell
        def settled?(path, now) = vouches?(@by_path[path], now.stamp(path))

        # @param stat [#call] stamps each directory again
        # @return [Boolean] whether every directory is as this ask found it, and this ask could tell
        def all_settled?(stat) = @by_path.all? { |path, stamp| vouches?(stamp, Stamp.of(path, stat)) }

        # @param path [String]
        # @return [Stamp, nil]
        def stamp(path) = @by_path[path]

        private

        def vouches?(stamp, now) = !stamp.nil? && stamp == now && !racy?(stamp)

        def racy?(stamp)
          changed_at = stamp.changed_at
          @asked_at - changed_at < (changed_at.nsec.zero? ? COARSE_TICK : FINE_TICK)
        end
      end
      private_constant :Stamps

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

        # A walk is reused only while every directory it read is settled, every
        # link it met resolves the same, and each walk it ceded is still taken.
        Leaf = Data.define(:identity, :found, :links, :walks, :ceded, :pruned, :stamps)

        # What one listed name's walk gathers, frozen into a {Leaf} once it ends.
        class Gathering
          # @param identity [Identity] the listed name's
          # @param stat [#call]
          def initialize(identity, stat)
            @identity = identity
            @stat = stat
            @asked_at = Time.now
            @found = {}
            @links = {}
            @walks = []
            @ceded = []
            @pruned = []
            @stamps = {}
          end

          # @return [void]
          def found(name, identity)
            @found[name] = identity
          end

          # @param keys [Array<Array>] landing and mark pairs this walk took
          # @param ceded [Array<Array>] the pairs an earlier walk had taken
          # @return [void]
          def took(keys, ceded)
            @walks.concat(keys)
            @ceded.concat(ceded)
          end

          # @param dir [String] a directory the walk reads, stamped before its entries are
          # @return [void]
          def reading(dir)
            @stamps[dir] = Stamp.of(dir, @stat)
          end

          # @return [String] the spelling, once a link at it is noted by its real path
          def noting_link(spelled, path, identity)
            @links[spelled] = path if identity&.link
            spelled
          end

          # @return [void]
          def prune(real)
            @pruned << real
          end

          # @return [Leaf] deeply frozen
          def leaf
            Ractor.make_shareable(Leaf.new(identity: @identity, found: @found, links: @links, walks: @walks,
                                           ceded: @ceded, pruned: @pruned, stamps: Stamps.new(@asked_at, @stamps)))
          end
        end
        private_constant :Gathering

        # @param root [String] the project root
        # @param policy [#marks] see {Sensitivity#marks}
        # @param leaves [Hash{String => Leaf}] the last ask's, by listed name
        # @param stat [#call] how a directory the walk reads is stamped
        def initialize(root, policy, leaves, stat)
          @root = root
          @policy = policy
          @stat = stat
          @before = leaves
          @leaves = {}
          @walked = Set.new
          @pruned = []
        end

        # @return [Array<String>] each directory the walk did not enter for lying below a pruned one, by real path
        attr_reader :pruned

        # @return [Hash{String => Leaf}] each listed name walked or reused, for the next ask
        attr_reader :leaves

        # @param identities [Hash{String => Identity, nil}] by listed name
        # @return [Hash{String => Identity, nil}] each name, followed by every file beneath it when it is a directory
        def with(identities)
          identities.each_with_object({}) do |(name, identity), all|
            all[name] = identity
            all.merge!(beneath(name, identity)) if identity&.dir || identity&.link
          end
        end

        private

        def beneath(name, identity)
          leaf = reused(name, identity) || walked(name, identity)
          @leaves[name] = leaf if leaf
          leaf ? leaf.found : {}
        end

        def reused(name, identity)
          leaf = @before[name]
          return unless leaf && leaf.identity == identity && current?(leaf)

          @walked.merge(leaf.walks)
          @pruned.concat(leaf.pruned)
          leaf
        end

        # Links are re-resolved, as a listed one is, since a chain moves no directory this walk read.
        def current?(leaf)
          leaf.walks.none? { @walked.include?(_1) } && (leaf.ceded - leaf.walks).all? { @walked.include?(_1) } &&
            leaf.stamps.all_settled?(@stat) && leaf.links.all? { |name, real| Identity.of(real) == leaf.found[name] }
        end

        def walked(name, identity)
          gathering = Gathering.new(identity, @stat)
          first = start(name.chomp(SEPARATOR), identity, gathering)
          return unless first

          walk(first, gathering)
          gathering.leaf
        end

        def real_root = @real_root ||= File.realpath(@root).b

        # A worklist rather than recursion, so no depth of tree runs out of stack.
        def walk(first, gathering)
          pending = [first]
          until pending.empty?
            each_file(pending.pop, gathering) do |name, identity|
              gathering.found(name, identity)
              pending.concat([start(name, identity, gathering)].compact)
            end
          end
        end

        def start(spelling, identity, gathering)
          real = landing(spelling, identity)
          return nil unless real && walkable?(spelling, real)

          gained = identity.link ? gained(spelling, relative(real)) : [LISTED]
          fresh = gained.select { @walked.add?([real, _1]) }
          gathering.took(fresh.map { [real, _1] }, (gained - fresh).map { [real, _1] })
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
        def each_file(walking, gathering, &)
          top = walking.real
          gathering.reading(top)
          Find.find(top) do |path|
            rest = path.byteslice(top.bytesize..)
            visit(walking, path, rest, gathering, &) unless rest.empty?
          end
        end

        # A `.git` that is a link is a name like any other, which judge reads by.
        def visit(walking, path, rest, gathering)
          identity = Identity.of(path)
          spelled = "#{walking.spelling}#{rest}"
          return yield(gathering.noting_link(spelled, path, identity), identity) unless identity&.dir

          return Find.prune if File.basename(rest) == GIT_DIR
          return gathering.reading(path) unless pruned?(spelled) || pruned?(relative(path.b))

          prune(path.b, gathering)
        end

        def prune(real, gathering)
          @pruned << real
          gathering.prune(real)
          Find.prune
        end

        def pruned?(name) = name.b.split(SEPARATOR)[0...-1].any? { PRUNED.include?(_1) }
      end
      private_constant :Beneath

      # One root's listing and the masks judged from it. A failed listing keeps
      # the last masks, since an empty set would unmask everything, and says
      # it was not listed, which is what keeps a related directory unread.
      # The project's own tree walks instead, as its root is read whatever its
      # listing says, so a project git cannot list is masked rather than bared.
      class Tree
        # @param root [String] absolute
        # @param shell_out [#call]
        # @param stat [#call] how a directory read for names is stamped
        # @param whole_pruned [Boolean] whether each directory the prune skips is masked whole
        # @param walks_unlisted [Boolean] whether the root's entries stand in for a listing git did not answer
        def initialize(root, shell_out, stat:, whole_pruned: false, walks_unlisted: false)
          # Bytes, as git lists a name and Linux holds one, so a name and the root always join.
          @root = root.b
          @shell_out = shell_out
          @stat = stat
          @whole_pruned = whole_pruned
          @walks_unlisted = walks_unlisted
          @state = blank_state
          @pruned = []
          @beneath_pruned = []
          @links = {}
          @read = nil
          @current = nil
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
        # walk, which asks it which directory names a rule matches. An ask
        # reuses the last masks while the policy and the directory stamps are
        # unchanged, since a name cannot be added or swapped without moving one.
        #
        # @param policy [#call]
        # @return [Sensitivity::Policy, nil] the policy read, or nil when the listing failed
        def refresh(policy)
          listed = listing
          pruned = @whole_pruned ? pruned_dirs : []
          @listed = !(listed.nil? || pruned.nil?)
          return unless @listed

          read = policy.call
          unchanged = reusable?(read)
          advance(listed, read) unless unchanged
          settle_pruned(@whole_pruned ? [*pruned, *@beneath_pruned] : [], !unchanged)
          read
        end

        # @return [Array<Sensitivity::Policy::Mask>] resolved paths that exist now, in listing order
        def current
          @current ||= built
        end

        # @param path [String]
        # @return [Array<String>] the listed names that landed on it
        def landed_on(path) = @state.masks.filter_map { |name, mask| outward(name) if mask.path.b == path.b }

        private

        # Held as bytes, handed out in the filesystem's encoding, which is what
        # every caller compares a path in.
        def outward(bytes) = bytes.dup.force_encoding(FILESYSTEM).freeze

        def blank_state = State.new(identities: {}, masks: {}, stamps: Stamps.new(Time.at(0), {}), leaves: {})

        def built
          [*@state.masks.values, *@pruned].uniq(&:path).select { File.exist?(_1.path) }
                                          .map { _1.with(path: outward(_1.path)) }.freeze
        end

        # Another policy judges every name afresh, so what was classified under the last is dropped.
        def advance(listed, read)
          @state = blank_state unless read.equal?(@read)
          beneath = Beneath.new(@root, read, @state.leaves, @stat)
          @state = restated(listed, read, beneath)
          @beneath_pruned = @whole_pruned ? beneath.pruned.filter_map { pruned_mask(_1) } : []
          @links = @state.identities.select { |_, identity| identity&.link }
          @read = read
        end

        def settle_pruned(pruned, moved)
          @current = nil if moved || pruned != @pruned
          @pruned = pruned
        end

        # A link is looked at again, since a chain can move without any directory this tree read.
        def reusable?(read)
          read.equal?(@read) && @state.stamps.all_settled?(@stat) &&
            @state.leaves.each_value.all? { settled?(_1) } &&
            @links.all? { |name, identity| Identity.of(File.join(@root, name)) == identity }
        end

        def settled?(leaf)
          leaf.stamps.all_settled?(@stat) && leaf.links.all? { |name, real| Identity.of(real) == leaf.found[name] }
        end

        def restated(listed, policy, beneath)
          parents = listed.to_h { [_1, File.dirname(_1)] }
          stamps = stamped(parents.values.uniq)
          identities = beneath.with(identified(parents, stamps))
          State.new(identities: identities.freeze, masks: remasked(policy, identities), stamps:,
                    leaves: beneath.leaves.freeze)
        end

        def remasked(policy, identities)
          changed = identities.keys.reject { @state.identities.key?(_1) && @state.identities[_1] == identities[_1] }
          @state.masks.slice(*identities.keys).except(*changed).merge(judged(policy, changed, identities)).freeze
        end

        def stamped(dirs) = Stamps.take(dirs.map { File.join(@root, _1) }, @stat)

        def identified(parents, stamps)
          settled = parents.values.uniq.select { @state.stamps.settled?(File.join(@root, _1), stamps) }.to_set
          parents.to_h { |name, dir| [name, (vouched(name) if settled.include?(dir)) || identity(name)] }
        end

        def identity(name) = Identity.of(File.join(@root, name))

        # A link is re-resolved every ask, since a chain can be retargeted
        # outside the root without moving any directory this tree reads.
        def vouched(name)
          known = @state.identities[name]
          known unless known.nil? || known.link
        end

        def judged(policy, names, identities)
          return {} if names.empty?

          landings = Landings.new(names, identities, @root)
          policy.mask_paths(names, cwd: @root).each_with_object({}) do |mask, by_name|
            landings.of(mask.path).each { by_name[_1] = mask }
          end
        end

        def listing = Listing.of(@root, @shell_out) || (entries if @walks_unlisted)

        # {Beneath} walks each directory among them, as it walks a nested repo git lists as 1 leaf.
        def entries
          Dir.children(@root).reject { _1 == Beneath::GIT_DIR || PRUNED_WHOLE.include?(_1) }.sort.map(&:b)
        rescue SystemCallError
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

        def git(*) = Listing.git(@root, @shell_out, *)
      end
      private_constant :Tree
    end
  end
end
