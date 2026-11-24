# frozen_string_literal: true

require "pathname"
require "tempfile"

module Lain
  module Confine
    # Prefixes each stage with bwrap, then strace, then lain-fence. bwrap is
    # outermost because the fence opens its paths inside bwrap's namespace;
    # strace sits inside bwrap, where its cost simply adds. Each stage gets its
    # own stack, so the pipeline still wires its stages together. The reader is
    # given no --connect-port, so the fence refuses all of its TCP.
    #
    # An unconfined profile has no bwrap, whose pid namespace is what ends a
    # reader's processes with the call, so its fence runs as a reaper only: a
    # stop kills every descendant, a setsid one included, and a normal exit
    # leaves background children running.
    class Bwrap
      include Launcher

      STRING_BYTES = 256
      HOST_TMP = "/tmp"
      RUN = "/run"
      # Holds only the mount points of what a profile grants.
      RUN_BYTES = 1024 * 1024

      # @param env [Hash] where CARGO_TARGET_DIR is read from, see {Paths::Shipped.cargo_target}
      # @return [String] where `rake compile` writes the fence
      def self.fence_binary(env: ENV) = File.join(Paths::Shipped.cargo_target(env:), "release", "lain-fence")

      # The one place bwrap is found, so a probe never tries a different binary from the one a call runs.
      #
      # @param fence [String] the lain-fence binary
      # @param env [Hash] where PATH is read from
      # @return [Bwrap] with bwrap and strace resolved on PATH, nil where absent
      def self.on_path(fence:, env: ENV)
        path = env.fetch("PATH", "")
        new(fence:, bwrap: Shell::Path.find("bwrap", path:), strace: Shell::Path.find("strace", path:),
            runtime_dir: Paths.new(env:).runtime_dir)
      end

      # @return [String, nil] the bwrap a call runs under, nil when PATH has none
      attr_reader :bwrap

      # @return [String, nil] the strace a traced call runs under, nil when PATH has none
      attr_reader :strace

      # @param fence [String] the lain-fence binary
      # @param bwrap [String, nil]
      # @param strace [String, nil]
      # @param decoys [Decoys] what a masked file reads as
      # @param runtime_dir [String] lain's folder in the runtime directory, which is hidden from every call
      def initialize(fence:, bwrap: "/usr/bin/bwrap", strace: "/usr/bin/strace", decoys: Decoys.new,
                     runtime_dir: Paths.new.runtime_dir)
        @fence = fence
        @bwrap = bwrap
        @strace = strace
        @decoys = decoys
        @seal_binds = SealBinds.new
        @runtime_dir = runtime_dir
        @runtime_root = runtime_root_of(runtime_dir)
      end

      # The kind is read here, the last moment before bwrap binds, because a
      # mask list keeps a path, not what it was when judged; a hidden path is
      # kept only while it is there, since bwrap aborts on a mount at nothing.
      # A directory gets an empty read-only tmpfs. A mask inside a masked
      # directory is left out: bwrap cannot bind into the read-only tmpfs.
      #
      # @param profile [Profile]
      # @return [Masked] each mask, with the bytes a file reads as or nil for a directory
      def masked(profile)
        masks = [*profile.masks, *profile.hidden.select { File.exist?(_1) }]
        dirs = masks.select { File.directory?(_1) }
        kept = masks.reject { |mask| dirs.any? { mask != _1 && Landing.under?(mask, _1) } }
        files = kept - dirs
        Masked.new(entries: [*kept, *@decoys.partners(files)].map { [_1, shown(_1, dirs, files)].freeze }.freeze,
                   own_tmp: profile.read_dirs.first != HOST_TMP)
      end

      # @param term [Shell::Term]
      # @param profile [Profile]
      # @param trace_fd [Integer] the first stage's trace descriptor; stage i,
      #   counted across every pipeline, writes to `trace_fd + i`
      # @param bound [Bound] the profile's masks, bound for every stage of the term
      # @return [Shell::Term]
      def wrap(term, profile, trace_fd:, bound:)
        stages = (0..).each
        Shell::Term.new(pipelines: term.pipelines.map do |pipeline|
          Shell::Term::Pipeline.new(stages: pipeline.stages.map do |stage|
            index = stages.next
            Shell::Term::Stage.new(argv: prefix(profile, trace_fd + index, bound.argv(index)) + stage.argv,
                                   discards: stage.discards)
          end)
        end)
      end

      # @param private_net [Boolean]
      # @return [Array<String>] the bwrap argv a confined call runs under, through its closing "--"
      def namespace_argv(private_net:) = namespace(Profile.new(name: :reader, trace: false, private_net:), [])

      private

      # With no XDG_RUNTIME_DIR the parent is /tmp, shared with everything else, so only lain's folder is hidden.
      def runtime_root_of(dir) = [HOST_TMP, File::SEPARATOR].include?(File.dirname(dir)) ? dir : File.dirname(dir)

      def shown(mask, dirs, files) = (@decoys.bytes_for(mask, masks: files) unless dirs.include?(mask))

      def prefix(profile, own, masking)
        return [*trace(profile, own), @fence, "--reap-only", "--"] unless profile.confined?

        [*namespace(profile, masking), *trace(profile, own), *fence(profile)]
      end

      # Landlock below ABI 9 cannot refuse a Unix connect, so /run and lain's runtime directory are left out of the
      # call's view. /run turns read-only last, because bwrap cannot make a later bind's mount point in a read-only
      # tmpfs.
      def namespace(profile, masking)
        runtime = runtime_mask(profile)
        [@bwrap, "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
         "--size", profile.tmpfs_bytes.to_s, "--tmpfs", "/tmp", *private_run, *runtime.before,
         "--unshare-pid", "--die-with-parent",
         *("--unshare-net" if profile.private_net),
         *under_tmp(profile).flat_map { |dir| ["--ro-bind-try", dir, dir] },
         *under_run(profile).flat_map { |path| ["--ro-bind-try", path, path] },
         *writable(profile).flat_map { |dir| ["--bind-try", dir, dir] },
         *profile.homes.flat_map { housing(_1, profile) },
         *@seal_binds.for(profile.sealed, writable(profile)),
         *masking, *runtime.after, *sealed_run, "--"]
      end

      # bwrap aborts on a mount at a target a read-only root does not have.
      def private_run = File.directory?(RUN) ? ["--size", RUN_BYTES.to_s, "--tmpfs", RUN] : []

      def sealed_run = File.directory?(RUN) ? ["--remount-ro", RUN] : []

      def under_run(profile)
        [*profile.read_dirs, *profile.exec_dirs, *profile.exec_files, *profile.unix_dirs]
          .map { Pathname(_1).cleanpath.to_s }
          .select { _1.start_with?("#{RUN}/", "#{@runtime_root}/") }.uniq
          .reject { refused_grant?(_1) }
      end

      # A bind follows links at its source, so a grant is judged by where it lands as well as how it is spelled.
      def refused_grant?(path)
        spelled = Pathname(path).cleanpath.to_s
        landed = landing_of(spelled)
        runtime = landing_of(@runtime_root)
        landed == runtime || Landing.under?(RUN, landed) ||
          [RUN, runtime].any? { Landing.under?(landed, _1) && !Landing.under?(spelled, _1) }
      end

      def landing_of(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      # A mask made before the binds lets a grant inside it come back; one a wider bind would undo goes after them.
      def runtime_mask(profile)
        return RuntimeMask.none unless File.directory?(@runtime_root)

        covered = shown_binds(profile).any? { Landing.under?(@runtime_root, _1) }
        return RuntimeMask.none unless covered || [HOST_TMP, RUN].none? { Landing.under?(@runtime_root, _1) }

        RuntimeMask.new(dir: @runtime_root, late: covered)
      end

      def shown_binds(profile)
        writes = writable(profile)
        [*under_tmp(profile), *under_run(profile), *writes, *@seal_binds.shown(profile.sealed, writes)]
      end

      # The fence decides what may be written; this only lifts bwrap's
      # read-only root from the grants that live outside its own /tmp. A
      # private home is written only through its own mount, never the user's.
      def writable(profile)
        homes = profile.homes.map(&:path)
        (profile.write_dirs - Profile::SYSTEM_WRITE)
          .reject { |dir| homes.any? { Landing.under?(dir, _1) } || refused_grant?(dir) }
      end

      # A call whose TMPDIR is the private /tmp has no dir of its own on the
      # host, so its home is a tmpfs, and lain's files go unwritten.
      def housing(home, profile)
        mount = if profile.call_tmpdir
                  ["--bind", home.source(profile.call_tmpdir), home.path]
                else
                  ["--size", profile.tmpfs_bytes.to_s, "--tmpfs", home.path]
                end
        [*mount, *home.reads.flat_map { back("--ro-bind-try", home, _1) },
         *home.writes.flat_map { back("--bind-try", home, _1) }]
      end

      def back(flag, home, name) = File.join(home.path, name).then { [flag, _1, _1] }

      # The private /tmp hides whatever the host had there, a project or a
      # granted program included; a project that is /tmp itself takes the host's
      # /tmp back whole. `-try`, because a grant that does not exist must cost
      # nothing, as it does in the fence, rather than abort bwrap.
      def under_tmp(profile)
        project = profile.read_dirs.first
        granted = (profile.read_dirs + profile.exec_files).select { _1.start_with?("/tmp/") }
        [*(project == "/tmp" ? [project] : []), *granted].uniq.reject { refused_grant?(_1) }
      end

      # `-DD` puts the tracer in a process group of its own, as the tracee's
      # grandchild: the call ends when its command does rather than when every
      # process it left behind has, and the call's group kill never reaches the
      # tracer, which follows a background child until it exits. `-s` keeps a
      # long path or argv0 from being cut at strace's default of 32 bytes. The
      # tracer writes to the descriptor itself: a `|cmd` relay can lose its
      # tracer at start under load, and a seccomp tracer that exits kills its
      # tracees. A direct write outlives the call, since strace ignores SIGPIPE
      # under -D and the tracee keeps running once the reader has closed. The
      # fence after it closes every descriptor above stderr, so the command
      # cannot write exec lines of its own into the record.
      def trace(profile, own)
        return [] unless profile.trace

        [@strace, "-DD", "-f", "-s", STRING_BYTES.to_s, "--seccomp-bpf", "-e",
         "trace=execve,execveat,connect,sendto,sendmsg,sendmmsg", "-o", "/dev/fd/#{own}", "--"]
      end

      def fence(profile)
        grants = { "--exec-dir" => profile.exec_dirs, "--exec-file" => profile.exec_files,
                   "--read-dir" => profile.read_dirs, "--write-dir" => profile.write_dirs,
                   "--connect-port" => profile.connect_ports, "--unix-dir" => profile.unix_dirs }
        [@fence, *("--private-net" if profile.private_net),
         *grants.flat_map { |flag, values| values.flat_map { [flag, _1.to_s] } }, "--"]
      end

      RuntimeMask = Data.define(:dir, :late) do
        # @return [RuntimeMask] one that mounts nothing
        def self.none = new(dir: nil, late: false)

        # @return [Array<String>] the flags that go before the binds
        def before = dir && !late ? ["--tmpfs", dir] : []

        # @return [Array<String>] the flags that go after the binds
        def after
          return [] unless dir

          [*(["--tmpfs", dir] if late), "--remount-ro", dir]
        end
      end

      # A call's masks, read for their kind and bytes.
      # `own_tmp` is false where the project is /tmp itself: the host's /tmp is then bound back read-only over
      # the call's own, and bwrap could not make another file there.
      Masked = Data.define(:entries, :own_tmp) do
        # @return [Hash{String => String}] each masked file and the bytes it reads as
        def files = entries.reject { _2.nil? }.to_h

        # @param stages [Integer] how many stages the term runs
        # @param first_fd [Integer] the first descriptor free after every stage's trace
        # @param also [Hash{String => String}] more files to bind as data under /tmp, after the masks
        # @return [Bound]
        def bind(stages:, first_fd:, also: {}) = Bound.new([*entries, *(also if own_tmp)], stages:, first_fd:)
      end

      # Every mask bound from a descriptor, never a path: bwrap follows a link
      # at a source, so a link planted there would read any host file at a
      # project path. bwrap reads each descriptor to its end and closes it,
      # so every mask of every stage gets its own. Mode 0400 keeps an empty file bound
      # over a hidden program from running as an empty script. Each stage
      # inherits every stage's descriptors, as it does the traces, and the
      # fence closes all of them above stderr before the command runs.
      class Bound
        # @param entries [Array<Array(String, String, nil)>] each path, with its bytes or nil for a directory
        # @param stages [Integer]
        # @param first_fd [Integer]
        def initialize(entries, stages:, first_fd:)
          @opened = []
          @fds = {}
          sources = entries.map { |path, bytes| [path, bytes && readers(bytes, stages)] }
          numbers = (first_fd..).each
          @argv = Array.new(stages) do |stage|
            sources.flat_map do |path, readers|
              readers ? data(numbers.next, readers.fetch(stage), path) : ["--tmpfs", path, "--remount-ro", path]
            end
          end
          @empty = entries.empty?
        rescue StandardError
          close
          raise
        end

        # @return [Hash{Integer => IO}] what the spawn hands each stage, at its descriptor
        attr_reader :fds

        # @param stage [Integer] counted across every pipeline
        # @return [Array<String>] the stage's mask flags
        def argv(stage) = @empty ? [] : @argv.fetch(stage)

        # @return [void]
        def close = @opened.each { _1.close unless _1.closed? }

        private

        def data(number, reader, path)
          @fds[number] = reader
          ["--perms", "0400", "--ro-bind-data", number.to_s, path]
        end

        # One reader per stage, each with its own offset, from a file removed once they are open: no writer
        # outlives the spawn, and the bytes may be any size, as an attributes file over many masks can be.
        # Reopened through the descriptor it was written by, never its path, which a link could replace.
        def readers(bytes, stages)
          return Array.new(stages) { opened(File::NULL) } if bytes.empty?

          Tempfile.create("lain-mask", binmode: true) do |file|
            file.write(bytes)
            file.flush
            Array.new(stages) { opened("/proc/self/fd/#{file.fileno}") }
          end
        end

        def opened(path) = File.new(path, "rb").tap { @opened << _1 }
      end

      # The binds that keep a workspace's seals in place: each directory
      # between a write and a seal bound over itself, then each present seal
      # read-only. Walking each seal's path costs about 0.5 ms a call, so the
      # binds are kept per seal set and the writes that hold a seal. The set
      # is the value `Confine::Profiles` rebuilds once a seal's path changes on disk, so
      # a changed set, root or holding write is a new key, never a stale bind.
      class SealBinds
        KEPT = 64

        def initialize
          @kept = {}
          @lock = Mutex.new
        end

        # @param sealed [Array<Profile::Seal>]
        # @param writes [Array<String>] what bwrap binds writable
        # @return [Array<String>] the bind flags, frozen
        def for(sealed, writes)
          key = [sealed, holding(writes, sealed)]
          @lock.synchronize do
            @kept.clear if @kept.size >= KEPT
            @kept[key] ||= Ractor.make_shareable(built(*key))
          end
        end

        # @param sealed [Array<Profile::Seal>]
        # @param writes [Array<String>] what bwrap binds writable
        # @return [Array<String>] each seal bwrap binds
        def shown(sealed, writes) = sealed.reject(&:absent).map(&:path).select { in_view?(_1, writes) }

        private

        def built(sealed, writes)
          [*pinned(sealed, writes).flat_map { |dir| ["--bind-try", dir, dir] },
           *shown(sealed, writes).flat_map { ["--ro-bind", _1, _1] }]
        end

        # A bind would bring the host's path into a private mount, sockets included, and no write there needs sealing.
        # One that holds a private mount would replace it whole.
        def in_view?(path, writes)
          return false if [HOST_TMP, RUN].any? { Landing.under?(_1, path) }

          [HOST_TMP, RUN].none? { Landing.under?(path, _1) } || writes.any? { Landing.under?(path, _1) }
        end

        # A write that holds no seal has no directory between it and one.
        def holding(writes, sealed) = writes.select { |write| sealed.any? { Landing.under?(_1.path, write) } }

        # A mount point cannot be renamed, so each directory between a write and
        # a seal is bound over itself: renaming one would carry the seal away and
        # leave its name free to plant.
        def pinned(sealed, writes) = sealed.flat_map { between(writes, _1.path) }.uniq - writes

        def between(writes, path)
          write = writes.select { Landing.under?(path, _1) }.max_by(&:size)
          return [] unless write

          Pathname(path).relative_path_from(write).descend.map { File.join(write, _1.to_s) }[0...-1]
        end
      end
    end
  end
end
