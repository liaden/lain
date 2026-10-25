# frozen_string_literal: true

require "pathname"

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

      # @param env [Hash] where CARGO_TARGET_DIR is read from, see {Paths::Shipped.cargo_target}
      # @return [String] where `rake compile` writes the fence
      def self.fence_binary(env: ENV) = File.join(Paths::Shipped.cargo_target(env:), "release", "lain-fence")

      # @param fence [String] the lain-fence binary
      # @param bwrap [String]
      # @param strace [String]
      def initialize(fence:, bwrap: "/usr/bin/bwrap", strace: "/usr/bin/strace")
        @fence = fence
        @bwrap = bwrap
        @strace = strace
        @seal_binds = SealBinds.new
      end

      # @param term [Shell::Term]
      # @param profile [Profile]
      # @param trace_fd [Integer] the first stage's trace descriptor; stage i,
      #   counted across every pipeline, writes to `trace_fd + i`
      # @return [Shell::Term]
      def wrap(term, profile, trace_fd:)
        stage_fds = (trace_fd..).each
        Shell::Term.new(pipelines: term.pipelines.map do |pipeline|
          Shell::Term::Pipeline.new(stages: pipeline.stages.map do |stage|
            Shell::Term::Stage.new(argv: prefix(profile, stage_fds.next) + stage.argv, discards: stage.discards)
          end)
        end)
      end

      private

      def prefix(profile, own)
        return [*trace(profile, own), @fence, "--reap-only", "--"] unless profile.confined?

        [*namespace(profile), *trace(profile, own), *fence(profile)]
      end

      def namespace(profile)
        [@bwrap, "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
         "--size", profile.tmpfs_bytes.to_s, "--tmpfs", "/tmp", "--unshare-pid", "--die-with-parent",
         *under_tmp(profile).flat_map { |dir| ["--ro-bind-try", dir, dir] },
         *writable(profile).flat_map { |dir| ["--bind-try", dir, dir] },
         *@seal_binds.for(profile.sealed, writable(profile)),
         *masking(profile.masks), "--"]
      end

      # The fence decides what may be written; this only lifts bwrap's
      # read-only root from the grants that live outside its own /tmp.
      def writable(profile) = profile.write_dirs - Profile::SYSTEM_WRITE

      # The kind is read here, the last moment before bwrap binds, because a
      # mask list keeps a path, not what it was when judged. bwrap cannot bind
      # /dev/null over a directory, so a directory gets an empty read-only
      # tmpfs. A mask inside a masked directory is left out: bwrap cannot bind
      # into the read-only tmpfs, and on a writable one the bind would put the
      # name back.
      def masking(masks)
        dirs = masks.select { File.directory?(_1) }
        masks.reject { |mask| dirs.any? { mask != _1 && Landing.under?(mask, _1) } }.flat_map do |mask|
          dirs.include?(mask) ? ["--tmpfs", mask, "--remount-ro", mask] : ["--ro-bind", "/dev/null", mask]
        end
      end

      # The private /tmp hides whatever the host had there, a project or a
      # granted program included; a project that is /tmp itself takes the host's
      # /tmp back whole. `-try`, because a grant that does not exist must cost
      # nothing, as it does in the fence, rather than abort bwrap.
      def under_tmp(profile)
        project = profile.read_dirs.first
        [*(project == "/tmp" ? [project] : []),
         *(profile.read_dirs + profile.exec_files).select { _1.start_with?("/tmp/") }].uniq
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
        [@fence, *grants.flat_map { |flag, values| values.flat_map { [flag, _1.to_s] } }, "--"]
      end

      # The binds that keep a workspace's seals in place: each directory
      # between a write and a seal bound over itself, then each present seal
      # read-only. Walking each seal's path costs about 0.5 ms a call, so the
      # binds are kept per seal set and the writes that hold a seal. The set
      # is the value {Profiles} rebuilds once a seal's path changes on disk, so
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

        private

        def built(sealed, writes)
          [*pinned(sealed, writes).flat_map { |dir| ["--bind-try", dir, dir] },
           *sealed.reject(&:absent).flat_map { ["--ro-bind", _1.path, _1.path] }]
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
