# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Tools
    # Tier 3 (free-form): runs a shell command via `sh -c`. Passing
    # Mixlib::ShellOut a String command -- rather than an argv Array -- is
    # exactly what makes this tier 3 rather than tier 2: an Array `exec`s with
    # no shell at all, while a String goes through the shell and the model
    # fully controls that string (see the plan's "Tool tiers, and where the
    # security boundary is").
    #
    # A PROCESS BOUNDARY IS NOT A SECURITY BOUNDARY. The child inherits our
    # uid, filesystem, and network; Mixlib::ShellOut adds no seccomp, landlock,
    # namespace, or chroot confinement of its own. What it *does* make
    # correct: capture, attribution, timeout, and reaping (it calls `setsid`,
    # so a timeout kills the whole process group, not just the shell). Real
    # safety is {#requires_approval?} plus a human (or policy) on the other
    # end of Effect::Handler::Gate, and eventually OS confinement in the
    # out-of-process Rust exec boundary (M5/M6) -- never this tool's input
    # validation, which checks only that `timeout` is a sane number.
    class Bash < Tool
      DEFAULT_TIMEOUT = 120
      MAX_TIMEOUT = 600

      # The wire shape: a required command String, plus optional cwd and timeout.
      class Input < Tool::Input
        field :command, :string, description: "Shell command to run via `sh -c`.", required: true
        field :cwd, :string, description: "Working directory for the command. Defaults to the current directory."
        field :timeout, :integer,
              description: "Seconds to allow before the command's whole process group is killed. " \
                           "Defaults to #{DEFAULT_TIMEOUT}, max #{MAX_TIMEOUT}."

        validates :timeout, numericality: { greater_than: 0, less_than_or_equal_to: MAX_TIMEOUT }, allow_nil: true
      end

      input_model Input

      def name = "bash"

      def description
        "Runs a shell command via `sh -c` and returns its exit status, " \
          "stdout, and stderr. The command's whole process group is killed " \
          "if it runs past its timeout."
      end

      # Tier 3: the model fully controls `command`. Gated by Effect::Handler::Gate
      # by default -- see the class comment.
      def requires_approval? = true

      protected

      def perform(input, invocation)
        shell_out = build_shell_out(input, invocation)
        shell_out.run_command
        # Exit status rides in the returned content, not `is_error`: a
        # nonzero exit is frequently exactly what the model asked to observe
        # (grep with no matches, a linter reporting findings). `is_error`
        # here means the tool itself could not produce a result -- a timeout,
        # not a subprocess's own exit code.
        Tool::Result.ok(format_output(shell_out))
      rescue Mixlib::ShellOut::CommandTimeout => e
        Tool::Result.error("command timed out after #{input.timeout || DEFAULT_TIMEOUT}s: #{e.message}")
      end

      private

      def build_shell_out(input, invocation)
        Mixlib::ShellOut.new(
          input.command,
          cwd: input.cwd,
          timeout: input.timeout || DEFAULT_TIMEOUT,
          live_stdout: output_sink(invocation, :stdout),
          live_stderr: output_sink(invocation, :stderr)
        )
      end

      # Bytes are attributed to their tool_use_id AT THE SOURCE, as they are
      # produced, rather than reconstructed after the fact from a buffer
      # shared with whatever else happens to be running -- see Lain::Channel's
      # doc comment on why a shared byte buffer destroys provenance.
      def output_sink(invocation, stream)
        Sink::IOAdapter.new(invocation.channel, tool_use_id: invocation.tool_use_id, stream:)
      end

      def format_output(shell_out)
        "exit status: #{shell_out.exitstatus}\n" \
          "--- stdout ---\n#{shell_out.stdout}" \
          "--- stderr ---\n#{shell_out.stderr}"
      end
    end
  end
end
