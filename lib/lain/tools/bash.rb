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
    # == Two arms, chosen by {Shell::Verdict}, and one rendering
    #
    # Every call is offered to the verdict first. It answers *"is this command
    # syntactically literal and fully understood?"* -- never "is it safe" -- and
    # it is free to abstain, which most commands do.
    #
    # * *allow* -- {Shell::Pipeline} runs the RECONSTRUCTED ARGV. No shell is
    #   started, so a disagreement between that parser and a real shell degrades
    #   to a broken command rather than an attacker-chosen one. There is
    #   deliberately no path from an allow back to the string: falling back
    #   would hand `sh -c` exactly the command the term path was chosen for.
    # * *anything else* -- the string runs through `sh -c` as it always has,
    #   under the same gate, with the same approval.
    #
    # Both arms render through {.render_output}, so which one ran is not
    # observable in the tool result. The one measured exception is a shell
    # BUILTIN with no binary -- `exit 3` is `command not found` on the term arm
    # -- and {Shell::Pipeline} documents why closing that gap honestly is not
    # possible.
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

      # The one output template BOTH exec arms render through -- {Bash} from
      # mixlib's captures, {CoreExec} from the daemon reply's bin fields --
      # shared so the differential's byte-identity cannot drift out from
      # under its specs (C3 panel fix 3).
      def self.render_output(exit_status:, stdout:, stderr:)
        "exit status: #{exit_status}\n" \
          "--- stdout ---\n#{stdout}" \
          "--- stderr ---\n#{stderr}"
      end

      # The subprocess machinery is injected as a factory, not constructed
      # inline: specs substitute a ShellOut whose TERM->KILL grace is short
      # (mixlib-shellout hardcodes `sleep 3` in reap_errant_child, with no
      # option) without giving up the real process-group kill.
      #
      # @param shell_out_factory [#call] builds the `Mixlib::ShellOut`-shaped
      #   object {#build_shell_out} runs the command through; substituting it
      #   is what lets a spec pin a shorter TERM->KILL grace without giving up
      #   the real process-group kill.
      # @param verdict [#call] `String -> Shell::Verdict::Decision`, the choice
      #   of arm. Injected rather than constructed so a spec can pin either arm
      #   for one command and compare their bytes.
      # @param pipeline [#call] runs the term arm's argv-array pipeline
      #   ({Shell::Pipeline}); the string arm never touches it
      def initialize(shell_out_factory: Mixlib::ShellOut.public_method(:new),
                     verdict: Shell::Verdict.new, pipeline: Shell::Pipeline.new)
        super()
        @shell_out_factory = shell_out_factory
        @verdict = verdict
        @pipeline = pipeline
      end

      def name = "bash"

      def description
        "Runs a shell command via `sh -c` and returns its exit status, " \
          "stdout, and stderr. The command's whole process group is killed " \
          "if it runs past its timeout."
      end

      # Tier 3: the model fully controls `command`. Gated by Effect::Handler::Gate
      # by default -- see the class comment.
      #
      # STAYS TRUE now that a term arm exists, and the reason is that the flag
      # describes the TOOL, not one call through it: the tool still takes a
      # string the model wrote. Which calls may skip a human is the escalation
      # ladder's question, asked per call and answered from the verdict.
      def requires_approval? = true

      protected

      def perform(input, invocation)
        decision = @verdict.call(input.command)
        decision.allow? ? run_term(decision.term, input, invocation) : run_string(input, invocation)
      end

      private

      def run_string(input, invocation)
        shell_out = build_shell_out(input, invocation)
        shell_out.run_command
        # Exit status rides in the returned content, not `is_error`: a
        # nonzero exit is frequently exactly what the model asked to observe
        # (grep with no matches, a linter reporting findings). `is_error`
        # here means the tool itself could not produce a result -- a timeout,
        # not a subprocess's own exit code.
        Tool::Result.ok(format_output(shell_out))
      rescue Mixlib::ShellOut::CommandTimeout => e
        timed_out(input, e)
      end

      # The same three fields, from the same {WorkerEnv}, rendered through the
      # same template -- so the arm a call took is not observable in its result.
      def run_term(term, input, invocation)
        worker_env = session_of(invocation).worker_env
        result = @pipeline.call(term,
                                cwd: worker_env.resolve(input.cwd), env: worker_env.env,
                                timeout: seconds(input),
                                stdout_sink: output_sink(invocation, :stdout),
                                stderr_sink: output_sink(invocation, :stderr))
        Tool::Result.ok(self.class.render_output(exit_status: result.exit_status,
                                                 stdout: result.stdout, stderr: result.stderr))
      rescue Shell::Pipeline::Timeout => e
        timed_out(input, e)
      end

      def seconds(input) = input.timeout || DEFAULT_TIMEOUT

      def timed_out(input, error)
        Tool::Result.error("command timed out after #{seconds(input)}s: #{error.message}")
      end

      # Cwd resolution lives on {WorkerEnv#resolve} -- one rule shared with
      # {CoreExec}. Under the default WorkerEnv (`Dir.pwd`) it is
      # byte-identical to passing the raw `input.cwd` through, nil included.
      def build_shell_out(input, invocation)
        worker_env = session_of(invocation).worker_env
        @shell_out_factory.call(
          input.command,
          cwd: worker_env.resolve(input.cwd),
          environment: worker_env.env,
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
        self.class.render_output(exit_status: shell_out.exitstatus,
                                 stdout: shell_out.stdout, stderr: shell_out.stderr)
      end
    end
  end
end
