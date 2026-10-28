# frozen_string_literal: true

require "fileutils"
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
    # A workspace call earns its build tool's ports, the grant profile, only
    # through {BuildGrant}: one fetching stage of a trusted program, while
    # nothing in the project is fresh.
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

      # What a caller with no policy hands over: every path is ordinary.
      module Unclassified
        # @param _path [String]
        # @return [Sensitivity::Verdict]
        def self.classify(_path) = Sensitivity::ORDINARY.verdict
      end

      # The freshness a caller that read no lineage hands over: every root
      # counts as fresh, so nothing is granted its ports.
      module Unread
        # @param _root [String]
        # @return [true]
        def self.any_under?(_root) = true
      end

      # @param masks [#masks] the session's {MaskList}, asked on every call so a
      #   mask whose file has gone never reaches bwrap, which fails on one
      # @param probe [#supports?] which sandbox layers this kernel offers
      # @param home [String] absolute; where the toolchain grants are looked for
      # @param root [String] absolute; the session's project, for a request that names no root of its own
      # @param workspace [Boolean] whether an automatic allow runs under the workspace profile
      # @param tmpdir [String] absolute; where each workspace call gets a dir of its own to write
      # @param fresh [#any_under?] the lineage's freshness, which a build tool's grant needs to be quiet
      # @param env [#[]] where a grant reads where bundler installs
      # @param classifier [#classify] the session's policy on a path, asked before a git config file outside the
      #   project is granted; by default every path is ordinary
      def initialize(masks:, probe:, home:, root:, workspace: false, tmpdir: Dir.tmpdir, fresh: Unread, env: ENV,
                     classifier: Unclassified)
        @masks = masks
        @probe = probe
        @home = home
        @root = root
        @workspace = workspace
        @tmpdir = tmpdir
        @fresh = fresh
        @env = env
        @classifier = classifier
        @sealed = Sealed.new(home:, tmpdir:)
        @build = BuildGrant.new(fresh:, home:)
      end

      # @param request [Request]
      # @return [Profile]
      # @raise [Overmasked] when a mask would empty a directory the reader or workspace profile grants
      # @raise [Profile::Unsealable] when a workspace seal is reached through a link inside the writes
      # @raise [NoTmpdir] when the TMPDIR cannot hold the workspace call's own dir
      # @raise [Profile::HomeTmpdir] when the TMPDIR a workspace call would write is home or holds it
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
        root = root_of(request)
        profile = Profile.reader(root:, home: @home, masks: mask_paths(root),
                                 exec_files: exec_files(placed(request.executables)), trace: traceable?)
        granted(profile.with(read_dirs: [*profile.read_dirs, *git_configs(root)]))
      end

      # The call's dir is made last, so a call refused on the way leaves none
      # behind, and never beneath the private /tmp, which is the call's own already.
      def workspace(request)
        masks = mask_paths(root_of(request))
        programs = programs(request, masks)
        profile = granted(networked(ported(request)).then do |ported|
          ported.with(masks:, exec_files: exec_files(programs),
                      exec_dirs: [*ported.exec_dirs, *install_bins(programs)].uniq,
                      read_dirs: [*ported.read_dirs, *git_configs(root_of(request))].uniq)
        end)
        Profile::SYSTEM_WRITE.include?(@tmpdir) ? profile : housed(profile.for_call(call_dir, granted: @tmpdir))
      end

      # A grant fetches from the host's network; a plain workspace call gets
      # a loopback of its own, where the box can make one. bwrap wraps each
      # stage, so the loopback is per stage: stages of one pipeline cannot
      # reach each other over it.
      def networked(profile)
        profile.name == :workspace && @probe.supports?(:private_net) ? profile.with(private_net: true) : profile
      end

      def housed(profile)
        profile.homes.each { _1.make(profile.call_tmpdir) }
        profile
      rescue SystemCallError
        FileUtils.rm_rf(profile.call_tmpdir)
        raise NoTmpdir.new(path: @tmpdir)
      end

      # A bin dir is granted whole, its subdirs with it, so never one that holds a dir or anything fresh.
      def install_bins(programs)
        programs.filter_map { Profile.install_bin(_1.realpath, home: @home) }.uniq
                .select { flat?(_1) && !@fresh.any_under?(_1) }
      end

      # A dir that is not there holds nothing to run; one that cannot be listed may hold anything.
      def flat?(dir)
        Dir.children(dir).none? { File.directory?(File.join(dir, _1)) }
      rescue Errno::ENOENT
        true
      rescue SystemCallError
        false
      end

      def ported(request)
        root = root_of(request)
        sealed = @sealed.for(root, trace: traceable?)
        program = @build.program(request, root)
        program ? sealed.granting(program, home: @home, env: @env) : sealed
      end

      def call_dir
        Dir.mktmpdir(CALL_DIR, @tmpdir)
      rescue SystemCallError
        raise NoTmpdir.new(path: @tmpdir)
      end

      def root_of(request) = request.root || @root

      # A project config file git reads is shown to the call, sealed in a workspace call, since git cannot run
      # without it; every other mask stands.
      def mask_paths(root) = @masks.masks.map(&:path) - project_configs(root)

      def project_configs(root)
        project = Profile.landing(root)
        @sealed.configs(root).origins.filter_map { landed_file(_1) }.select { Landing.under?(_1, project) }
      end

      # git exits 128 on a config file it cannot read, wherever the user keeps it, so each file it read config
      # from is granted on its own, at its landing. Never what the policy denies, and never a credential-shaped
      # file reached by an include chain that starts in the project, whose config a repository ships. The
      # project is read whole already.
      def git_configs(root)
        project = Profile.landing(root)
        configs = @sealed.configs(root)
        origins = configs.origins.reject { configs.reached_from?(_1, project) && level(_1) == :gated }
        [*configs.globals, *origins].filter_map { landed_file(_1) }
                                    .reject { level(_1) == :denied || Landing.under?(_1, project) }.uniq
      end

      def level(path) = @classifier.classify(path).level

      def landed_file(path)
        landed = File.realpath(path)
        landed if File.file?(landed)
      rescue SystemCallError
        nil
      end

      def granted(profile)
        overmask = profile.overmask
        raise Overmasked.new(path: overmask, names: @masks.landed_on(overmask), profile: profile.name) if overmask

        profile
      end

      # A parsed guess under a mask is dropped where a resolved stage there
      # refuses the call, since the guess may name a program the shell never runs.
      def programs(request, masks)
        [*placed(request.executables), *placed(request.grants).reject { masked?(_1.realpath, masks) }]
      end

      # A program the call resolved to outside /usr may run, unless the project
      # could have put it there: that is the plant the reader profile exists to
      # stop. Both arms ask the one placement test a build tool's grant does.
      def placed(executables)
        executables.flat_map(&:programs).select { grantable?(_1) && BuildGrant.placed?(_1, home: @home) }
      end

      def exec_files(programs) = programs.map(&:realpath).uniq

      def masked?(path, masks) = masks.any? { Landing.under?(path, _1) }

      def grantable?(executable)
        Profile::GRANTED_CLASSES.include?(executable.klass) && !executable.realpath.nil? &&
          Profile::SYSTEM_EXEC.none? { executable.realpath.start_with?("#{_1}/") }
      end

      # Names the build tool a workspace call may give its ports, or nil. The
      # call must be one stage, the program word bare and resolved to a trusted
      # file, the subcommand one that fetches, every option one its list names,
      # and the cwd inside the root. Then nothing under the root may be fresh,
      # whether or not a run file names it: a gemspec loads code no run file
      # lists. A run file outside the root, such as git's config in a worktree's
      # common dir, must be quiet on its own.
      #
      # Options are an allowlist matched whole, because git and cargo take
      # abbreviations and bundled short options a denylist never sees:
      # `--upload=x` is git's `--upload-pack=x`, and `-qu x` its `-q -u x`. A
      # value rides on its option as `=N`, digits only, since a value in a word
      # of its own reads as an operand.
      class BuildGrant
        COUNT = /=\d+\z/

        # Per tool, per subcommand: the options it may carry; one ending in `=` takes a count.
        OPTIONS = {
          "bundle" => { "install" => %w[--frozen --local --prefer-local --quiet --verbose --jobs= --retry=] },
          "cargo" => { "build" => %w[--locked --frozen --offline --quiet --verbose --release --jobs=],
                       "fetch" => %w[--locked --frozen --offline --quiet --verbose] },
          "git" => { "fetch" => %w[--quiet --verbose --prune --tags --all --depth=],
                     "clone" => %w[--quiet --verbose --single-branch --no-tags --depth=],
                     "pull" => %w[--quiet --verbose --ff-only],
                     "ls-remote" => %w[--quiet --heads --tags --refs] }
        }.then { |table| Profile::GRANTS.keys.to_h { [_1, table.fetch(_1).freeze] } }.freeze

        # @param fresh [#any_under?]
        # @param home [String] absolute
        def initialize(fresh:, home:)
          @fresh = fresh
          @home = home
        end

        # ComposedTerm's test: a user program that shadows another of its name is how an old plant shows. A
        # program in a mise install is the toolchain, which is put ahead of /usr/bin and mise's shims on purpose.
        #
        # @param stage [Shell::Executable]
        # @param home [String] absolute; where the mise installs are
        # @return [Boolean]
        def self.placed?(stage, home:)
          Profile::GRANTED_CLASSES.include?(stage.klass) && !stage.realpath.nil? && !stage.fresh &&
            !(stage.klass == :user && stage.shadowed.any? && !Profile.install_bin(stage.realpath, home:))
        end

        # @param request [Request]
        # @param root [String]
        # @return [String, nil] a key of {Profile::GRANTS}
        def program(request, root)
          stage, argv = sole(request)
          name = argv&.first
          return unless OPTIONS.key?(name) && trusted?(stage, name) && asked?(OPTIONS.fetch(name), argv.drop(1))
          return unless inside?(request.cwd, root)

          name unless @fresh.any_under?(root)
        end

        private

        def sole(request)
          stages = [request.executables, request.argv]
          stages.all? { _1.size == 1 } ? stages.map(&:first) : []
        end

        def trusted?(stage, name)
          stage.name == name && stage.wrappers.empty? && stage.anomalies.empty? &&
            self.class.placed?(stage, home: @home) && stage.run_files.none? { _1.fresh || _1.klass == :unresolved }
        end

        def asked?(subcommands, args)
          listed = subcommands.fetch(args.first, nil)
          listed && args.drop(1).select { _1.start_with?("-") }.all? { listed?(listed, _1) }
        end

        def listed?(listed, option)
          counted = option.sub(COUNT, "=")
          listed.include?(option) ? !option.end_with?("=") : listed.include?(counted)
        end

        def inside?(cwd, root) = cwd.nil? || Landing.under?(Profile.landing(cwd), Profile.landing(root))
      end
      private_constant :BuildGrant

      # A workspace profile with no masks and no programs, kept per landed root
      # and trace: building one asks git where its dirs are and which config
      # files it read, about 4 ms. It is rebuilt once any seal's path or config
      # file has appeared, gone, or changed, so a path made absent or present
      # between calls is never served stale, and nor is a hooks dir an
      # included file names; so is each path {Profile.watched} names, such as
      # a `target/` the last call made. At most {KEPT} roots are kept.
      class Sealed
        KEPT = 64
        CONFIG_ASKS = %w[config --list --show-origin -z].freeze
        INCLUDE = /\Ainclude(?:if\..*)?\.path\z/i
        Kept = Data.define(:profile, :configs, :stamp)
        # `globals` are where git looks for its global and system files; `origins` every file it read config
        # from. `named` adds each path an include names, active or not, which only a seal or a stamp needs.
        Configs = Data.define(:globals, :origins, :named, :includes) do
          def all = [*globals, *origins, *named].uniq

          # @param file [String] an origin
          # @param dir [String] absolute
          # @return [Boolean] whether an include chain that reaches `file` starts in a config file under `dir`
          def reached_from?(file, dir) = starts(file, []).any? { Landing.under?(_1, dir) }

          # The files no other one includes, from which `file` is reached; a file met again around a cycle
          # counts as one.
          def starts(file, seen)
            parents = includes.filter_map { |from, to| from if to == file && !seen.include?(from) }
            parents.empty? ? [file] : parents.flat_map { starts(_1, [*seen, file]) }
          end
        end
        Read = Data.define(:configs, :watched, :stamp)

        # @param home [String]
        # @param tmpdir [String]
        def initialize(home:, tmpdir:)
          @home = home
          @tmpdir = tmpdir
          @kept = {}
          @configs = {}
          @lock = Mutex.new
        end

        # The config files git reads for `root`, kept until one it reads or an include names changes, or the
        # env that names the global ones does.
        #
        # @param root [String]
        # @return [Configs]
        def configs(root)
          key = [Profile.landing(root), standard_configs(git_env)]
          @lock.synchronize do
            kept = @configs[key]
            return kept.configs if kept && kept.stamp == kept.watched.map { identity(_1) }

            @configs.clear if @configs.size >= KEPT
            (@configs[key] = read(*key)).configs
          end
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
          files = config_files(root).all
          profile = Profile.workspace(root:, home: @home, tmpdir: @tmpdir, trace:, configs: files)
          configs = [*files, *Profile.watched(root, @home)]
          Kept.new(profile:, configs:, stamp: stamp(profile, configs))
        end

        def read(root, globals)
          configs = config_files(root, globals)
          watched = configs.all
          Read.new(configs:, watched:, stamp: watched.map { identity(_1) })
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
        def config_files(root, globals = standard_configs(git_env))
          entries = read_configs(root).filter_map { |origin, entry| origin_entry(root, origin.to_s, entry.to_s) }
          Configs.new(globals:, origins: entries.map(&:first).uniq, named: entries.filter_map(&:last).uniq,
                      includes: entries.select(&:last).uniq)
        end

        def git_env = ENV.to_h.merge(Isolation::Worktree::GIT_CONTEXT_SCRUB)

        def read_configs(root)
          out, status = Open3.capture2(Isolation::Worktree::GIT_CONTEXT_SCRUB, "git", "-C", root, *CONFIG_ASKS,
                                       err: File::NULL)
          status.success? ? out.split("\0").each_slice(2).to_a : []
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

        # @return [Array(String, String), nil] the file an entry came from, and the path it includes, if any
        def origin_entry(root, origin, entry)
          return unless origin.start_with?("file:")

          file = File.expand_path(origin.delete_prefix("file:"), root)
          key, value = entry.split("\n", 2)
          [file, (File.expand_path(value, File.dirname(file)) if key.match?(INCLUDE) && value)]
        end
      end
      private_constant :Sealed
    end
  end
end
