# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Exec
    # The in-process backend: a command runs as a child of THIS process, under
    # this process's uid, filesystem and network.
    #
    # It owns BOTH in-process arms, and that is the point rather than an
    # accident of extraction: a String reaches `sh -c` through
    # `Mixlib::ShellOut`, a TERM reaches `execvp` through {Shell::Pipeline}, and
    # {Exec.child_env} is applied in one place above them. Split across the two
    # arms it would be two scrubs that happen to agree today -- the same reason
    # {Tools::Bash.render_output} is one rendering rather than one per arm.
    class Local
      # @param shell_out_factory [#call] builds the `Mixlib::ShellOut`-shaped
      #   object the string arm runs through; substituting it is what lets a
      #   spec pin a shorter TERM->KILL grace without giving up the real
      #   process-group kill
      # @param pipeline [#call] runs the term arm's argv-array pipeline; the
      #   string arm never touches it
      def initialize(shell_out_factory: Mixlib::ShellOut.public_method(:new), pipeline: Shell::Pipeline.new)
        @shell_out_factory = shell_out_factory
        @pipeline = pipeline
        freeze
      end

      # @param command [String, Array<Array<String>>] a shell command string, or
      #   a TERM -- an Array of argv Arrays, which never reaches a shell
      # @param cwd [String] already resolved by the caller ({WorkerEnv#resolve})
      # @param env [Hash] the caller's overrides, before the framework scrub
      # @param timeout [Numeric] seconds before the process group is killed
      # @param stdout_sink [#<<] where stdout bytes are pumped as they arrive
      # @param stderr_sink [#<<] where stderr bytes are pumped as they arrive
      # @return [Capture] what ran, whatever its exit status
      # @raise [Timeout] when the deadline passed and the group was killed
      def call(command:, cwd:, env:, timeout:, stdout_sink: Sink::Null.new, stderr_sink: Sink::Null.new)
        child = Exec.child_env(env)
        if command.is_a?(String)
          shell(command, cwd:, env: child, timeout:, stdout_sink:, stderr_sink:)
        else
          pipe(command, cwd:, env: child, timeout:, stdout_sink:, stderr_sink:)
        end
      end

      private

      def shell(command, cwd:, env:, timeout:, stdout_sink:, stderr_sink:)
        shell_out = @shell_out_factory.call(command, cwd:, environment: env, timeout:,
                                                     live_stdout: stdout_sink, live_stderr: stderr_sink)
        shell_out.run_command
        Capture.new(exit_status: shell_out.exitstatus, stdout: shell_out.stdout, stderr: shell_out.stderr)
      rescue Mixlib::ShellOut::CommandTimeout => e
        raise Timeout, e.message
      end

      def pipe(term, cwd:, env:, timeout:, stdout_sink:, stderr_sink:)
        result = @pipeline.call(term, cwd:, env:, timeout:, stdout_sink:, stderr_sink:)
        Capture.new(exit_status: result.exit_status, stdout: result.stdout, stderr: result.stderr)
      rescue Shell::Pipeline::Timeout => e
        raise Timeout, e.message
      end
    end
  end
end
