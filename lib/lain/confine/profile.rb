# frozen_string_literal: true

require "open3"
require "pathname"

module Lain
  module Confine
    Profile = Data.define(:name, :exec_dirs, :exec_files, :read_dirs, :write_dirs, :masks, :tmpfs_bytes, :trace,
                          :connect_ports, :unix_dirs, :sealed)

    # What one call may do: run beneath `exec_dirs` and exactly `exec_files`,
    # read beneath `read_dirs`, write beneath `write_dirs`, and never see
    # `masks`. `trace` records every exec. `connect_ports` are the TCP ports it may
    # connect to and `unix_dirs` the directories whose Unix sockets it may
    # reach; the reader has neither. `:none` runs as before, `:traced`
    # only watches, `:reader` confines, and `:workspace` confines while
    # writing the project, which `sealed` keeps from planting what runs later. Both unconfined profiles still run
    # under lain-fence as a reaper, so a stopped call leaves no descendant
    # behind; that covers a call made through a sandbox, and `--confine off`
    # or a box lacking bwrap or Landlock builds none.
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

      # Relative to the root: files a later shell, hook or lain session runs.
      PROJECT_SEALED = %w[.lain .envrc .pre-commit-config.yaml].freeze

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
                     connect_ports: [], unix_dirs: [], sealed: [], tmpfs_bytes: TMPFS_BYTES)
        grants = { exec_dirs:, exec_files:, read_dirs:, write_dirs:, masks:, unix_dirs: }
        relative = [*grants.values.flatten, *sealed.map(&:path)].reject { _1.start_with?(File::SEPARATOR) }
        # The fence and bwrap resolve a relative path against wherever they
        # happen to run, which is not a grant anyone wrote.
        raise ArgumentError, "a profile path must be absolute, got #{relative.first.inspect}" if relative.any?

        super(name:, trace:, tmpfs_bytes:, connect_ports: valid_ports(connect_ports).freeze, sealed: sealed.dup.freeze,
              **grants.transform_values { |paths| paths.map(&:-@).freeze })
      end

      def valid_ports(ports)
        bad = ports.find { !(_1.is_a?(Integer) && _1.between?(1, 65_535)) }
        raise ArgumentError, "a connect port must be an integer from 1 to 65535, got #{bad.inspect}" if bad

        ports.dup
      end
      private :valid_ports

      # @return [Boolean] whether the kernel bounds what the call may reach
      def confined? = Profile.confines?(name)

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
      # and with no `.git` the list is {PROJECT_SEALED} alone. A background
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
      # root reached through a link must be named by its landing.
      #
      # @param root [String]
      # @return [String] the resolved root, or `root` as written when it cannot be resolved
      def self.landing(root)
        root.start_with?(File::SEPARATOR) ? File.realpath(root) : root
      rescue SystemCallError
        root
      end
      private_class_method :landing

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

      Seal = Data.define(:path, :absent)

      # A persistence path a workspace call must not change. An absent one is
      # not enforced; it is listed for a check after the call.
      class Seal
        # The hooks dir is asked first, before the absolute format, which would resolve a link on its way.
        GIT_ASKS = %w[rev-parse --git-path hooks --path-format=absolute --git-common-dir --absolute-git-dir].freeze

        # @param root [String] absolute
        # @param git [Array<String>] {.git_dirs} of `root`
        # @param writable [Array<String>] what the call may write, where a link on a seal's way is refused
        # @return [Array<Seal>] the hooks, the git configs, what redirects git, and {Profile::PROJECT_SEALED}
        # @raise [Unsealable]
        def self.of(root, git = git_dirs(root), writable: [root])
          named = [*in_git(root, *git), *Profile::PROJECT_SEALED.map { File.join(root, _1) }]
          named.each { refuse_link(_1, writable) }
          named.map { at(_1) }.uniq
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

        def self.at(path)
          File.exist?(path) ? new(path: -File.realpath(path), absent: false) : new(path: -path, absent: true)
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
