# frozen_string_literal: true

module Lain
  module Tools
    # Tier 3 (free-form): runs a shell command via `sh -c`. Passing
    # Mixlib::ShellOut a STRING command rather than an argv Array is exactly
    # what makes this tier 3 rather than tier 2 -- an Array `exec`s with no
    # shell at all, while a String goes through the shell and the model fully
    # controls that string.
    #
    # == Two arms, chosen by {Shell::Verdict}, and one rendering
    #
    # Every call is offered to the verdict first. It answers *"is this command
    # syntactically literal and fully understood?"* -- never "is it safe" --
    # and it is free to abstain, which most commands do.
    #
    # * *allow* -- {Shell::Pipeline} runs the RECONSTRUCTED ARGV, wherever the
    #   backend has a shape for one. No shell is started, so a disagreement
    #   between that parser and a real shell degrades to a broken command
    #   rather than an attacker-chosen one. A backend that answers
    #   `#takes_term?` with false -- {Exec::Docker} handed a pipe,
    #   {Exec::Core} handed anything -- is given the model's own string, which
    #   is the only arm it ever had for that command. What still never happens
    #   is a term JOINED back into a string: that would hand `sh -c` a command
    #   this tool composed, and the term path exists to keep one away from it.
    #
    #   NAME WHAT THE FALLBACK TRADES AWAY. "No string is composed" and "no
    #   shell sees this command" are different claims, and only the first
    #   survives: a shell DOES read the model's string on that path --
    #   {Exec::Docker} runs it as `["sh", "-c", command]` INSIDE the container
    #   -- so the term arm's no-shell property is gone there, and what carries
    #   safety in its place is containment plus the same gate, never the
    #   absence of a shell.
    # * *anything else* -- the string runs through `sh -c`, under the same gate.
    #
    # Both arms render through {.render_output}, so which one ran is not
    # observable in the tool result. The one measured exception is a shell
    # BUILTIN with no binary -- `exit 3` is `command not found` on the term arm
    # -- and {Shell::Pipeline} documents why closing that gap honestly is not
    # possible.
    #
    # Neither arm is run here: both go to an injected {Lain::Exec} backend,
    # which decides the child's environment. This tool owns the CHOICE of arm
    # and the rendering of what came back.
    #
    # A PROCESS BOUNDARY IS NOT A SECURITY BOUNDARY. The child inherits our
    # uid, filesystem and network; Mixlib::ShellOut adds no seccomp, landlock,
    # namespace or chroot confinement of its own. What it DOES make correct:
    # capture, attribution, timeout and reaping -- it calls `setsid`, so a
    # timeout kills the whole process group and not just the shell. Real safety
    # is {#requires_approval?} plus a human or policy on the other end of
    # {Effect::Handler::Gate}, and eventually OS confinement in the
    # out-of-process Rust exec boundary. NEVER this tool's input validation,
    # which checks only that `timeout` is a sane number.
    class Bash < Tool
      DEFAULT_TIMEOUT = 120
      MAX_TIMEOUT = 600

      # A command's output is a WHOLE ARTIFACT in {Tool::Bounds}' sense -- its
      # first N bytes read like the answer and are not -- so it is refused over
      # the ceiling rather than truncated. 128 KiB is the tightest ceiling here
      # for a reason: command output is the only artifact the caller SHAPES
      # BEFORE IT EXISTS. A file's size is a fact to be worked around; `| tail
      # -n 200` is one edit to the command already being written.
      OUTPUT_BOUND = Tool::Bounds::Artifact.new(limit: 128 * 1024)

      # Both are available to EVERY command, which keeps the refusal from
      # being a dead end.
      NARROWER = [
        "re-run it with the output narrowed through head, tail or grep",
        "redirect it to a file and read one window of that with read_file"
      ].freeze

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

      # The one place BOTH exec arms turn captures into a {Tool::Result},
      # shared so the differential's byte-identity cannot drift out from under
      # its specs. {OUTPUT_BOUND} is applied HERE for that reason: a ceiling
      # checked per arm would be two ceilings that happen to agree today, and
      # the daemon arm would have a third or none.
      #
      # The exit status rides in the refusal's SUBJECT rather than being
      # dropped, because it is the one fact a truncation would have preserved
      # and the model usually asked the question to learn it.
      #
      # The HUMAN still sees every byte: both arms stream through
      # {Sink::IOAdapter} as output is produced, which is right for a live
      # terminal -- a refusal is about what the MODEL is handed. It does mean
      # the cockpit and the transcript diverge above this ceiling, which matters
      # on a bench whose product is the comparison of the two.
      #
      # @return [Tool::Result] ok with the rendered output, or the bound's
      #   refusal carrying none of it
      def self.render_output(exit_status:, stdout:, stderr:)
        size = stdout.bytesize + stderr.bytesize
        unless OUTPUT_BOUND.admits?(size)
          return OUTPUT_BOUND.refusal(subject: "the command's output (exit status: #{exit_status})",
                                      size:, narrower: NARROWER)
        end

        Tool::Result.ok("exit status: #{exit_status}\n" \
                        "--- stdout ---\n#{stdout}" \
                        "--- stderr ---\n#{stderr}")
      end

      # @param exec [#call] the {Lain::Exec} backend a command is run through,
      #   injected so the transport is a run's choice and a spec can substitute
      #   one whose TERM->KILL grace is short
      # @param verdict [#call] `String -> Shell::Verdict::Decision`, the choice
      #   of arm, injected so a spec can pin either arm for one command and
      #   compare their bytes
      def initialize(exec: Exec::Local.new, verdict: Shell::Verdict.new)
        super()
        @exec = exec
        @verdict = verdict
      end

      def name = "bash"

      def description
        "Runs a shell command via `sh -c` and returns its exit status, " \
          "stdout, and stderr. The command's whole process group is killed " \
          "if it runs past its timeout."
      end

      # Tier 3: the model fully controls `command`.
      #
      # STAYS TRUE now that a term arm exists, because the flag describes the
      # TOOL and not one call through it -- the tool still takes a string the
      # model wrote. WHICH calls may skip a human is the escalation ladder's
      # question, asked per call and answered from the verdict.
      def requires_approval? = true

      protected

      # Exit status rides in the returned content, NOT `is_error`: a nonzero
      # exit is frequently what the model asked to observe. `is_error` means
      # the tool itself could not produce a result -- a timeout, or output too
      # large to hand back -- never a subprocess's own exit code.
      def perform(input, invocation)
        capture = @exec.call(command: arm_for(input.command), **runtime(input, invocation))
        self.class.render_output(exit_status: capture.exit_status,
                                 stdout: capture.stdout, stderr: capture.stderr)
      rescue Exec::Timeout => e
        timed_out(input, e)
      end

      private

      # ASK BEFORE OFFERING. An allow yields a term, but a backend may have no
      # shape for that term, and hearing so as an {Exec::Unsupported} mid-call
      # is how `--exec docker` used to answer an ordinary pipeline with a tool
      # error nobody wrote. The fallback is `input.command` itself -- never the
      # term rejoined -- so the string arm sees exactly the bytes the model
      # wrote, under the same gate.
      def arm_for(command)
        decision = @verdict.call(command)
        return command unless decision.allow? && @exec.takes_term?(decision.term)

        decision.term
      end

      # Cwd resolution lives on {WorkerEnv#resolve} -- one rule shared with
      # {CoreExec}.
      def runtime(input, invocation)
        worker_env = session_of(invocation).worker_env
        { cwd: worker_env.resolve(input.cwd), env: worker_env.env, timeout: seconds(input),
          stdout_sink: output_sink(invocation, :stdout), stderr_sink: output_sink(invocation, :stderr) }
      end

      def seconds(input) = input.timeout || DEFAULT_TIMEOUT

      def timed_out(input, error)
        Tool::Result.error("command timed out after #{seconds(input)}s: #{error.message}")
      end

      # Bytes are attributed to their tool_use_id AT THE SOURCE, as produced,
      # rather than reconstructed afterwards from a buffer shared with whatever
      # else is running -- see {Lain::Channel} on why that destroys provenance.
      def output_sink(invocation, stream)
        Sink::IOAdapter.new(invocation.channel, tool_use_id: invocation.tool_use_id, stream:)
      end
    end
  end
end
