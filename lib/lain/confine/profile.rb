# frozen_string_literal: true

module Lain
  module Confine
    Profile = Data.define(:name, :exec_dirs, :exec_files, :read_dirs, :write_dirs, :masks, :tmpfs_bytes, :trace)

    # What one call may do: run beneath `exec_dirs` and exactly `exec_files`,
    # read beneath `read_dirs`, write beneath `write_dirs`, and never see
    # `masks`. `trace` records every exec. `:none` runs as before, `:traced`
    # only watches, and `:reader` confines.
    #
    # A value: a {Launcher} turns it into argv. Every path is absolute and,
    # for a mask, already resolved, because bwrap aborts on a mask that is a
    # symlink. The project is the first read dir, which is how {Bwrap} finds
    # it to bind back over the private /tmp.
    class Profile
      # The call's /tmp is a tmpfs of its own, discarded when it exits, so it
      # is granted whole; tmpfs would otherwise take up to half of RAM.
      TMPFS_BYTES = 1024 * 1024 * 1024

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

      def initialize(name:, trace:, exec_dirs: [], exec_files: [], read_dirs: [], write_dirs: [], masks: [],
                     tmpfs_bytes: TMPFS_BYTES)
        grants = { exec_dirs:, exec_files:, read_dirs:, write_dirs:, masks: }
        relative = grants.values.flatten.reject { _1.start_with?(File::SEPARATOR) }
        # The fence and bwrap resolve a relative path against wherever they
        # happen to run, which is not a grant anyone wrote.
        raise ArgumentError, "a profile path must be absolute, got #{relative.first.inspect}" if relative.any?

        super(name:, trace:, tmpfs_bytes:, **grants.transform_values { |paths| paths.map(&:-@).freeze })
      end

      # @return [Boolean] whether the kernel bounds what the call may reach
      def confined? = !%i[none traced].include?(name)

      # @param path [String] a resolved program
      # @return [Boolean] whether the fence lets the call exec it
      def runs?(path) = exec_files.include?(path) || exec_dirs.any? { path.start_with?("#{_1}/") }

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
    end
  end
end
