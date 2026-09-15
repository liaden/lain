# frozen_string_literal: true

module Lain
  module Exec
    # The in-process backend: a command runs as a child of THIS process, under
    # this process's uid, filesystem and network.
    #
    # It owns BOTH in-process arms, and one runner runs them: a TERM reaches
    # `execvp` through {Shell::Pipeline} as it is, and a String reaches the same
    # runner as the one-stage term `["/bin/sh", "-c", command]`. So the session of its
    # own, the group kill, the live sinks, the capture bound and the child's
    # `/dev/null` stdin are one implementation, and {Exec.child_env} is applied in one place above
    # them -- the same reason {Tools::Bash.render_output} is one rendering rather
    # than one per arm.
    #
    # The string is wrapped, never a term joined: a term offered here never
    # reaches a shell, and the model's string reaches `sh -c` as one argv word,
    # byte for byte as it was written.
    class Local
      # Absolute, so a PATH the child is lent can neither lose the shell nor put
      # a project's own `sh` ahead of it.
      SHELL = "/bin/sh"

      # @param pipeline [#call] runs both arms; injectable so a spec can pin a
      #   shorter TERM->KILL grace without giving up the real process-group kill
      # @param ceiling [Integer] the output ceiling the bytes are bound for
      def initialize(pipeline: Shell::Pipeline.new, ceiling: Tool::Bounds::CEILINGS.fetch("bash"))
        @pipeline = pipeline
        @ceiling = ceiling
        freeze
      end

      # Both arms are this backend's own, so its answer does not depend on the
      # term. It is still ASKED about one, because the contract's question is
      # about a shape rather than about a backend: {Docker} takes a one-stage
      # term and refuses a pipe, which no argument-less predicate could say.
      #
      # ⚠️ THIS LINE HOLDS UP THE TWO-ARM BYTE-IDENTITY INVARIANT. Because it
      # is true for EVERY term, no command that reaches the term arm here can
      # fall back to the string arm, so the two arms never run the same command
      # differently. Narrow it -- a subclass answering `term.size == 1` is
      # enough -- and `cat README.md | head -20` silently takes the string arm
      # on a term-capable backend, which is the divergence
      # `spec/lain/tools/bash_spec.rb` pins.
      #
      # @param _term [Array<Array<String>>] the term a caller is about to offer
      # @return [true]
      def takes_term?(_term) = true

      # @param command [String, Array<Array<String>>] a shell command string, or
      #   a TERM -- an Array of argv Arrays, which never reaches a shell
      # @param cwd [String] already resolved by the caller ({WorkerEnv#resolve})
      # @param env [Hash] the caller's overrides, before the framework scrub
      # @param timeout [Numeric] seconds before the process group is killed
      # @param stdout_sink [#<<] where stdout bytes are pumped as they arrive
      # @param stderr_sink [#<<] where stderr bytes are pumped as they arrive
      # @return [Capture] what ran, whatever its exit status, holding at most
      #   one byte past the ceiling and counting every byte
      # @raise [Timeout] when the deadline passed and the group was killed
      def call(command:, cwd:, env:, timeout:, stdout_sink: Sink::Null.new, stderr_sink: Sink::Null.new)
        capture = Capture::Bounded.new(ceiling: @ceiling, stdout_sink:, stderr_sink:)
        @pipeline.call(term(command), cwd:, env: Exec.child_env(env), timeout:, capture:)
      rescue Shell::Pipeline::Timeout => e
        raise Timeout, e.message
      end

      private

      def term(command) = command.is_a?(String) ? [[SHELL, "-c", command]] : command
    end
  end
end
