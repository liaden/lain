# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Lain
  module Confine
    # Chooses the `Confine::Profile` a call runs under. The ruling decides, never the
    # resolution: an approval by {Approval::ComposedTerm} rested on the call
    # only reading, so it runs under the reader profile. One that builds writes
    # its target dir, so with the workspace switch on it runs under the workspace
    # profile, and with the switch off it stays on the reader. With the workspace
    # switch on, an automatic allow by the judge, a rule or bypass runs under the
    # workspace profile, since no person saw the command. A plain allow of a
    # call that reads secrets, a surface's or an automatic rung's, runs
    # contained, under the workspace profile with the switch on and the
    # reader's with it off, and in a private network either way; a human's
    # may run the call's own project scripts, and a human's secrets answer
    # lifts the project's own masks and earns no build tool's ports. Any other
    # allow is traced and not confined: a human's that chose network, and a
    # surface's of a call that read no secret, whose machine answers stand
    # beside a person's in the same queue.
    #
    # A workspace call earns its build tool's ports, the grant profile, only
    # through {BuildGrant}: one fetching stage of a trusted program, while
    # nothing in the project is fresh. Freshness gates only the reader's exec,
    # and never a project script a human's plain approval vouches for: a
    # workspace program whose ctime moved mid-run still runs, and the tripwire
    # records it.
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

      # A contained call needs a private network, and this box cannot make one.
      class Uncontainable < Error
        attr_reader :profile

        # @param profile [Symbol] the profile the call would have run under
        def initialize(profile:)
          @profile = profile
          super("cannot give a contained #{profile} call a private network")
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

        # @return [MaskList::Related] none: with no policy, no directory outside the project is read
        def self.related = MaskList::Related::NONE
      end

      # The freshness a caller that read no lineage hands over: every root and
      # file counts as fresh, so nothing is granted its ports, nor a linter by name.
      module Unread
        # @param _root [String]
        # @return [true]
        def self.any_under?(_root) = true

        # @param _root [String]
        # @return [true]
        def self.changed_under?(_root) = true

        # @param _path [String]
        # @return [true]
        def self.fresh?(_path) = true

        # @param path [String]
        # @yieldparam path [String]
        # @return [Object] the block's value
        def self.making(path) = yield(path)
      end

      # What a parked call is told before its programs resolve: the first half of {BuildGrant#program}, read off
      # the argv alone. Trust and freshness can only withdraw a grant, so these ports bound what one may reach.
      #
      # @param argvs [Array<Array<String>>] each stage's argv on the term arm; none on the string arm
      # @return [Array<Integer>] the ports a contained workspace call of them could be granted, else none
      def self.grantable_ports(argvs)
        name = argvs.one? ? BuildGrant.asked(argvs.first) : nil
        name ? Profile::GRANTS.fetch(name) : []
      end

      # A secrets answer lifts only the masks the project's own listing put on files under it: a mask landing
      # outside the project, and one a scan put on a file an unmasked run wrote, stay.
      #
      # @param masks [Array<Sensitivity::Policy::Mask>] as {MaskList#masks} answers them
      # @param root [String] absolute; the project
      # @return [Array<String>] the resolved paths a secrets answer lets the call read
      def self.lifted(masks, root)
        project = Profile.landing(root)
        masks.reject { _1.reason == Sensitivity::Taint::REASON }.map(&:path)
             .select { _1 != project && Landing.under?(_1, project) }
      end

      # @param masks [Array<Sensitivity::Policy::Mask>] as {MaskList#masks} answers them
      # @param root [String] absolute; the call's own root
      # @return [Array<String>] what {.lifted} lifts, named from the root and sorted, as a row and a note list them
      def self.readable(masks, root)
        project = "#{Profile.landing(root).chomp(File::SEPARATOR)}#{File::SEPARATOR}"
        lifted(masks, root).map { _1.delete_prefix(project) }.sort
      end

      # @param masks [#masks] the session's {MaskList}, asked on every call so a
      #   mask whose file has gone never reaches bwrap, which fails on one
      # @param probe [#supports?] which sandbox layers this kernel offers
      # @param home [String] absolute; where the toolchain grants are looked for
      # @param root [String] absolute; the session's project, for a request that names no root of its own
      # @param workspace [Boolean] whether an automatic allow runs under the workspace profile
      # @param tmpdir [String] absolute; where each workspace call gets a dir of its own to write
      # @param fresh [#any_under?, #fresh?] the lineage's freshness, which a build tool's grant needs to be quiet
      #   and a linter's file must be
      # @param env [#[]] where a grant reads where bundler installs
      # @param classifier [#classify, #related] the session's policy on a path, asked before a git config file
      #   outside the project is granted, and the related directories a reader may read, each with its masks; by
      #   default every path is ordinary and none is related
      # @param registry [#backend] which backend mise fetches a short name through
      def initialize(masks:, probe:, home:, root:, workspace: false, tmpdir: Dir.tmpdir, fresh: Unread, env: ENV,
                     classifier: Unclassified, registry: MiseRegistry)
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
        @granting = Granting.over(fresh:, home:, root:, registry:)
      end

      # @param request [Request]
      # @return [Profile]
      # @raise [Overmasked] when a mask would empty a directory the reader or workspace profile grants
      # @raise [Profile::Unsealable] when a workspace seal is reached through a link inside the writes
      # @raise [NoTmpdir] when the TMPDIR cannot hold the workspace call's own dir
      # @raise [Profile::HomeTmpdir] when the TMPDIR a workspace call would write is home or holds it
      # @raise [Uncontainable] when a contained call needs a private network this box cannot make
      def for(request) = chosen(request, making: true) || (traceable? ? Profile::TRACED : Profile::NONE)

      # @param ruling [Approval::Escalation::Ruling]
      # @return [Boolean] whether {#for} would choose a confined profile for it, so a caller asks {#unrunnable} only
      #   of a request worth resolving
      def confines?(ruling) = (ruling.allow? && ruling.contained?) || workspace?(ruling) || composed?(ruling)

      # The same choice {#for} makes, without building the sandbox: no call dir is made, nor a build's target dir.
      #
      # @param request [Request] the request the run will carry, its grants included
      # @param executables [Enumerable<Shell::Executable>] every program the call is read to exec; the request's own
      #   by default
      # @return [Array<String>] the resolved programs that profile would not run; none for a ruling it does not confine
      # @raise [Overmasked, Uncontainable, Profile::Unsealable, Profile::HomeTmpdir, Profile::HoldsState,
      #   Profile::Tampered] as {#for} does
      def unrunnable(request, executables = request.executables)
        profile = chosen(request, making: false)
        return [] unless profile

        executables.flat_map(&:programs).filter_map(&:realpath).uniq.reject { profile.runs?(_1) }
      end

      private

      def chosen(request, making:)
        ruling = request.ruling
        return contained(request, making:) if ruling.allow? && ruling.contained?
        return workspace(request, making:) if workspace?(ruling)

        reader(request) if composed?(ruling)
      end

      def composed?(ruling) = ruling.allow? && ruling.rule == Approval::ComposedTerm.rule_name

      def workspace?(ruling)
        @workspace && ruling.allow? && !ruling.human? && WORKSPACE_RUNGS.include?(ruling.rung) &&
          (ruling.builds? || !composed?(ruling))
      end

      # Refused before a workspace call's dir is made. A build grant keeps its own ports, as {#networked} says,
      # except under a secrets answer, which reads the project's secrets only where the network is closed.
      def contained(request, making:)
        raise Uncontainable.new(profile: @workspace ? :workspace : :reader) unless @probe.supports?(:private_net)

        profile = @workspace ? workspace(request, making:) : reader(request).with(private_net: true)
        request.ruling.unmasked? ? profile.with(unmasked: true) : profile
      end

      def traceable? = @probe.supports?(:trace)

      def reader(request)
        root = root_of(request)
        masks = mask_paths(root, request)
        related = @classifier.related
        profile = Profile.reader(root:, home: @home, masks: [*masks, *related.masks.map(&:path)].uniq,
                                 related: [*related.roots, *related.reads], unread: related.refused,
                                 exec_files: [*exec_files(programs(request, masks, fresh_gates: true)),
                                              *linters(root, [*masks, *related.masks.map(&:path)])].uniq,
                                 trace: traceable?)
        granted(profile.with(read_dirs: [*profile.read_dirs, *git_configs(root)]))
      end

      # The call's dirs are made last, so a call refused on the way leaves none
      # behind, and never beneath the private /tmp, which is the call's own already.
      def workspace(request, making:)
        root = root_of(request)
        programmed = programmed(networked(ported(request)), request, root)
        related = @classifier.related
        lent = granted(lent(programmed, related))
        built_by_cargo(lent.read_dirs.first) if making
        profile = granted(lent.running(related.execs | ExecRules.project(root)))
        return profile if !making || Profile::SYSTEM_WRITE.include?(@tmpdir)

        housed(profile.for_call(call_dir, granted: @tmpdir))
      end

      # lain-fence grants only a dir that exists when it starts, so a first `cargo test` could not run what it
      # builds. cargo would make this same dir anyway; no other build output is made, since an empty
      # node_modules or .venv changes how npm and venv tools behave. A link there is left alone, and runs nothing.
      # The lineage makes it and journals that it did, so the dir withholds no build's grant, after a resume too.
      def built_by_cargo(project)
        target = File.join(project, "target")
        return if !File.file?(File.join(project, "Cargo.toml")) || File.symlink?(target) || File.exist?(target)

        @fresh.making(target) { Dir.mkdir(_1) }
      rescue SystemCallError
        nil
      end

      def programmed(ported, request, root)
        masks = mask_paths(root, request)
        programs = programs(request, masks, fresh_gates: false)
        linted = linters(root, [*masks, *@classifier.related.masks.map(&:path)])
        ported.with(masks:, exec_files: [*exec_files(programs), *linted].uniq,
                    exec_dirs: [*ported.exec_dirs, *install_bins(programs)].uniq,
                    read_dirs: [*ported.read_dirs, *git_configs(root)].uniq)
      end

      def lent(profile, related)
        reads = [*related.roots, *related.reads].map { Profile.landing(_1) }
        profile.with(masks: [*profile.masks, *related.masks.map(&:path)].uniq,
                     read_dirs: [*profile.read_dirs, *reads].uniq, unread: related.refused)
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

      # A bin dir is granted whole, its subdirs with it, so never one that holds a dir.
      def install_bins(programs)
        programs.filter_map { Profile.install_bin(_1.realpath, home: @home) }.uniq.select { flat?(_1) }
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
        program = @granting.build_grant_for(request) unless request.ruling.unmasked?
        program ? sealed.granting(program, home: @home, env: @env) : sealed
      end

      def call_dir
        Dir.mktmpdir(CALL_DIR, @tmpdir)
      rescue SystemCallError
        raise NoTmpdir.new(path: @tmpdir)
      end

      def root_of(request) = request.root || @root

      # A project config file git reads is shown to the call, sealed in a workspace call, since git cannot run
      # without it; every other mask stands, but those a secrets answer lifts.
      def mask_paths(root, request)
        masks = @masks.masks
        lifted = request.ruling.unmasked? ? self.class.lifted(masks, root) : []
        masks.map(&:path) - lifted - project_configs(root)
      end

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
      # On the string arm the one executable is the unresolved command, so a
      # reader runs what the grants name: Bash's own parse, which agrees with the
      # stages ComposedTerm read because its reading admits only literal commands.
      # A term-arm call carries no grants. A project script a human vouched for
      # is dropped under a mask as a guess is.
      def programs(request, masks, fresh_gates:)
        unmasked = [*placed(request.grants, fresh_gates:), *vouched(request)].reject { masked?(_1.realpath, masks) }
        [*placed(request.executables, fresh_gates:), *unmasked]
      end

      # Granted by file rather than by stage, since a hook or a compound command runs one no stage names, and as
      # the file alone, never its dir, so nothing beside a linter in a mise install runs with it. Read off the
      # host's PATH; a call whose own PATH finds another copy runs that one ungranted. Freshness gates every
      # profile here. A link that lands on a file of another name is refused, but a copy or hard link of any
      # static program under a linter's name is granted: it is the user's own file, old and shadowing nothing,
      # and it could run by its own name as a stage anyway. Every mask the profile will carry drops one, the
      # related dirs' included, since a mask over a granted file refuses the whole call.
      #
      # @return [Array<String>] the resolved linters the call may exec
      def linters(root, masks)
        resolver = Shell::Executable::Resolver.new(root:, fresh: @fresh, host_env: @env)
        found = resolver.for(WorkerEnv.new(cwd: root, env: {})).call(Shell::Term.of(*Profile::LINTERS.each_slice(1)))
        found.select { linter?(_1) }.map(&:realpath).reject { masked?(_1, masks) }
      end

      def linter?(found)
        BuildGrant.placed?(found, home: @home) && File.basename(found.realpath) == found.name &&
          Elf.static?(found.realpath)
      end

      # A human's approval reaches a profile only contained, so it vouches for the call's own project scripts,
      # one this lineage wrote included: the call has no network to send what they read.
      def vouched(request)
        return [] unless request.ruling.human?

        [*request.executables, *request.grants].flat_map(&:programs).select { _1.klass == :project && _1.realpath }
      end

      # A program the call resolved to outside /usr may run, unless the project
      # could have put it there: that is the plant the reader profile exists to
      # stop. Both arms ask the one placement test a build tool's grant does.
      def placed(executables, fresh_gates: true)
        executables.flat_map(&:programs).select do |program|
          grantable?(program) && BuildGrant.placed?(program, home: @home, fresh_gates:)
        end
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
                     "ls-remote" => %w[--quiet --heads --tags --refs] },
          "mise" => { "install" => [] }
        }.then { |table| Profile::GRANTS.keys.to_h { [_1, table.fetch(_1).freeze] } }.freeze

        # A short name, so no backend is named, at a version of digits: `latest`, a prefix or a ref resolves online.
        MISE_PIN = /\A[a-z0-9][a-z0-9_-]*@\d+(?:\.\d+)*\z/

        # @param fresh [#any_under?]
        # @param home [String] absolute
        # @param registry [#backend] which backend mise fetches a short name through
        def initialize(fresh:, home:, registry: MiseRegistry)
          @fresh = fresh
          @home = home
          @mise = MiseInstall.new(home:, registry:)
        end

        # ComposedTerm's test: a user program that shadows another of its name is how an old plant shows. A
        # program in a mise install is the toolchain, which is put ahead of /usr/bin and mise's shims on purpose.
        #
        # @param stage [Shell::Executable]
        # @param home [String] absolute; where the mise installs are
        # @param fresh_gates [Boolean] whether a program changed this lineage is refused
        # @return [Boolean]
        def self.placed?(stage, home:, fresh_gates: true)
          Profile::GRANTED_CLASSES.include?(stage.klass) && !stage.realpath.nil? && !(fresh_gates && stage.fresh) &&
            !(stage.klass == :user && stage.shadowed.any? && !Profile.install_bin(stage.realpath, home:))
        end

        # @param request [Request]
        # @param root [String]
        # @param vouched [Boolean] whether a human's vouch lifts the lineage's unread mark under `root`
        # @return [String, nil] a key of `Confine::Profile::GRANTS`
        def program(request, root, vouched: false)
          stage, argv = sole(request)
          name = argv && self.class.asked(argv)
          return unless name && trusted?(stage, name) && inside?(request.cwd, root)
          return if vouched ? @fresh.changed_under?(root) : @fresh.any_under?(root)

          name if mise_admits?(name, stage, argv, request.cwd, root)
        end

        # @param argv [Array<String>]
        # @return [String, nil] the build tool whose lists take this subcommand and every option, else nil
        def self.asked(argv)
          name = argv.first
          subcommands = OPTIONS.fetch(name, nil)
          listed = subcommands&.fetch(argv[1], nil)
          name if listed && argv.drop(2).select { _1.start_with?("-") }.all? { listed?(listed, _1) } &&
                  operands?(name, argv.drop(2))
        end

        # mise takes one tool at one version and nothing after it, since `--` hands the rest to the install.
        def self.operands?(name, words) = name != "mise" || (words.one? && MISE_PIN.match?(words.first))
        private_class_method :operands?

        def self.listed?(listed, option)
          counted = option.sub(COUNT, "=")
          listed.include?(option) ? !option.end_with?("=") : listed.include?(counted)
        end
        private_class_method :listed?

        private

        def sole(request)
          stages = [request.executables, request.argv]
          stages.all? { _1.size == 1 } ? stages.map(&:first) : []
        end

        def trusted?(stage, name)
          stage.name == name && stage.wrappers.empty? && stage.anomalies.empty? &&
            self.class.placed?(stage, home: @home) && stage.run_files.none? { _1.fresh || _1.klass == :unresolved }
        end

        def inside?(cwd, root) = cwd.nil? || Landing.under?(Profile.landing(cwd), Profile.landing(root))

        # Asked last, since it may ask mise itself.
        def mise_admits?(name, stage, argv, cwd, root)
          name != "mise" || @mise.admits?(stage.realpath, argv.last, cwd:, root:)
        end
      end

      # What lain, never mise, decides of a mise install: the binary is the box's mise, the call starts at the
      # root, since mise reads a config in each dir from its cwd up, the root's path holds no separator that would
      # split mise's list of ignored roots, the project pins that tool at that version, and the backend the name
      # resolves through fetches a prebuilt release.
      class MiseInstall
        PREBUILT = /\A(?:aqua|ubi|github):/
        # Core tools that download a build; the rest, ruby and python among them, may compile.
        CORE_PREBUILT = %w[bun deno go java node zig].map { "core:#{_1}" }.freeze

        # @param home [String] absolute
        # @param registry [#backend]
        def initialize(home:, registry:)
          @home = home
          @registry = registry
        end

        # @param mise [String] the resolved program
        # @param word [String] `name@version`
        # @param cwd [String, nil]
        # @param root [String]
        # @return [Boolean]
        def admits?(mise, word, cwd:, root:)
          tool, version = word.split("@", 2)
          project = Profile.landing(root)
          Profile.mise_binaries(@home).include?(mise) && (cwd.nil? || Profile.landing(cwd) == project) &&
            !project.include?(File::PATH_SEPARATOR) && MisePins.of(project).include?([tool, version]) &&
            prebuilt?(@registry.backend(mise:, name: tool, root:))
        end

        private

        def prebuilt?(backend) = backend.is_a?(String) && (PREBUILT.match?(backend) || CORE_PREBUILT.include?(backend))
      end

      # The tool versions a project pins, read by lain's own TOML parser from the config files mise would read at
      # the root. A config that does not parse pins nothing.
      module MisePins
        CONFIGS = Profile::PROJECT_SEALED.grep(/mise/).freeze
        TOOL_VERSIONS = ".tool-versions"

        # @param project [String] absolute, landed
        # @return [Array<Array(String, String)>] each pinned tool and version
        def self.of(project)
          [*CONFIGS.flat_map { toml(File.join(project, _1)) }, *tool_versions(File.join(project, TOOL_VERSIONS))]
        end

        def self.toml(path)
          tools = Ext::Toml.parse(File.read(path)).fetch("tools", nil)
          tools.is_a?(Hash) ? tools.flat_map { |name, spec| versions(spec).map { [name, _1] } } : []
        rescue SystemCallError, Ext::Toml::Invalid
          []
        end

        def self.versions(spec)
          case spec
          when String then [spec]
          when Array then spec.flat_map { versions(_1) }
          when Hash then versions(spec["version"])
          else []
          end
        end

        def self.tool_versions(path)
          File.readlines(path, chomp: true).flat_map do |line|
            name, *versions = line.sub(/#.*/, "").split
            versions.map { [name, _1] }
          end
        rescue SystemCallError
          []
        end
        private_class_method :toml, :versions, :tool_versions
      end

      # Asks the box's mise which backend a short name resolves through, under the env a granted install runs
      # with, so the project's config cannot rename it.
      module MiseRegistry
        TIMEOUT = 5

        # @param mise [String] the resolved program
        # @param name [String]
        # @param root [String]
        # @param timeout [Numeric] seconds before mise is killed and nothing is answered
        # @return [String, nil] the first backend mise lists, nil where it lists none or does not answer
        def self.backend(mise:, name:, root:, timeout: TIMEOUT)
          env = Profile.mise_env([Profile.landing(root)], ENV.keys)
          out = Shell::Out.new(mise, "registry", name, environment: env, cwd: root, timeout:).run_command
          out.stdout.split.first if Shell::Out.ok?(out)
        rescue Shell::Out::Timeout, SystemCallError
          nil
        end
      end

      Granting = Data.define(:grant, :root) do
        # @param fresh [#any_under?, #changed_under?] the lineage's freshness
        # @param home [String] absolute
        # @param root [String] absolute
        # @param registry [#backend] which backend mise fetches a short name through
        # @return [Granting]
        def self.over(fresh:, home:, root:, registry: MiseRegistry)
          new(grant: BuildGrant.new(fresh:, home:, registry:), root:)
        end

        # @param request [Request]
        # @param vouched [Boolean] whether to answer as if a human had vouched for the lineage's unread command
        # @return [String, nil] a key of `Confine::Profile::GRANTS`
        def build_grant_for(request, vouched: false) = grant.program(request, request.root || root, vouched:)

        # @param argvs [Array<Array<String>>] each stage's words, as {Tools::Bash#planned_argvs} reads them
        # @return [Boolean] whether the words alone ask for a build a grant could cover, before anything resolves
        def asks?(argvs) = argvs.one? && !BuildGrant.asked(argvs.first).nil?
      end

      # The one answer to whether a build gets its tool's ports, at the root a request names or the session's.
      # The sandbox asks it as a call runs, and a layer ahead of the gate asks it over the same lineage.
      #
      # @!attribute [r] grant
      #   @return [BuildGrant]
      # @!attribute [r] root
      #   @return [String] absolute; the session's project, for a request that names no root of its own
      class Granting
        # A session whose sandbox grants no build its ports: no workspace sandbox wraps its bash.
        module NONE
          # @return [nil]
          def self.root = nil

          # @param _request [Request]
          # @return [nil]
          def self.build_grant_for(_request, **) = nil

          # @param _argvs [Array<Array<String>>]
          # @return [false]
          def self.asks?(_argvs) = false
        end
      end

      # A workspace profile with no masks and no programs, kept per landed root
      # and trace: building one asks git where its dirs are and which config
      # files it read, about 4 ms. It is rebuilt once any seal's path or config
      # file has appeared, gone, or changed, so a path made absent or present
      # between calls is never served stale, and nor is a hooks dir an
      # included file names; so is each path `Confine::Profile.watched` names, such as
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
          # A kept rule dir could have become a link since, so {Profiles} adds them per call.
          profile = Profile.workspace(root:, home: @home, tmpdir: @tmpdir, trace:, configs: files,
                                      execs: ExecRules::NONE)
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

        # A clone lain cut whose git dir was tampered with is one lain runs no git in, this read included.
        def read_configs(root)
          return [] unless Isolation::Clone::Guard.refusal(root).empty?

          out, status = Open3.capture2(Isolation::Worktree::GIT_SPAWN_ENV, "git", "-C", root, *CONFIG_ASKS,
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
