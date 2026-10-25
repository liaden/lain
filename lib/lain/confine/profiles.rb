# frozen_string_literal: true

require "open3"
require "tmpdir"

module Lain
  module Confine
    # Chooses the {Profile} a call runs under. The ruling decides, never the
    # resolution: an approval by {Approval::ComposedTerm} rested on the call
    # only reading, so it runs under the reader profile. With the workspace
    # switch on, an automatic allow by the judge, a rule or bypass runs under the
    # workspace profile, since no person saw the command. Any other allow is
    # traced and not confined: a human's, and a surface's, whose machine
    # answers stand beside a person's in the same queue.
    #
    # What this kernel lacks narrows the profile: no trace leaves a reader
    # confined and untraced, and every other call unwatched.
    class Profiles
      # A listed link lands on a program or directory the call runs on, so its
      # mask would leave an empty view or an exec that fails for no visible reason.
      class Overmasked < Error
        attr_reader :path, :names, :profile

        # @param path [String] the program or directory the mask would hide
        # @param names [Array<String>] the listed names that landed on it
        # @param profile [Symbol] the profile the call would have run under
        def initialize(path:, names:, profile: :reader)
          @path = path
          @names = names
          @profile = profile
          super("#{names.join(", ")} lands on #{path}, which the call needs")
        end
      end

      # The TMPDIR a workspace call gets its own dir beneath cannot hold one, most often because it has gone.
      class NoTmpdir < Error
        attr_reader :path, :profile

        # @param path [String] the TMPDIR
        # @param profile [Symbol] the profile the call would have run under
        def initialize(path:, profile: :workspace)
          @path = path
          @profile = profile
          super("cannot make the call's own dir beneath #{path}")
        end
      end

      # The rungs whose automatic allow earns the workspace profile, named so a new rung earns nothing by default.
      WORKSPACE_RUNGS = [Approval::Judged::NAME, Approval::Escalation::Rules::NAME,
                         Approval::Escalation::Bypass::NAME].freeze

      CALL_DIR = "lain-call-"

      # @param masks [#masks] the session's {MaskList}, asked on every call so a
      #   mask whose file has gone never reaches bwrap, which fails on one
      # @param probe [#supports?] which sandbox layers this kernel offers
      # @param home [String] absolute; where the toolchain grants are looked for
      # @param root [String] absolute; the session's project, for a request that names no root of its own
      # @param workspace [Boolean] whether an automatic allow runs under the workspace profile
      # @param tmpdir [String] absolute; where each workspace call gets a dir of its own to write
      def initialize(masks:, probe:, home:, root:, workspace: false, tmpdir: Dir.tmpdir)
        @masks = masks
        @probe = probe
        @home = home
        @root = root
        @workspace = workspace
        @tmpdir = tmpdir
        @sealed = Sealed.new(home:, tmpdir:)
      end

      # @param request [Request]
      # @return [Profile]
      # @raise [Overmasked] when a mask would empty a directory the reader or workspace profile grants
      # @raise [Profile::Unsealable] when a workspace seal is reached through a link inside the writes
      # @raise [NoTmpdir] when the TMPDIR cannot hold the workspace call's own dir
      def for(request)
        ruling = request.ruling
        return reader(request) if read_only?(ruling)
        return workspace(request) if workspace?(ruling)

        traceable? ? Profile::TRACED : Profile::NONE
      end

      private

      def read_only?(ruling) = ruling.allow? && ruling.rule == Approval::ComposedTerm.rule_name

      def workspace?(ruling) = @workspace && ruling.allow? && !ruling.human? && WORKSPACE_RUNGS.include?(ruling.rung)

      def traceable? = @probe.supports?(:trace)

      def reader(request)
        granted(Profile.reader(root: root_of(request), home: @home, masks: mask_paths,
                               exec_files: exec_files(request.executables), trace: traceable?))
      end

      # The call's dir is made last, so a call refused on the way leaves none
      # behind, and never beneath the private /tmp, which is the call's own already.
      def workspace(request)
        sealed = @sealed.for(root_of(request), trace: traceable?)
        profile = granted(sealed.with(masks: mask_paths, exec_files: exec_files(request.executables)))
        Profile::SYSTEM_WRITE.include?(@tmpdir) ? profile : profile.for_call(call_dir, granted: @tmpdir)
      end

      def call_dir
        Dir.mktmpdir(CALL_DIR, @tmpdir)
      rescue SystemCallError
        raise NoTmpdir.new(path: @tmpdir)
      end

      def root_of(request) = request.root || @root

      def mask_paths = @masks.masks.map(&:path)

      def granted(profile)
        overmask = profile.overmask
        raise Overmasked.new(path: overmask, names: @masks.landed_on(overmask), profile: profile.name) if overmask

        profile
      end

      # A program the call resolved to outside /usr may run, unless the project
      # could have put it there: that is the plant the reader profile exists to stop.
      def exec_files(executables)
        executables.flat_map(&:programs).select { grantable?(_1) }.map(&:realpath).uniq
      end

      def grantable?(executable)
        Profile::GRANTED_CLASSES.include?(executable.klass) && !executable.realpath.nil? &&
          Profile::SYSTEM_EXEC.none? { executable.realpath.start_with?("#{_1}/") }
      end

      # A workspace profile with no masks and no programs, kept per landed root
      # and trace: building one asks git where its dirs are and which config
      # files it read, about 4 ms. It is rebuilt once any seal's path or config
      # file has appeared, gone, or changed, so a path made absent or present
      # between calls is never served stale, and nor is a hooks dir an
      # included file names. At most {KEPT} roots are kept.
      class Sealed
        KEPT = 64
        CONFIG_ASKS = %w[config --list --show-origin -z].freeze
        INCLUDE = /\Ainclude(?:if\..*)?\.path\z/i
        Kept = Data.define(:profile, :configs, :stamp)

        # @param home [String]
        # @param tmpdir [String]
        def initialize(home:, tmpdir:)
          @home = home
          @tmpdir = tmpdir
          @kept = {}
          @lock = Mutex.new
        end

        # @param root [String]
        # @param trace [Boolean]
        # @return [Profile]
        # @raise [Profile::Unsealable]
        def for(root, trace:)
          key = [Profile.landing(root), trace]
          @lock.synchronize do
            kept = @kept[key]
            return kept.profile if kept && kept.stamp == stamp(kept.profile, kept.configs)

            built = build(*key)
            keep(key, built) if consistent?(built)
            built.profile
          end
        end

        private

        def build(root, trace)
          profile = Profile.workspace(root:, home: @home, tmpdir: @tmpdir, trace:)
          configs = config_files(root)
          Kept.new(profile:, configs:, stamp: stamp(profile, configs))
        end

        def keep(key, built)
          @kept.clear if @kept.size >= KEPT
          @kept[key] = built
        end

        # A set whose seals changed while it was built lists one absent that is there, or the reverse.
        def consistent?(built) = built.profile.sealed.zip(built.stamp).all? { |seal, id| seal.absent == id.nil? }

        # The seals come first, in order, which is what {#consistent?} reads.
        def stamp(profile, configs)
          watched = [*profile.sealed.flat_map(&:hops), *configs]
          [*profile.sealed.map { identity(_1.path) }, *watched.map { identity(_1) }]
        end

        def identity(path)
          stat = File.lstat(path)
          [stat.dev, stat.ino, stat.mtime]
        rescue SystemCallError
          nil
        end

        # Every file git read config from, every file an include names, and
        # git's own global and system files, since one that is missing or empty
        # contributes no entry of its own.
        def config_files(root)
          [*standard_configs(ENV.to_h.merge(Isolation::Worktree::GIT_CONTEXT_SCRUB)), *read_configs(root)].uniq
        end

        def read_configs(root)
          out, status = Open3.capture2(Isolation::Worktree::GIT_CONTEXT_SCRUB, "git", "-C", root, *CONFIG_ASKS,
                                       err: File::NULL)
          return [] unless status.success?

          out.split("\0").each_slice(2).flat_map { |origin, entry| named(root, origin.to_s, entry.to_s) }
        rescue SystemCallError
          []
        end

        # Where git looks for its global and system config, read from the env git is run with.
        def standard_configs(env)
          system = env["GIT_CONFIG_NOSYSTEM"] ? [] : [env.fetch("GIT_CONFIG_SYSTEM", "/etc/gitconfig")]
          [*(env["GIT_CONFIG_GLOBAL"] ? [env["GIT_CONFIG_GLOBAL"]] : user_configs(env)), *system]
            .map { File.expand_path(_1) }
        end

        def user_configs(env)
          home = env["HOME"]
          return [] if home.to_s.empty?

          xdg = env["XDG_CONFIG_HOME"].to_s.empty? ? File.join(home, ".config") : env["XDG_CONFIG_HOME"]
          [File.join(home, ".gitconfig"), File.join(xdg, "git", "config")]
        end

        def named(root, origin, entry)
          return [] unless origin.start_with?("file:")

          file = File.expand_path(origin.delete_prefix("file:"), root)
          key, value = entry.split("\n", 2)
          [file, *(File.expand_path(value, File.dirname(file)) if key.match?(INCLUDE) && value)]
        end
      end
      private_constant :Sealed
    end
  end
end
