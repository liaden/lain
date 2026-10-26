# frozen_string_literal: true

require "open3"
require "pathname"

module Lain
  module Confine
    Profile = Data.define(:name, :exec_dirs, :exec_files, :read_dirs, :write_dirs, :masks, :tmpfs_bytes, :trace,
                          :connect_ports, :unix_dirs, :sealed, :call_tmpdir)

    # What one call may do: run beneath `exec_dirs` and exactly `exec_files`,
    # read beneath `read_dirs`, write beneath `write_dirs`, and never see
    # `masks`. `trace` records every exec. `connect_ports` are the TCP ports it may
    # connect to and `unix_dirs` the directories whose Unix sockets it may
    # reach; the reader has neither. `:none` runs as before, `:traced`
    # only watches, `:reader` confines, and `:workspace` confines while
    # writing the project, which `sealed` keeps from planting what runs
    # later, and `:grant` is a workspace with one build tool's ports, from
    # {.grant}. A workspace's `call_tmpdir`, once {#for_call} names one, is the
    # dir made for a single call and removed after it. Both unconfined
    # profiles still run under lain-fence as a reaper, so a stopped call
    # leaves no descendant behind; that covers a call made through a sandbox,
    # and `--confine off` or a box lacking bwrap or Landlock builds none.
    #
    # A value: a {Launcher} turns it into argv. Every path is absolute and,
    # for a mask, already resolved, because bwrap aborts on a mask that is a
    # symlink. The project is the first read dir, which is how {Bwrap} finds
    # it to bind back over the private /tmp.
    class Profile
      # The call's /tmp is a tmpfs of its own, discarded when it exits, so it
      # is granted whole; tmpfs would otherwise take up to half of RAM.
      TMPFS_BYTES = 1024 * 1024 * 1024

      UNCONFINED = %i[none traced].freeze
      # The classes a reader profile may grant a program outside /usr: one the project could have put there is
      # the plant it exists to stop.
      GRANTED_CLASSES = %i[system user].freeze

      SYSTEM_EXEC = %w[/usr].freeze
      # bwrap's /proc belongs to the call's own pid namespace, so it shows
      # only the call's processes; /proc/self alone would cover only the fence.
      SYSTEM_READ = %w[/usr /etc /proc /dev/null /dev/urandom /tmp].freeze
      SYSTEM_WRITE = %w[/dev/null /tmp].freeze

      # rustup's proxies in .cargo/bin exec the real tools out of its
      # toolchains, so those run; the rest are read. git dies without its user
      # config, and a mise ruby reads its own install tree. A path that does
      # not exist grants nothing.
      HOME_EXEC = %w[.rustup/toolchains].freeze
      HOME_READ = %w[.rustup .cargo/bin .config/git .gitconfig .local/share/mise/installs].freeze

      # Relative to the root: files a later shell or hook runs. The lain dir a
      # later session reads is sealed too, at the path {ProjectDir} owns.
      PROJECT_SEALED = %w[.envrc .pre-commit-config.yaml].freeze

      # The TCP ports each build tool fetches on. Landlock bounds a port, never
      # a host, so a granted port is open to whatever code the build runs, and
      # {Profiles} grants one only while nothing the build could load is fresh.
      GRANTS = { "bundle" => [443, 80], "cargo" => [443], "git" => [443] }.freeze

      # nss-resolve's socket dir: a name resolves through it, so no grant needs a
      # datagram socket, which the fence refuses whatever the profile says.
      RESOLVER = "/run/systemd/resolve"

      # Relative to cargo's home: what it fetches into. The rest holds its bin
      # and its credentials.
      CARGO_WRITES = %w[registry git .package-cache].freeze

      # What a commit in a linked worktree writes in the main checkout's git dir. git rewrites packed-refs by
      # renaming a lock beside it in that dir, which is not granted, so whatever rewrites it fails here.
      COMMIT_WRITES = %w[objects refs logs].freeze

      # A workspace seal the call could replace, through a link it can repoint.
      class Unsealable < Error
        # @param path [String] the sealed path as written
        # @param link [String] the link inside the writes on its way
        def initialize(path:, link:)
          super("cannot seal #{path}: #{link} is a link inside the writable project")
        end
      end

      def initialize(name:, trace:, exec_dirs: [], exec_files: [], read_dirs: [], write_dirs: [], masks: [],
                     connect_ports: [], unix_dirs: [], sealed: [], tmpfs_bytes: TMPFS_BYTES, call_tmpdir: nil)
        grants = { exec_dirs:, exec_files:, read_dirs:, write_dirs:, masks:, unix_dirs: }
        relative = [*grants.values.flatten, *sealed.map(&:path)].reject { _1.start_with?(File::SEPARATOR) }
        # The fence and bwrap resolve a relative path against wherever they
        # happen to run, which is not a grant anyone wrote.
        raise ArgumentError, "a profile path must be absolute, got #{relative.first.inspect}" if relative.any?

        super(name:, trace:, tmpfs_bytes:, connect_ports: valid_ports(connect_ports).freeze, sealed: sealed.dup.freeze,
              call_tmpdir: call_tmpdir&.then(&:-@), **grants.transform_values { |paths| paths.map(&:-@).freeze })
      end

      def valid_ports(ports)
        bad = ports.find { !(_1.is_a?(Integer) && _1.between?(1, 65_535)) }
        raise ArgumentError, "a connect port must be an integer from 1 to 65535, got #{bad.inspect}" if bad

        ports.dup
      end
      private :valid_ports

      # @return [Boolean] whether the kernel bounds what the call may reach
      def confined? = Profile.confines?(name)

      # A TMPDIR other processes share holds their scratch too, so a call
      # writes a dir of its own beneath it instead. Only a profile that names
      # one has a dir its call may remove.
      #
      # @param dir [String] absolute; made for the call, beneath `granted`
      # @param granted [String] the TMPDIR this profile writes
      # @return [Profile] this one, writing `dir` where it wrote `granted`
      # @raise [ArgumentError] when `granted` is not written, is the private /tmp, or `dir` is not beneath it
      def for_call(dir, granted:)
        raise ArgumentError, "this profile writes no #{granted.inspect}" unless write_dirs.include?(granted)
        raise ArgumentError, "#{granted.inspect} is already private to the call" if SYSTEM_WRITE.include?(granted)
        unless dir != granted && Landing.under?(dir, granted)
          raise ArgumentError, "a call's TMPDIR must be beneath #{granted.inspect}, got #{dir.inspect}"
        end

        with(write_dirs: write_dirs.map { _1 == granted ? dir : _1 }, call_tmpdir: dir)
      end

      # @param name [Symbol, String] a profile's name, as a record journals it
      # @return [Boolean] whether a profile of that name bounds what the call may reach
      def self.confines?(name) = !UNCONFINED.include?(name.to_sym)

      # @param path [String] a resolved program
      # @return [Boolean] whether the fence lets the call exec it
      def runs?(path) = exec_files.include?(path) || exec_dirs.any? { path.start_with?("#{_1}/") }

      # @return [String, nil] the first mask that is or holds a grant, which masking would empty
      def overmask
        grants = [*exec_dirs, *exec_files, *read_dirs, *write_dirs]
        masks.find { |mask| grants.any? { Landing.under?(_1, mask) } }
      end

      NONE = new(name: :none, trace: false)
      TRACED = new(name: :traced, trace: true)

      # @param root [String] absolute; the project, read whole
      # @param home [String] absolute; where the toolchain grants are looked for
      # @param masks [Array<String>] resolved paths hidden from the call
      # @param exec_files [Array<String>] programs outside /usr the call may run
      # @param trace [Boolean] false where this kernel cannot trace
      # @return [Profile]
      def self.reader(root:, home:, masks: [], exec_files: [], trace: true)
        new(name: :reader, trace:, exec_files:, masks:, write_dirs: SYSTEM_WRITE,
            exec_dirs: [*SYSTEM_EXEC, *HOME_EXEC.map { File.join(home, _1) }],
            read_dirs: [landing(root), *linked_git_dir(root), *SYSTEM_READ, *HOME_READ.map { File.join(home, _1) }])
      end

      # The reader's reach, plus writes to the project and the caller's TMPDIR,
      # which Ruby and this repo need on the project's filesystem. So a call
      # cannot plant what runs later, each persistence path that exists is
      # bound read-only, each directory above one is bound over itself so it
      # cannot be renamed away, and a seal reached through a link inside the
      # writes is refused. An absent one is not enforced: it is listed for a
      # check after the call. Where git cannot answer, `.git` is sealed whole,
      # and with no `.git` the list is the lain dir and {PROJECT_SEALED}. A background
      # child ends with the call, in bwrap's pid namespace. What
      # fails: in a linked worktree, ref deletion, gc, pack-refs and worktree
      # add; in an ordinary checkout, any .git/config write (branch -D leaves
      # its section, branch -m exits 128 with the ref renamed), git inside a
      # submodule, and worktree add, prune and remove.
      #
      # @param root [String] absolute; the project, read and written whole
      # @param home [String] absolute; where the toolchain grants are looked for
      # @param tmpdir [String] absolute; the caller's TMPDIR, never home or above it
      # @param masks [Array<String>] resolved paths hidden from the call
      # @param exec_files [Array<String>] programs outside /usr the call may run
      # @param trace [Boolean] false where this kernel cannot trace
      # @return [Profile]
      # @raise [Unsealable] when a seal is reached through a link inside the writes
      def self.workspace(root:, home:, tmpdir:, masks: [], exec_files: [], trace: true)
        refuse_workspace(root, home, tmpdir)
        reader = reader(root:, home:, masks:, exec_files:, trace:)
        project = reader.read_dirs.first
        git = Seal.git_dirs(project)
        writes = [project, tmpdir, *commit_writes(project, git)]
        new(**reader.to_h, name: :workspace, sealed: Seal.of(project, git, writable: writes),
                           write_dirs: [*writes, *SYSTEM_WRITE])
      end

      # The workspace profile with a build tool's ports, the resolver's socket
      # dir, and what the tool writes outside the project: bundle its gem home
      # and its user cache, cargo its fetched sources, with exec on `target/`
      # for its build scripts. Every seal the workspace holds is kept. Where a
      # write cannot be bounded, the workspace profile comes back unchanged,
      # with no ports.
      #
      # A granted bundle install writes the gem home, which holds the gems lain
      # itself loads, so the install can change code lain runs later. That was
      # accepted. The dir RubyGems installs executables to is never granted:
      # where it sits inside the gem home it is sealed, and where it would sit
      # there but is absent, bundle gets no grant, since an absent seal is only
      # checked after the call.
      #
      # @param program [String] a key of {GRANTS}
      # @param root [String] absolute; the project, read and written whole
      # @param home [String] absolute; where the toolchain grants are looked for
      # @param tmpdir [String] absolute; the caller's TMPDIR, never home or above it
      # @param masks [Array<String>] resolved paths hidden from the call
      # @param exec_files [Array<String>] programs outside /usr the call may run
      # @param trace [Boolean] false where this kernel cannot trace
      # @param env [#[]] where bundler's GEM_HOME and BUNDLE_USER_* are read from
      # @return [Profile] named :grant, or the workspace profile when a write cannot be bounded
      # @raise [ArgumentError] for a program with no grant
      # @raise [Unsealable] when a seal is reached through a link inside the writes
      def self.grant(program:, root:, home:, tmpdir:, masks: [], exec_files: [], trace: true, env: ENV)
        workspace(root:, home:, tmpdir:, masks:, exec_files:, trace:).granting(program, home:, env:)
      end

      # @param program [String] a key of {GRANTS}
      # @param home [String] absolute
      # @param env [#[]]
      # @return [Profile] this workspace profile granted `program`'s ports, named :grant; itself when a
      #   write cannot be bounded
      # @raise [ArgumentError] for a program with no grant
      def granting(program, home:, env: ENV)
        ports = GRANTS.fetch(program) { raise ArgumentError, "no build tool is granted as #{program.inspect}" }
        tool = BuildTool.of(program, project: read_dirs.first, home:, env:)
        return self unless tool

        with(name: :grant, connect_ports: ports, unix_dirs: [RESOLVER], read_dirs: [*read_dirs, RESOLVER],
             write_dirs: [*write_dirs, *tool.writes], exec_dirs: [*exec_dirs, *tool.execs],
             sealed: [*sealed, *tool.seals])
      end

      # git's answer is read a line per path, and a TMPDIR at or above home grants home.
      def self.refuse_workspace(root, home, tmpdir)
        raise ArgumentError, "a workspace root must not contain a newline, got #{root.inspect}" if root.include?("\n")
        return unless tmpdir.start_with?(File::SEPARATOR) && Landing.under?(landing(home), landing(tmpdir))

        raise ArgumentError, "a workspace TMPDIR must not be home or hold it, got #{tmpdir.inspect}"
      end
      private_class_method :refuse_workspace

      # @param root [String]
      # @param git [Array<String>] common dir and git dir, or none
      # @return [Array<String>] what a commit writes in a git dir outside the project
      def self.commit_writes(root, git)
        common, gitdir = git
        return [] if common.nil? || Landing.under?(common, root)

        [*COMMIT_WRITES.map { File.join(common, _1) }, *(gitdir == common ? [File.join(common, "index")] : []), gitdir]
      end
      private_class_method :commit_writes

      # bwrap binds a project back over the private /tmp where it lands, so a
      # root reached through a link must be named by its landing, and so must
      # anything keyed on a root.
      #
      # @param root [String]
      # @return [String] the resolved root, or `root` as written when it cannot be resolved
      def self.landing(root)
        root.start_with?(File::SEPARATOR) ? File.realpath(root) : root
      rescue SystemCallError
        root
      end

      # A linked worktree's or a submodule's `.git` is a file naming a git dir
      # outside the project, and git cannot run without reading it. A worktree's
      # names the main checkout's git dir in turn, through `commondir`.
      #
      # @param root [String]
      # @return [Array<String>] the git dir outside the project, or none
      def self.linked_git_dir(root)
        pointer = File.read(File.join(root, ".git"))[/\Agitdir: (.+)$/, 1]
        return [] unless pointer

        admin = File.expand_path(pointer, root)
        common = File.join(admin, "commondir")
        [File.exist?(common) ? File.expand_path(File.read(common).strip, admin) : admin]
      rescue SystemCallError
        []
      end
      private_class_method :linked_git_dir

      BuildTool = Data.define(:writes, :execs, :seals)

      # What one build tool needs beyond the workspace, or nil where a write
      # cannot be bounded. GEM_HOME and CARGO_HOME are read from the host env,
      # names {Exec::ChildEnv} keeps; a GEM_HOME the worker env lends to one
      # call is not seen here, so that call's install is denied its writes and
      # fails closed. No BUNDLE_USER_ name reaches the child, so bundler's cache
      # is the one beneath ~/.bundle.
      class BuildTool
        # @param program [String]
        # @param project [String]
        # @param home [String]
        # @param env [#[]]
        # @return [BuildTool, nil]
        def self.of(program, project:, home:, env:)
          case program
          when "bundle" then bundle(project, home, env)
          when "cargo" then cargo(project, home, env)
          else new(writes: [], execs: [], seals: [])
          end
        end

        # With no GEM_HOME, a child's bundler installs to RubyGems' default dir,
        # which is this ruby's: a bundle on another ruby is not granted its own,
        # so its install fails rather than writing somewhere unbounded. A gem
        # home must look like one, with a specifications dir.
        def self.bundle(project, home, env)
          gem_home = named(env, "GEM_HOME") || Gem.default_dir
          writes = [gem_home, File.join(home, ".bundle", "cache")]
          return unless writes.all? { bounded?(_1, home) } && File.directory?(File.join(gem_home, "specifications")) &&
                        holds_nothing?(gem_home, project, home)

          seals = installs_in(Gem.bindir(gem_home), writes)
          seals && new(writes:, execs: [], seals:)
        end

        # cargo's own bin is where its home is meant to hold a reader's grant.
        def self.cargo(project, home, env)
          cargo_home = named(env, "CARGO_HOME") || File.join(home, ".cargo")
          execs = built_in(project)
          return unless execs && bounded?(cargo_home, home) &&
                        holds_nothing?(cargo_home, project, home, own: File.join(cargo_home, "bin"))

          new(writes: CARGO_WRITES.map { File.join(cargo_home, _1) }, execs:, seals: [])
        end

        def self.named(env, key) = env[key].to_s.empty? ? nil : env[key]

        # TMPDIR's rule: never /, home or a dir above it, and only where it says
        # it is, so a link on the way grants nothing. An absent dir is read
        # through its longest existing prefix.
        def self.bounded?(path, home)
          landed = Landing.eventual(path, cwd: File::SEPARATOR).first
          landed == File.expand_path(path) && !Landing.under?(Profile.landing(home), landed)
        rescue Landing::Dangling, SystemCallError
          false
        end

        # A write over the project or a home dir the reader grants would let the call rewrite what it reads as trusted.
        def self.holds_nothing?(dir, project, home, own: nil)
          read = HOME_READ.map { File.join(home, _1) }.reject { own && Landing.under?(_1, own) }
          [project, *read].none? { Landing.under?(_1, dir) }
        end

        # cargo runs its build scripts out of `target/`, so only a real directory
        # is granted exec; one not made yet grants none, and a link or a file
        # grants cargo nothing.
        def self.built_in(project)
          target = File.join(project, "target")
          File.lstat(target).directory? ? [target] : nil
        rescue Errno::ENOENT
          []
        rescue SystemCallError
          nil
        end

        # @return [Array<Seal>, nil] nil when the dir would sit in a write and is absent
        def self.installs_in(bindir, writes)
          return [] unless writes.any? { Landing.under?(bindir, _1) }
          return unless File.directory?(bindir)

          [Seal.new(path: -Profile.landing(bindir), absent: false)]
        end
        private_class_method :bundle, :cargo, :named, :bounded?, :holds_nothing?, :built_in, :installs_in
      end

      Seal = Data.define(:path, :absent, :hops)

      # A persistence path a workspace call must not change. An absent one is
      # not enforced; it is listed for a check after the call. A dangling link
      # cannot be mounted, so it is sealed where it lands, absent there.
      # `hops` names each link on the way, so a repointed one is noticed.
      class Seal
        LINK_HOPS = 40

        # @param path [String] where the seal lands
        # @param absent [Boolean]
        # @param hops [Array<String>] the links followed to reach `path`
        def initialize(path:, absent:, hops: [])
          super(path:, absent:, hops: hops.map(&:-@).freeze)
        end

        # The hooks dir is asked first, before the absolute format, which would resolve a link on its way.
        GIT_ASKS = %w[rev-parse --git-path hooks --path-format=absolute --git-common-dir --absolute-git-dir].freeze

        # @param root [String] absolute
        # @param git [Array<String>] {.git_dirs} of `root`
        # @param writable [Array<String>] what the call may write, where a link on a seal's way is refused
        # @return [Array<Seal>] the hooks, the git configs, what redirects git, the lain dir and
        #   {Profile::PROJECT_SEALED}
        # @raise [Unsealable]
        def self.of(root, git = git_dirs(root), writable: [root])
          named = [*in_git(root, *git), ProjectDir.new(root:).dir,
                   *Profile::PROJECT_SEALED.map { File.join(root, _1) }]
          named.each { refuse_link(_1, writable) }
          named.map { at(_1) }.group_by(&:path).map do |path, seals|
            new(path:, absent: seals.first.absent, hops: seals.flat_map(&:hops).uniq)
          end
        end

        def self.in_git(root, common = nil, gitdir = nil, hooks = nil)
          dot_git = File.join(root, ".git")
          return File.exist?(dot_git) || File.symlink?(dot_git) ? [dot_git] : [] unless common

          [File.join(common, "hooks"), File.join(common, "config"), File.join(gitdir, "config.worktree"), hooks,
           File.join(gitdir, "commondir"), *pointer(dot_git), File.join(common, "modules"),
           *worktrees(common, gitdir)]
        end

        # The main checkout seals every worktree's admin dir whole, as one mount however many there are; a
        # linked one writes its own, so there only the pointers back are sealed.
        def self.worktrees(common, gitdir)
          return [File.join(common, "worktrees")] if gitdir == common

          Dir.glob(%w[commondir gitdir].map { File.join(common, "worktrees", "*", _1) })
        end

        # A `.git` file redirects git, and a `.git` link is refused on the way to the seals under it.
        def self.pointer(dot_git) = File.file?(dot_git) || File.symlink?(dot_git) ? [dot_git] : []

        def self.refuse_link(path, writable)
          link = Pathname(path).descend.map(&:to_s).find do |step|
            File.symlink?(step) && writable.any? { step != _1 && Landing.under?(step, _1) }
          end
          raise Unsealable.new(path:, link:) if link
        end

        def self.at(path, left = LINK_HOPS, followed = [])
          hops = File.symlink?(path) ? [*followed, path] : followed
          return new(path: -File.realpath(path), absent: false, hops:) if File.exist?(path)
          return new(path: -path, absent: true, hops: followed) unless File.symlink?(path) && left.positive?

          at(File.expand_path(File.readlink(path), Profile.landing(File.dirname(path))), left - 1, hops)
        end
        private_class_method :in_git, :worktrees, :pointer, :refuse_link, :at

        # git answers core.hooksPath and a worktree's pointer itself, includes
        # and all, so this asks it once rather than parsing its config.
        #
        # @param root [String]
        # @return [Array<String>] common dir, git dir and hooks dir; none where git cannot answer
        def self.git_dirs(root)
          out, status = Open3.capture2(Isolation::Worktree::GIT_CONTEXT_SCRUB, "git", "-C", root, *GIT_ASKS,
                                       err: File::NULL)
          hooks, *dirs = out.lines(chomp: true)
          status.success? && dirs.size == 2 ? [*dirs, File.expand_path(hooks, root)] : []
        rescue SystemCallError
          []
        end
      end
    end
  end
end
