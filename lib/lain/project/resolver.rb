# frozen_string_literal: true

require "pathname"
require "tomlrb"

module Lain
  class Project
    # Turns a working directory into a {Project} by walking its own ancestry.
    #
    # Six rungs, tried in order, each landing on an ancestor-or-self of cwd: an
    # explicit flag, a `root =` in `.lain/config.toml`, a `.lain/` marker
    # directory, a `.git` entry, a deliberately empty rung 5, and finally cwd
    # itself with `detected_by: :none`.
    #
    # **Rung 5 is reserved and stays empty.** Non-VCS markers (`package.json`,
    # `Cargo.toml`, `Gemfile`) are not planned: in a monorepo the nearest
    # `package.json` names a PACKAGE, not the project, so it would fight rung 4
    # and usually lose the case the monorepo user wanted.
    #
    # **The rungs are searched rung-major, not directory-major.** Each rung
    # scans the whole ancestry nearest-first before the next rung is tried, so
    # an explicit `.lain/` high in a tree outranks an inferred `.git` below it.
    # Directory-major would make depth beat evidence, which inverts the point
    # of having rungs at all.
    #
    # **The refusal set is a stop rule on the WALK, not a filter on one rung.**
    # It fires AFTER a rung has matched, which is what keeps it general: `$HOME`
    # with a `.git` directory in it resolves to cwd because the walk stops at
    # `$HOME`, not because the git detector was taught to skip home. That
    # ordering is also what lets {Report#refusal} name which rung was rejected.
    # Rung 1 is exempt -- an explicit `--root $HOME` is intent, not inference --
    # and so is rung 6, which never walks anywhere.
    #
    # **The walk is our own; it never shells to `git rev-parse --show-toplevel`,**
    # because git answers that question from `GIT_DIR`/`GIT_WORK_TREE` before it
    # looks at the disk, and a bare dotfiles repo in the ambient environment
    # would then make `$HOME` every session's root. {GIT_ENV_SCRUB} is what a
    # future card that DOES shell to git must merge into the child's env.
    #
    # `home:` is a required, injected collaborator and is never read from `ENV`
    # here: a sibling class silently disabled its entire denied table when
    # `HOME` was `/` or `""` (Docker's default for a uid with no `/etc/passwd`
    # entry), so an unusable home raises {UnusableHome} instead of degrading.
    # The claim is exact and covers `home:` only -- the DEFAULT `paths:` is a
    # `Paths.new` over the real `ENV`, whose XDG fallbacks are computed from the
    # ambient `HOME`, so a caller wanting the refusal set free of ambient
    # environment has to inject `paths:` as well as `home:`.
    class Resolver
      # The variables git reads to override its own root detection, mapped to
      # `nil` rather than merely listed: an absent key still leaks from the
      # parent, and an explicit nil VALUE is the one removal lever that works
      # in-band (`worker_env.rb:8-20`, and Ruby's own `spawn` env hash).
      GIT_ENV_SCRUB = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil,
                        "GIT_CEILING_DIRECTORIES" => nil }.freeze

      # The rungs the walk itself can produce, strongest evidence first. Rung 1
      # (`:flag`) is absent because it never walks and rung 6 (`:none`) because
      # it is the fallthrough; a spec pins this against {Project::DETECTED_BY}
      # so the two orderings cannot drift.
      WALKED_RUNGS = %i[config lain_dir git].freeze

      # `.git` is a DIRECTORY in a primary checkout and a one-line `gitdir:`
      # pointer FILE in a linked worktree, so this is only ever tested with
      # `exist?` -- the same call {CLI::IsolationBackend#repo_root} makes, so
      # the two walks agree about what a repository looks like even while this
      # one carries a ceiling the other has not been given yet.
      GIT_ENTRY = ".git"

      CONFIG_FILE = "config.toml"

      # `home:` was not a usable absolute directory. Loud rather than
      # degrading, per the class docstring.
      class UnusableHome < Error
        def initialize(home)
          super("home must be an absolute path other than \"/\", got #{home.inspect}")
        end
      end

      # `.lain/config.toml` declared a `root` this walk cannot use as one --
      # a shape failure, unlike a root that is merely refused or out of
      # ancestry, which falls through to the next rung instead.
      class UnusableConfiguredRoot < Error
        def initialize(path, value, why)
          super("#{path} declares root = #{value.inspect}, which #{why}")
        end
      end

      Refusal = Data.define(:directory, :reason, :rung) do
        include Inspectable

        # Interned rather than merely frozen: this string comes out of
        # `Pathname#to_s`, which hands back a fresh mutable String, and
        # `Ractor.shareable?` on the enclosing {Report} is the mechanical
        # statement that nothing here is mutable.
        def initialize(directory:, reason:, rung:)
          super(directory: -directory, reason:, rung:)
        end

        def to_s = "#{directory} refused (#{reason}); rung #{rung} rejected"
      end

      # Where the walk stopped, why, and which rung that directory would have
      # produced had it been allowed to.
      class Refusal
        REASONS = %i[home filesystem_root temp system xdg mount_boundary unreadable].freeze
      end

      # One resolution: the {Project}, and the refusal that bounded the walk
      # that produced it. The refusal is always present -- `/` is always in the
      # set, so every ascent ends at a refused directory -- and is informative
      # even when it did not change the answer.
      Report = Data.define(:project, :refusal) do
        include Inspectable

        def to_s = "#{project} (#{refusal})"
      end

      # Both spellings of a path: the lexical expansion and the kernel
      # resolution. Refusals are compared against a realpath-resolved ancestry,
      # so a symlinked `$HOME` or `/tmp` has to be recognizable under either
      # name; a path that does not resolve contributes only its lexical form.
      #
      # @param path [String] an absolute path
      # @param filesystem [#realpath]
      # @return [Array<String>]
      def self.spellings(path, filesystem)
        expanded = File.expand_path(path)
        [expanded, resolved(expanded, filesystem)].uniq
      end

      # @param path [String] an already-expanded absolute path
      # @param filesystem [#realpath]
      # @return [String] the resolved path, or the given one when it does not resolve
      def self.resolved(path, filesystem)
        filesystem.realpath(path)
      rescue SystemCallError
        path
      end

      # The ONE spelling of a project's config file. {Declarations} scans for it
      # and {Resolver#marker_rung} names it at the boundary; spelled twice, the
      # two could disagree about where rung 2's evidence lives.
      #
      # @param dir [String]
      # @return [String]
      def self.config_path(dir) = File.join(dir, ProjectDir.join(CONFIG_FILE))

      # The one place `$HOME` is validated, so no other object has to guess
      # what an unusable one means.
      class Home
        # @param path [String] an absolute directory
        # @param filesystem [#realpath]
        # @raise [UnusableHome] when the value is not an absolute path, or is `/`
        def initialize(path, filesystem)
          raise UnusableHome, path unless path.is_a?(String) && path.start_with?(File::SEPARATOR)

          @spellings = Resolver.spellings(path, filesystem)
          raise UnusableHome, path if @spellings.include?(File::SEPARATOR)
        end

        attr_reader :spellings

        def covers?(dir) = @spellings.include?(dir)
      end

      # The stop rule the walk obeys, as a lookup: a table of exact directory
      # paths built once per resolution, plus the device of cwd.
      #
      # Exact paths, never prefixes -- `/tmp` is refused but `/tmp-other` is an
      # ordinary directory, and a project living at `$XDG_CONFIG_HOME/nvim` is
      # perfectly legitimate even though its parent is refused. Refusing a
      # directory stops the walk THERE; it does not ban the subtree below it.
      class Refusals
        # `/` first because a `$HOME` of `/` is already refused at
        # construction, and the two later tables may legitimately overlap.
        LITERALS = { File::SEPARATOR => :filesystem_root, "/tmp" => :temp, "/var/tmp" => :temp,
                     "/etc" => :system, "/usr" => :system }.freeze

        # @param cwd [String] a resolved absolute directory; supplies the device
        #   every ancestor is compared against
        # @param home [Home]
        # @param paths [Paths] supplies the three XDG bases
        # @param filesystem [#realpath, #stat]
        def initialize(cwd:, home:, paths:, filesystem:)
          @filesystem = filesystem
          @table = build(home, paths)
          @device = device_of(cwd)
          @memo = {}
        end

        # @param dir [String]
        # @return [Symbol, nil] why the walk must stop here, or nil
        def reason_for(dir) = @memo.fetch(dir) { @memo[dir] = compute(dir) }

        def refuse?(dir) = !reason_for(dir).nil?

        private

        # Home LAST so it wins any overlap: it is the entry a user can move,
        # and naming the reason `:home` is more useful than naming `:xdg`.
        def build(home, paths)
          (literal_entries + xdg_entries(paths) + home.spellings.product([:home])).to_h
        end

        def literal_entries = LITERALS.flat_map { |path, reason| spellings(path).product([reason]) }

        # `File.dirname` of each accessor because {Paths} suffixes every one
        # with `/lain` -- the BASE is the parent, and both are refused.
        def xdg_entries(paths)
          [paths.config_home, paths.cache_home, paths.state_home]
            .flat_map { |dir| [dir, File.dirname(dir)] }
            .flat_map { |dir| spellings(dir) }
            .product([:xdg])
        end

        def spellings(path) = Resolver.spellings(path, @filesystem)

        # A directory that cannot be stat'd is refused rather than walked
        # through: fail closed, because the alternative is treating an
        # unreadable ancestor as ordinary and continuing past it.
        def compute(dir)
          return @table[dir] if @table.key?(dir)

          device = device_of(dir)
          return :unreadable if device.nil?

          device == @device ? nil : :mount_boundary
        end

        def device_of(dir)
          @filesystem.stat(dir).dev
        rescue SystemCallError
          nil
        end
      end

      # The ancestry the rungs search: cwd and its ancestors, nearest first, cut
      # at the first refused directory. That directory is the {#boundary} and is
      # NOT a candidate; nothing above it is reachable either, which is what
      # makes the refusal a stop rule rather than a skip.
      class Walk
        include Enumerable

        # @param cwd [String] a resolved absolute directory
        # @param refusals [Refusals]
        def initialize(cwd:, refusals:)
          # `Pathname#ascend` is lexical, as {CLI::IsolationBackend#repo_root}'s
          # is -- but the two walks do NOT agree on the ancestry they ascend.
          # `repo_root` starts from `File.expand_path(root)`; this one starts
          # from a `realpath`. For a symlink whose LEXICAL parent holds a `.git`
          # its real parent does not, `repo_root` finds that repo and this
          # resolver does not. That is a second divergence beyond the ceiling,
          # and T5 owns reconciling both.
          ascent = Pathname.new(cwd).ascend.map(&:to_s)
          @candidates = ascent.take_while { |dir| !refusals.refuse?(dir) }
          # Never nil: `/` terminates every absolute ascent and is always in
          # {Refusals::LITERALS}, so the take_while always stops short.
          @boundary = ascent.fetch(@candidates.length)
          @reason = refusals.reason_for(@boundary)
        end

        attr_reader :boundary, :reason

        def each(&block) = @candidates.each(&block)
      end

      # Rung 2's scan of the walk: the nearest `root =` the walk can reach.
      #
      # **LAZY, and that is a correctness property, not an optimisation.**
      # `first match wins` has to mean the scan STOPS -- an eager scan opens
      # every `.lain/config.toml` in the ancestry after the nearest one has
      # already answered, so one stale or hostile file high in a tree makes
      # `lain` refuse to start in every project beneath it. The files this
      # class opens are exactly the untrusted input {#declared} worries about,
      # so the fewer of them the walk touches, the better.
      #
      # Only the files ABOVE an answer go unopened. A broken config the walk
      # reaches BEFORE any answer still raises, and deliberately: rung 2 scans
      # the whole reachable ancestry before rung 3 is tried, so a config a user
      # can see and the parser cannot read is a real error, not something to
      # swallow.
      class Declarations
        def initialize(walk:, filesystem:)
          @walk = walk
          @filesystem = filesystem
          @declined = []
        end

        # Asked at most once per resolution -- {Resolver#walked} is lazy over
        # {WALKED_RUNGS}, so rung 2 answers once and is never revisited -- which
        # is why there is deliberately no memo here. One would defend nothing,
        # and no spec could tell a live memo from a dead one.
        #
        # @return [String, nil] the nearest declared root the walk can reach
        # @raise [UnusableConfiguredRoot] on a declaration of the wrong shape
        # @raise [Config::Malformed] on a config.toml that will not parse
        def root = @walk.lazy.filter_map { |dir| declared_in(dir) }.first

        # Whether a declaration this scan REACHED named this directory and was
        # turned down for it -- which is how {Report#refusal} can say that a
        # rung-2 declaration, not merely a bare marker, is what the stop rule
        # rejected. Empty until {#root} has run: an explicit `--root` never
        # scans, and nothing was declined because nothing was read.
        #
        # @param directory [String]
        # @return [Boolean]
        def declined?(directory) = @declined.include?(directory)

        private

        def declared_in(dir)
          path = Resolver.config_path(dir)
          return nil unless @filesystem.exist?(path)

          declared = declared_root(path)
          declared && reachable(path, declared, dir)
        end

        def declared_root(path)
          Tomlrb.load_file(path)["root"]
        rescue Tomlrb::ParseError, ArgumentError, SystemCallError => e
          raise Config::Malformed.new(path, e)
        end

        # A `~` is refused LEXICALLY and never handed to `File.expand_path`,
        # which would resolve it through getpwnam -- on an SSSD or LDAP-backed
        # host that is a network call, made here on behalf of a file a cloned
        # repository may well have written (`approval/risk.rb:212-220` refuses
        # it for the same reason).
        #
        # Out-of-ancestry is NOT a shape failure: the refusal set makes rungs
        # fall through rather than raise, and a declared root the walk cannot
        # reach -- because it is outside cwd's ancestry, or because the stop
        # rule cut the walk below it -- is the same situation. It is recorded
        # rather than discarded so the report can still name it.
        def reachable(path, declared, dir)
          raise UnusableConfiguredRoot.new(path, declared, "is not a string") unless declared.is_a?(String)
          raise UnusableConfiguredRoot.new(path, declared, "is empty") if declared.empty?
          raise UnusableConfiguredRoot.new(path, declared, "is home-relative") if declared.start_with?("~")

          target = File.expand_path(declared, dir)
          return target if @walk.include?(target)

          @declined << target
          nil
        end
      end

      # @param home [String] the user's home directory; required and injected,
      #   never read from `ENV` here
      # @param paths [Paths] supplies the three XDG bases the refusal set names
      # @param filesystem [#exist?, #directory?, #realpath, #stat] injected so a
      #   spec can pin a mount boundary over an otherwise real tree
      # @raise [UnusableHome]
      def initialize(home:, paths: Paths.new, filesystem: File)
        @home = Home.new(home, filesystem)
        @paths = paths
        @filesystem = filesystem
      end

      # @param cwd [String] the working directory to resolve from
      # @param root [String, nil] an explicit root (rung 1), exempt from the refusal set
      # @return [Report]
      # @raise [Project::Unresolvable] when cwd or an explicit root names no readable path
      # @raise [UnusableConfiguredRoot] when a `.lain/config.toml` declares an unusable root
      # @raise [Config::Malformed] when a `.lain/config.toml` on the walk will not parse
      def call(cwd: Dir.pwd, root: nil)
        here = resolve!(:cwd, cwd)
        walk = Walk.new(cwd: here, refusals: Refusals.new(cwd: here, home: @home, paths: @paths,
                                                          filesystem: @filesystem))
        declarations = Declarations.new(walk:, filesystem: @filesystem)
        # Ordered, not incidental: {Declarations#declined?} can only answer for
        # what the scan actually read, so detection has to run before the report.
        rung, found = detect(root, walk, declarations, here)
        Report.new(project: Project.new(root: found, cwd: here, kind: kind_for(found), detected_by: rung),
                   refusal: refusal_for(walk, declarations))
      end

      private

      def detect(root, walk, declarations, cwd)
        return [:flag, resolve!(:root, root)] if root

        walked(walk, declarations) || [:none, cwd]
      end

      def walked(walk, declarations)
        WALKED_RUNGS.lazy
                    .filter_map { |rung| root_at(rung, walk, declarations)&.then { |dir| [rung, dir] } }
                    .first
      end

      def root_at(rung, walk, declarations)
        case rung
        when :config then declarations.root
        when :lain_dir then walk.find { |dir| @filesystem.directory?(marker(dir, ProjectDir::DIR)) }
        when :git then walk.find { |dir| @filesystem.exist?(marker(dir, GIT_ENTRY)) }
        end
      end

      def marker(dir, *names) = File.join(dir, *names)

      # A declined rung-2 declaration outranks the boundary's bare markers: when
      # a user wrote an explicit `root =` and the stop rule turned it down, the
      # report saying `rung none` would be a lie about what happened.
      def refusal_for(walk, declarations)
        rung = declarations.declined?(walk.boundary) ? :config : marker_rung(walk.boundary)
        Refusal.new(directory: walk.boundary, reason: walk.reason, rung:)
      end

      # MARKERS only, never file CONTENT: the boundary is a directory this walk
      # has already refused, so naming what sat there must not mean parsing a
      # config it declined to trust -- nor raising on one that will not parse.
      def marker_rung(dir)
        return :config if @filesystem.exist?(Resolver.config_path(dir))
        return :lain_dir if @filesystem.directory?(marker(dir, ProjectDir::DIR))
        return :git if @filesystem.exist?(marker(dir, GIT_ENTRY))

        :none
      end

      def kind_for(root) = @home.covers?(root) ? :home : :project

      # {Project} renames its own `SystemCallError`s to {Project::Unresolvable}
      # so `exe/lain`'s `rescue Lain::Error` still catches them; resolving here
      # first must not undo that, so it raises the same named refusal with the
      # same role.
      def resolve!(role, path)
        @filesystem.realpath(path)
      rescue SystemCallError => e
        raise Unresolvable.new(role, path, e)
      end
    end
  end
end
