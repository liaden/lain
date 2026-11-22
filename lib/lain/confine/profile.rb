# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"

module Lain
  module Confine
    Profile = Data.define(:name, :exec_dirs, :exec_files, :read_dirs, :write_dirs, :masks, :tmpfs_bytes, :trace,
                          :connect_ports, :unix_dirs, :sealed, :call_tmpdir, :homes, :hidden, :private_net, :unmasked)

    # What one call may do: run beneath `exec_dirs` and exactly `exec_files`,
    # read beneath `read_dirs`, write beneath `write_dirs`, and never see
    # `masks`. `trace` records every exec. `connect_ports` are the TCP ports it may
    # connect to and `unix_dirs` the directories whose Unix sockets it may
    # reach; the reader has neither. `:none` runs as before, `:traced`
    # only watches, `:reader` confines, and `:workspace` confines while
    # writing the project, which `sealed` keeps from planting what runs
    # later, and `:grant` is a workspace with one build tool's ports, from
    # {.grant}. A workspace's `call_tmpdir`, once {#for_call} names one, is the
    # dir made for a single call and removed after it. `homes` are the
    # {PrivateHome}s mounted over a home dir, `hidden` the toolchain files a
    # workspace shows empty and never runs, and `private_net` says each stage
    # of the call has a network namespace of its own, holding only loopback,
    # so the stages of one pipeline cannot reach each other over it. `unmasked` says a human let the call
    # read the project's secrets, so what it wrote is scanned for them after. Both unconfined
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
      INSTALLS = ".local/share/mise/installs"
      HOME_READ = [".rustup", ".cargo/bin", ".config/git", ".gitconfig", INSTALLS].freeze

      # A shim is a link to mise, which reads the project's config and goes online, so a workspace never runs it.
      MISE_SHIMS = ".local/share/mise/shims"
      MISE = %w[/usr/bin/mise /usr/local/bin/mise].freeze
      HOME_MISE = ".local/bin/mise"
      # It can hold gem server credentials; shown empty, bundler reads no config at all.
      BUNDLE_CONFIG = ".bundle/config"

      # `require "resolv"` opens it at load time. Its landing is read, never the dir that also holds the upstream
      # servers and the resolver's sockets.
      RESOLV_CONF = "/etc/resolv.conf"
      # A test suite that asks whether Landlock is active reads this, and skips itself in silence when it cannot.
      LSM_LIST = "/sys/kernel/security/lsm"

      # Relative to the root: files a later shell, hook or toolchain run reads
      # and acts on. The lain dir a later session reads is sealed too, at the
      # path `ProjectDir` owns.
      PROJECT_SEALED = %w[.envrc .pre-commit-config.yaml rust-toolchain.toml rust-toolchain .cargo/config.toml
                          .cargo/config .tool-versions mise.toml .mise.toml mise.local.toml .mise.local.toml
                          .mise/config.toml .config/mise.toml .config/mise/config.toml mise/config.toml].freeze

      # The TCP ports each build tool fetches on. Landlock bounds a port, never
      # a host, so a granted port is open to whatever code the build runs, and
      # `Profiles` grants one only while nothing the build could load is fresh.
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
        attr_reader :path, :link, :root

        # @param path [String] the sealed path as written
        # @param link [String] the link inside the writes on its way
        # @param root [String, nil] the project being sealed
        def initialize(path:, link:, root: nil)
          @path = path
          @link = link
          @root = root
          super("cannot seal #{path}: #{link} is a link inside the writable project")
        end

        # @return [Symbol] the profile the call would have run under
        def profile = :workspace
      end

      # A clone lain cut whose git dir holds a name that redirects git, which a call may have planted.
      class Tampered < Error
        # @return [String] the clone
        attr_reader :path

        # @return [Symbol] the profile the call would have run under
        attr_reader :profile

        # @param path [String] the clone
        # @param why [String] what was found there
        # @param profile [Symbol] the profile the call would have run under
        def initialize(path:, why:, profile:)
          @path = path
          @profile = profile
          super("#{path}: #{why}")
        end
      end

      # A root that holds lain's state home would let a call write the lease records lain trusts.
      class HoldsState < Error
        attr_reader :path

        # @param path [String] the root
        # @param state [String] lain's state home beneath it
        def initialize(path:, state:)
          @path = path
          super("a workspace root must not hold lain's state home #{state}, whose lease records lain trusts, " \
                "got #{path.inspect}")
        end

        # @return [Symbol] the profile the call would have run under
        def profile = :workspace
      end

      # A TMPDIR at or above home would make home writable.
      class HomeTmpdir < Error
        attr_reader :path

        # @param path [String] the TMPDIR
        def initialize(path:)
          @path = path
          super("a workspace TMPDIR must not be home or hold it, got #{path.inspect}")
        end

        # @return [Symbol] the profile the call would have run under
        def profile = :workspace
      end

      def initialize(name:, trace:, exec_dirs: [], exec_files: [], read_dirs: [], write_dirs: [], masks: [],
                     connect_ports: [], unix_dirs: [], sealed: [], tmpfs_bytes: TMPFS_BYTES, call_tmpdir: nil,
                     homes: [], hidden: [], private_net: false, unmasked: false)
        grants = { exec_dirs:, exec_files:, read_dirs:, write_dirs:, masks:, unix_dirs:, hidden: }
        absolute([*grants.values.flatten, *sealed.map(&:path), *homes.map(&:path)])
        raise ArgumentError, "a private network has no host port to connect to" if private_net && connect_ports.any?

        super(name:, trace:, tmpfs_bytes:, connect_ports: valid_ports(connect_ports).freeze, sealed: sealed.dup.freeze,
              call_tmpdir: call_tmpdir&.then(&:-@), homes: homes.dup.freeze, private_net: private_net == true,
              unmasked: unmasked == true,
              **grants.transform_values { |paths| paths.map(&:-@).freeze })
      end

      # The fence and bwrap resolve a relative path against wherever they
      # happen to run, which is not a grant anyone wrote.
      def absolute(paths)
        relative = paths.reject { _1.start_with?(File::SEPARATOR) }
        raise ArgumentError, "a profile path must be absolute, got #{relative.first.inspect}" if relative.any?
      end
      private :absolute

      def valid_ports(ports)
        bad = ports.find { !(_1.is_a?(Integer) && _1.between?(1, 65_535)) }
        raise ArgumentError, "a connect port must be an integer from 1 to 65535, got #{bad.inspect}" if bad

        ports.dup
      end
      private :valid_ports

      def network_phrase(network)
        return "with network" if network == true

        network ? "network only on ports #{network.join(", ")}" : "no network"
      end
      private :network_phrase

      def home_phrase
        mounted = homes.map { "private ~/#{File.basename(_1.path)}" }
        ["home masked", *mounted].join(", ")
      end
      private :home_phrase

      # @return [Boolean] whether the kernel bounds what the call may reach
      def confined? = Profile.confines?(name)

      # @return [Boolean] whether the call could read the project's secret files
      def unmasked? = unmasked

      # @param net_enforced [Boolean] whether the kernel bounds TCP ports at all; below Landlock ABI 4 a confined
      #   profile with no private network still reaches the host's
      # @return [Boolean, Array<String>] true when the call could reach the network, the granted ports when only
      #   they could be, false when none
      def network(net_enforced: true)
        return true unless confined? && (net_enforced || private_net)

        connect_ports.map(&:to_s).presence || false
      end

      # @param net_enforced [Boolean] as for {#network}
      # @return [String] the line a bash result ends with, so the model reads what its run lacked
      def tier_line(net_enforced: true)
        return "[ran: unconfined, with network]" unless confined?

        "[ran: #{name}; #{network_phrase(network(net_enforced:))}; no /dev/dri; #{home_phrase}]"
      end

      # A TMPDIR other processes share holds their scratch too, so a call
      # writes a dir of its own beneath it instead, and may run what it writes
      # there, as a test suite runs the scripts it makes. Only a profile that
      # names one has a dir its call may remove.
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

        with(write_dirs: write_dirs.map { _1 == granted ? dir : _1 }, exec_dirs: [*exec_dirs, dir], call_tmpdir: dir)
      end

      # @param name [Symbol, String] a profile's name, as a record journals it
      # @return [Boolean] whether a profile of that name bounds what the call may reach
      def self.confines?(name) = !UNCONFINED.include?(name.to_sym)

      # @param path [String] a resolved program
      # @return [Boolean] whether the fence lets the call exec it, and nothing hides it
      def runs?(path)
        return false if hidden.any? { Landing.under?(path, _1) }

        exec_files.include?(path) || exec_dirs.any? { path.start_with?("#{_1}/") }
      end

      # A mise install's own bin holds the interpreter its scripts name by
      # `env`, by their binstub's own dir, or through `bundle exec`, and the
      # install is read already, so running it reaches nothing new.
      #
      # @param realpath [String] a resolved program
      # @param home [String] absolute
      # @return [String, nil] the bin dir of the one install `realpath` sits directly in
      def self.install_bin(realpath, home:)
        installs = File.join(landing(home), INSTALLS)
        return unless realpath.start_with?("#{installs}/")

        tool, version, bin, name, *rest = realpath.delete_prefix("#{installs}/").split(File::SEPARATOR)
        File.join(installs, tool, version, bin) if bin == "bin" && name && rest.empty?
      end

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
      # @param related [Array<String>] absolute; directories outside the project read whole, their masks among `masks`
      # @return [Profile]
      # @raise [Tampered] when the root is a clone lain cut whose git dir was tampered with
      def self.reader(root:, home:, masks: [], exec_files: [], trace: true, related: [])
        refuse_tampered(landing(root), :reader)
        new(name: :reader, trace:, exec_files:, masks:, write_dirs: SYSTEM_WRITE,
            exec_dirs: [*SYSTEM_EXEC, *HOME_EXEC.map { File.join(home, _1) }],
            read_dirs: [landing(root), *git_reads(root), *related.map { landing(_1) }, *SYSTEM_READ,
                        *HOME_READ.map { File.join(home, _1) }])
      end

      # git cannot run without the git dir a linked worktree points at, nor without the objects a clone lain cut
      # reads through alternates; the latter comes from lain's own record, never from the alternates file.
      def self.git_reads(root) = [*linked_git_dir(root), *Isolation::Clone::Guard.upstream_objects(landing(root))]
      private_class_method :git_reads

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
      # {PROJECT_SEALED} is a fixed list at the root, so it cannot seal what
      # rustup, cargo and mise also read from every dir between the cwd and
      # the root (`crates/x/.cargo/config.toml`, `sub/.tool-versions`), nor
      # mise's globs, `.config/mise/conf.d/*.toml` and `mise.<env>.toml`. Its
      # nested names pin `.cargo`, `.config`, `.mise` and `mise` in place,
      # so a project where one of them is a link is refused whole. For a name
      # that is absent, sealing is only a report after the call, and the pairs
      # matter: cargo reads `.cargo/config` over `.cargo/config.toml`, and
      # rustup `rust-toolchain` over `rust-toolchain.toml`, so a call that
      # creates the absent one of a pair overrides the present, sealed one.
      #
      # A project's own build output runs as {#running} says. The exact file
      # {RESOLV_CONF} lands on and {LSM_LIST} are read; cargo's home is a
      # {PrivateHome}; bundler's user config and every mise binary are
      # hidden. `Profiles` gives a plain workspace call a private loopback,
      # one per stage, since bwrap wraps each stage on its own.
      #
      # @param root [String] absolute; the project, read and written whole
      # @param home [String] absolute; where the toolchain grants are looked for
      # @param tmpdir [String] absolute; the caller's TMPDIR, never home or above it
      # @param masks [Array<String>] resolved paths hidden from the call
      # @param exec_files [Array<String>] programs outside /usr the call may run
      # @param trace [Boolean] false where this kernel cannot trace
      # @param configs [Array<String>] git config files git reads for the root; each one the call could
      #   rewrite is sealed, as `.git/config` is, so no include, hook path or fsmonitor can be planted there
      # @param execs [ExecRules] the build output the call runs
      # @return [Profile]
      # @raise [Unsealable] when a seal is reached through a link inside the writes
      # @raise [HomeTmpdir] when the TMPDIR is home or holds it
      # @raise [Tampered] when the root is a clone lain cut whose git dir was tampered with
      # @raise [HoldsState] when the root is lain's state home or holds it
      def self.workspace(root:, home:, tmpdir:, masks: [], exec_files: [], trace: true, configs: [],
                         execs: ExecRules.project(root))
        refuse_workspace(root, home, tmpdir)
        refuse_tampered(landing(root), :workspace)
        reader = reader(root:, home:, masks:, exec_files:, trace:)
        project = reader.read_dirs.first
        git = Seal.git_dirs(project)
        writes = [project, tmpdir, *commit_writes(project, git)]
        homes = PrivateHome.of(home)
        hooks = hooks_outside(project, git)
        new(**reader.to_h, name: :workspace, sealed: sealing(project, git, tmpdir, configs), homes:,
                           write_dirs: [*writes, *homes.map(&:path), *SYSTEM_WRITE],
                           exec_dirs: [*reader.exec_dirs, *hooks],
                           read_dirs: [*reader.read_dirs, *system_files, *hooks], hidden: hidden(home)).running(execs)
      end

      # So a project's own tests run, each rule's directory runs where it is a
      # real directory now, reached through no link from the project, so no
      # call can point one elsewhere for the next. A `CARGO_TARGET_DIR`
      # outside the project runs nothing. lain-fence grants only what exists
      # when it starts, so a dir the call makes runs from the next call on;
      # `Profiles` makes a cargo checkout's `target/` before the call for that reason.
      #
      # @param execs [ExecRules] the build output the call's bounds run
      # @return [Profile] this one, running each such directory under its project
      def running(execs)
        project = read_dirs.first
        with(exec_dirs: [*exec_dirs, *execs.dirs.select { Profile.real_beneath?(_1, project) }].uniq)
      end

      # @param dir [String] absolute
      # @param project [String] absolute, landed
      # @return [Boolean] whether `dir` and every directory between it and the project is a real directory
      def self.real_beneath?(dir, project)
        return false unless dir != project && Landing.under?(dir, project)

        names = dir.delete_prefix(project).split(File::SEPARATOR).reject(&:empty?)
        names.each_index.all? { File.lstat(File.join(project, *names.take(_1 + 1))).directory? }
      rescue SystemCallError
        false
      end

      # The seals a workspace call in `root` would hold, refused as {.workspace} refuses them.
      #
      # @param root [String] absolute
      # @param tmpdir [String] absolute; the caller's TMPDIR
      # @return [Array<Seal>]
      # @raise [Unsealable] when a seal is reached through a link inside the writes
      def self.seals(root:, tmpdir:)
        project = landing(root)
        sealing(project, Seal.git_dirs(project), tmpdir, [])
      end

      # A config file the call could rewrite is sealed; one in the TMPDIR is not, since a call writes only its
      # own dir beneath it.
      def self.sealing(project, git, tmpdir, configs)
        lasting = [project, *commit_writes(project, git)]
        rewritable = configs.select { |file| lasting.any? { Landing.under?(file, _1) } }
        Seal.of(project, git, writable: [*lasting, tmpdir], also: rewritable)
      end
      private_class_method :sealing

      # What a workspace build depends on beyond its seals: a path that comes or goes changes the profile.
      #
      # @param root [String]
      # @param home [String]
      # @return [Array<String>]
      def self.watched(root, home)
        [File.join(root, "target"), File.join(home, PrivateHome::CARGO),
         File.join(home, BUNDLE_CONFIG), File.join(home, MISE_SHIMS), RESOLV_CONF]
      end

      # cargo runs its build scripts out of `target/`, so a link or a file
      # there gets cargo no grant; {#running} grants the real one.
      #
      # @param project [String]
      # @return [Array<String>, nil] the target dir, none when absent, nil when it is not a real directory
      def self.target(project)
        path = File.join(project, "target")
        File.lstat(path).directory? ? [path] : nil
      rescue Errno::ENOENT
        []
      rescue SystemCallError
        nil
      end

      def self.system_files
        [*landing_file(RESOLV_CONF), LSM_LIST]
      end
      private_class_method :system_files

      def self.landing_file(path)
        landed = File.realpath(path)
        File.file?(landed) ? [landed] : []
      rescue SystemCallError
        []
      end
      private_class_method :landing_file

      def self.hidden(home)
        [*landing_file(File.join(home, BUNDLE_CONFIG)),
         *[*MISE, File.join(home, HOME_MISE), *shim_target(File.join(home, MISE_SHIMS))].flat_map { landing_file(_1) }]
          .uniq
      end
      private_class_method :hidden

      def self.shim_target(shims)
        Dir.each_child(shims).lazy.map { File.join(shims, _1) }.select { File.symlink?(_1) }.first(1)
      rescue SystemCallError
        []
      end
      private_class_method :shim_target

      # The workspace profile with a build tool's ports, the resolver's socket
      # dir, and what the tool writes outside the project: bundle its gem home
      # and its user cache, cargo its fetched sources; the workspace's exec
      # rules already run `target/`. Every seal the workspace holds is kept. Where a
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
             write_dirs: [*write_dirs, *tool.writes],
             sealed: [*sealed, *tool.seals], homes: homes.map { _1.opening(tool.writes) }, private_net: false)
      end

      # git's answer is read a line per path, and a TMPDIR at or above home grants home.
      def self.refuse_workspace(root, home, tmpdir)
        raise ArgumentError, "a workspace root must not contain a newline, got #{root.inspect}" if root.include?("\n")

        refuse_state_root(root)
        return unless tmpdir.start_with?(File::SEPARATOR) && Landing.under?(landing(home), landing(tmpdir))

        raise HomeTmpdir.new(path: tmpdir)
      end
      private_class_method :refuse_workspace

      # A clone sits two levels into the container, or three under a lease root's aside dir; anything shallower
      # holds the records beside the clones.
      def self.refuse_state_root(root)
        container = landed_ancestry(Isolation::Clone::Guard.container)
        project = landing(root)
        raise HoldsState.new(path: root, state: File.dirname(container)) if holds_records?(project, container)
      end
      private_class_method :refuse_state_root

      # The container is made at the first lease, so before it exists its nearest existing ancestor is resolved
      # and the rest appended: a linked state home must be compared where it really is. Nothing is made here.
      def self.landed_ancestry(path)
        missing = []
        until File.exist?(path) || path == File::SEPARATOR
          missing.unshift(File.basename(path))
          path = File.dirname(path)
        end
        File.join(landing(path), *missing)
      end
      private_class_method :landed_ancestry

      def self.holds_records?(project, container)
        return Landing.under?(File.dirname(container), project) unless Landing.under?(project, container)

        parts = Pathname(project).relative_path_from(container).each_filename.to_a
        parts.size < 2 || parts[1..] == [Isolation::Worktree::RETAINED]
      end
      private_class_method :holds_records?

      def self.refuse_tampered(project, profile)
        why = Isolation::Clone::Guard.refusal(project)
        raise Tampered.new(path: project, why:, profile:) unless why.empty?
      end
      private_class_method :refuse_tampered

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

      # git runs a hook beneath a hooks dir outside the project, a shared clone's upstream's among them, only
      # when the call may read and exec it; it is sealed, so what runs there is what the human put there.
      #
      # @param project [String]
      # @param git [Array<String>] {Seal.git_dirs} of `project`
      # @return [Array<String>] the hooks dir where it lands, or none
      def self.hooks_outside(project, git)
        hooks = git[2]
        return [] unless hooks && File.directory?(hooks)

        landed = landing(hooks)
        Landing.under?(landed, project) ? [] : [landed]
      end
      private_class_method :hooks_outside

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

      BuildTool = Data.define(:writes, :seals)

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
          else new(writes: [], seals: [])
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
          seals && new(writes:, seals:)
        end

        # cargo's own bin is where its home is meant to hold a reader's grant.
        def self.cargo(project, home, env)
          cargo_home = named(env, "CARGO_HOME") || File.join(home, PrivateHome::CARGO)
          return unless Profile.target(project) && bounded?(cargo_home, home) &&
                        holds_nothing?(cargo_home, project, home, own: File.join(cargo_home, "bin"))

          new(writes: CARGO_WRITES.map { File.join(cargo_home, _1) }, seals: [])
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

        # @return [Array<Seal>, nil] nil when the dir would sit in a write and is absent
        def self.installs_in(bindir, writes)
          return [] unless writes.any? { Landing.under?(bindir, _1) }
          return unless File.directory?(bindir)

          [Seal.new(path: -Profile.landing(bindir), absent: false)]
        end
        private_class_method :bundle, :cargo, :named, :bounded?, :holds_nothing?, :installs_in
      end

      PrivateHome = Data.define(:path, :reads, :writes, :files)

      # A home dir the call sees as its own: a dir made for the call mounted
      # at `path`, the user's `reads` bound back read-only and `writes`
      # writable over it, and `files` lain writes. Nothing else of the user's
      # dir shows, so a secret put there later, under any name, stays out,
      # and every other write lands in the call's dir and goes with it.
      class PrivateHome
        CARGO = ".cargo"
        # git checkouts are public sources, like the registry, and a lock naming one may change between calls.
        CARGO_READS = %w[registry bin git].freeze
        # The last-use database starts empty in a private home, and a gc reading it would delete crates from a
        # registry the call cannot write.
        CARGO_FILES = { "config.toml" => %([cache]\nauto-clean-frequency = "never"\n) }.freeze
        HOMES = ".lain-homes"

        # @param path [String] absolute; the home dir the call sees
        # @param reads [Array<String>] names beneath it bound back read-only
        # @param writes [Array<String>] names beneath it bound back writable
        # @param files [Hash{String => String}] what lain writes at the top, by name
        def initialize(path:, reads:, writes: [], files: {})
          super(path: -path, reads: reads.map(&:-@).freeze, writes: writes.map(&:-@).freeze,
                files: files.to_h { |name, body| [-name, -body] }.freeze)
        end

        # @param path [String]
        # @param reads [Array<String>]
        # @param writes [Array<String>]
        # @return [PrivateHome] cargo's, with a config that never cleans
        def self.cargo(path, reads:, writes: []) = new(path:, reads:, writes:, files: CARGO_FILES)

        # Only a real directory is mounted over: bwrap cannot mount at a path that is not there, and would mount
        # through a link to wherever it lands.
        #
        # @param home [String]
        # @return [Array<PrivateHome>] cargo's, or none where home has no real ~/.cargo
        def self.of(home)
          path = File.join(Profile.landing(home), CARGO)
          File.lstat(path).directory? ? [cargo(path, reads: CARGO_READS)] : []
        rescue SystemCallError
          []
        end

        # @param paths [Array<String>] what a grant writes
        # @return [PrivateHome] with each of `paths` beneath it bound back writable
        def opening(paths)
          opened = paths.select { Landing.under?(_1, path) && _1 != path }
                        .map { Pathname(_1).relative_path_from(path).to_s }
          opened.empty? ? self : with(reads: reads - opened, writes: [*writes, *opened].uniq)
        end

        # @param call_dir [String] the call's own TMPDIR, removed after it
        # @return [String] where this home's writes land
        def source(call_dir) = File.join(call_dir, HOMES, File.basename(path))

        # @param call_dir [String]
        # @return [void]
        def make(call_dir)
          dir = FileUtils.mkdir_p(source(call_dir)).first
          files.each { |name, body| File.write(File.join(dir, name), body) }
        end
      end

      Seal = Data.define(:path, :absent, :hops)

      # A persistence path a workspace call must not change. An absent one is
      # not enforced; it is listed for a check after the call. A dangling link
      # cannot be mounted, so it is sealed where it lands, absent there.
      # `hops` names each link on the way, so a repointed one is noticed.
      class Seal
        # Where git reads further object stores from: a call that repoints one makes an unsandboxed fetch out
        # of the checkout read objects from wherever it names.
        ALTERNATES = %w[alternates http-alternates].freeze

        # @param path [String] where the seal lands
        # @param absent [Boolean]
        # @param hops [Array<String>] each link met on the way to `path`, at its real place
        def initialize(path:, absent:, hops: [])
          super(path:, absent:, hops: hops.map(&:-@).freeze)
        end

        # The hooks dir is asked first, before the absolute format, which would resolve a link on its way.
        GIT_ASKS = %w[rev-parse --git-path hooks --path-format=absolute --git-common-dir --absolute-git-dir].freeze

        # @param root [String] absolute
        # @param git [Array<String>] {.git_dirs} of `root`
        # @param writable [Array<String>] what the call may write, where a link on a seal's way is refused
        # @param also [Array<String>] further absolute paths to seal, such as a config file git includes
        # @return [Array<Seal>] the hooks, the git configs, what redirects git, the lain dir and
        #   {Profile::PROJECT_SEALED}
        # @raise [Unsealable]
        def self.of(root, git = git_dirs(root), writable: [root], also: [])
          writes = writable.map { Profile.landing(_1) }
          landed = named(root, git, also).map { [_1, landings(_1)] }
          landed.each { |name, seals| seals.each { refuse_link(name, _1, writes, root) } }
          landed.reject { device?(_1.first, writable) }.flat_map(&:last).group_by(&:path).map do |path, seals|
            new(path:, absent: seals.first.absent, hops: seals.flat_map(&:hops).uniq)
          end
        end

        def self.named(root, git, also)
          [*in_git(root, *git), ProjectDir.new(root:).dir, *Profile::PROJECT_SEALED.map { File.join(root, _1) }, *also]
        end

        def self.in_git(root, common = nil, gitdir = nil, hooks = nil)
          dot_git = File.join(root, ".git")
          return File.exist?(dot_git) || File.symlink?(dot_git) ? [dot_git] : [] unless common

          [File.join(common, "hooks"), File.join(common, "config"), File.join(gitdir, "config.worktree"), hooks,
           File.join(gitdir, "commondir"), *pointer(dot_git), File.join(common, "modules"),
           *worktrees(common, gitdir), *ALTERNATES.map { File.join(common, "objects", "info", _1) }]
        end

        # The main checkout seals every worktree's admin dir whole, as one mount however many there are; a
        # linked one writes its own, so there only the pointers back are sealed.
        def self.worktrees(common, gitdir)
          return [File.join(common, "worktrees")] if gitdir == common

          Dir.glob(%w[commondir gitdir].map { File.join(common, "worktrees", "*", _1) })
        end

        # A `.git` file redirects git, and a `.git` link is refused on the way to the seals under it.
        def self.pointer(dot_git) = File.file?(dot_git) || File.symlink?(dot_git) ? [dot_git] : []

        # The call could repoint a link inside the writes after the seal is mounted, so one anywhere on the way
        # is refused rather than sealed past.
        def self.refuse_link(path, seal, writes, root)
          link = seal.hops.find { |place| writes.any? { place != _1 && Landing.under?(place, _1) } }
          raise Unsealable.new(path:, link:, root:) if link
        end

        # A read-only bind leaves a device unopenable, and git opens /dev/null on every call; one landing
        # outside the writes cannot be swapped for a hooks dir, so it needs no seal. A link to one is still
        # sealed, since its hops are what notice a repoint.
        def self.device?(path, writable)
          return false unless File.lstat(path).chardev?

          landing = File.realpath(path)
          writable.none? { Landing.under?(landing, _1) }
        rescue SystemCallError
          false
        end

        # A `..` after a missing component is sealed at that component, yet the call could plant beneath what
        # the text spells today and remove the component again, so that is sealed too.
        def self.landings(path)
          seal = at(path)
          climbs = seal.absent && Landing::Walk.parts(path).include?("..")
          spelled = climbs ? [at(File.expand_path(path))].reject(&:absent) : []
          [seal, *spelled]
        end

        def self.at(path) = from(Landing.walk(path))

        # A loop is sealed at the link the kernel refused, and a missing component as {.missing} folds the rest.
        def self.from(walk)
          return new(path: walk.hops.last, absent: true, hops: walk.hops.take(Landing::HOPS)) if walk.looped?
          return new(path: walk.path, absent: false, hops: walk.hops) unless walk.absent?

          name, *rest = walk.tail
          new(path: -missing(File.join(walk.path, name), rest), absent: true, hops: walk.hops)
        end

        # A `..` after a missing component climbs from wherever the call makes it lead, so it is sealed itself.
        def self.missing(place, rest) = rest.include?("..") ? place : File.join(place, *rest)

        private_class_method :named, :in_git, :worktrees, :pointer, :refuse_link, :device?, :landings, :at, :from,
                             :missing

        # git answers core.hooksPath and a worktree's pointer itself, includes
        # and all, so this asks it once rather than parsing its config.
        #
        # @param root [String]
        # @return [Array<String>] common dir, git dir and hooks dir, the hooks dir as git spells it under `root`;
        #   none where git cannot answer
        def self.git_dirs(root)
          laid_out = Isolation::Clone::Guard.git_dirs(root)
          return laid_out if laid_out

          out, status = Open3.capture2(Isolation::Worktree::GIT_SPAWN_ENV, "git", "-C", root, *GIT_ASKS,
                                       err: File::NULL)
          hooks, *dirs = out.lines(chomp: true)
          status.success? && dirs.size == 2 ? [*dirs, spelled_under(root, hooks)] : []
        rescue SystemCallError
          []
        end

        # Not expanded: a `..` after a link climbs from where the link lands, which only {.at} can see.
        def self.spelled_under(root, path) = path.start_with?(File::SEPARATOR) ? path : File.join(root, path)
        private_class_method :spelled_under
      end
    end
  end
end
