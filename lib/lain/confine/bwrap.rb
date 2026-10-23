# frozen_string_literal: true

module Lain
  module Confine
    # Prefixes each stage with bwrap, then strace, then lain-fence. bwrap is
    # outermost because the fence opens its paths inside bwrap's namespace;
    # strace sits inside bwrap, where its cost simply adds. Each stage gets its
    # own stack, so the pipeline still wires its stages together. The reader is
    # given no --connect-port, so the fence refuses all of its TCP.
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
      end

      # @param term [Shell::Term]
      # @param profile [Profile]
      # @param trace_fd [Integer] the first stage's trace descriptor; stage i,
      #   counted across every pipeline, writes to `trace_fd + i`
      # @return [Shell::Term] `term` itself under a profile that neither confines nor traces
      def wrap(term, profile, trace_fd:)
        return term unless profile.trace || profile.confined?

        fds = (trace_fd...(trace_fd + term.stages.size)).to_a
        stage_fds = fds.each
        Shell::Term.new(pipelines: term.pipelines.map do |pipeline|
          Shell::Term::Pipeline.new(stages: pipeline.stages.map do |stage|
            Shell::Term::Stage.new(argv: prefix(profile, stage_fds.next, fds) + stage.argv, discards: stage.discards)
          end)
        end)
      end

      private

      def prefix(profile, own, fds)
        return trace(profile, own, fds) unless profile.confined?

        [*namespace(profile), *trace(profile, own, fds), *fence(profile)]
      end

      def namespace(profile)
        [@bwrap, "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
         "--size", profile.tmpfs_bytes.to_s, "--tmpfs", "/tmp", "--unshare-pid", "--die-with-parent",
         *under_tmp(profile).flat_map { |dir| ["--ro-bind-try", dir, dir] },
         *masking(profile.masks), "--"]
      end

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
      # under -D and the tracee keeps running once the reader has closed.
      def trace(profile, own, fds)
        return [] unless profile.trace

        [@strace, "-DD", "-f", "-s", STRING_BYTES.to_s, "--seccomp-bpf", "-e", "trace=execve,execveat",
         "-o", "/dev/fd/#{own}", "--", *closing(profile, fds)]
      end

      # The fence closes every descriptor above 2 in a confined call. Nothing
      # does in a traced one, and a command holding a trace descriptor could
      # write exec lines of its own into the record, or a partial line that
      # swallows the next real one.
      def closing(profile, fds)
        profile.confined? ? [] : [Exec::Local::SHELL, "-c", ['exec "$@"', *closed(fds)].join(" "), "sh"]
      end

      def closed(fds) = fds.map { "#{_1}>&-" }

      def fence(profile)
        grants = { "--exec-dir" => profile.exec_dirs, "--exec-file" => profile.exec_files,
                   "--read-dir" => profile.read_dirs, "--write-dir" => profile.write_dirs }
        [@fence, *grants.flat_map { |flag, paths| paths.flat_map { [flag, _1] } }, "--"]
      end
    end
  end
end
