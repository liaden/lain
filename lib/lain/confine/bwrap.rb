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
      # @param trace_fd [Integer] where strace writes, as the stage's own descriptor
      # @return [Shell::Term] `term` itself under a profile that neither confines nor traces
      def wrap(term, profile, trace_fd:)
        prefix = prefix(profile, trace_fd)
        return term if prefix.empty?

        Shell::Term.new(pipelines: term.pipelines.map do |pipeline|
          Shell::Term::Pipeline.new(stages: pipeline.stages.map do |stage|
            Shell::Term::Stage.new(argv: prefix + stage.argv, discards: stage.discards)
          end)
        end)
      end

      private

      def prefix(profile, trace_fd)
        return trace(profile, trace_fd) unless profile.confined?

        [*namespace(profile), *trace(profile, trace_fd), *fence(profile)]
      end

      def namespace(profile)
        [@bwrap, "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
         "--size", profile.tmpfs_bytes.to_s, "--tmpfs", "/tmp", "--unshare-pid", "--die-with-parent",
         *under_tmp(profile).flat_map { |dir| ["--ro-bind-try", dir, dir] },
         *profile.masks.flat_map { |mask| ["--ro-bind", "/dev/null", mask] }, "--"]
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

      def trace(profile, trace_fd)
        return [] unless profile.trace

        [@strace, "-f", "--seccomp-bpf", "-e", "trace=execve,execveat", "-o", "/dev/fd/#{trace_fd}", "--"]
      end

      def fence(profile)
        grants = { "--exec-dir" => profile.exec_dirs, "--exec-file" => profile.exec_files,
                   "--read-dir" => profile.read_dirs, "--write-dir" => profile.write_dirs }
        [@fence, *grants.flat_map { |flag, paths| paths.flat_map { [flag, _1] } }, "--"]
      end
    end
  end
end
