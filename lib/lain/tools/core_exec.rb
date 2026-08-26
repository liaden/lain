# frozen_string_literal: true

module Lain
  module Tools
    # Tier 3 (free-form), the SAME command shape as {Bash} -- a String through
    # `sh -c` -- executed OUT of process by the lain-core daemon. The exec
    # boundary's COMPARISON ARM: never wired into a shipped toolset, a bench
    # constructs it beside {Bash} to measure the transport.
    #
    # The differential spec pins the two byte-for-byte identical for process
    # OUTPUT content. Spawn failure and timeout are POSTURE parity instead --
    # both arms return a result the model can read -- because their sources
    # differ structurally: mixlib fails inside its forked child and formats its
    # own exception, the daemon fails at spawn or kills server-side.
    #
    # Two inherent asymmetries, accepted deliberately: {Bash} forks from
    # call-time ENV while the daemon merges the override map over its BOOT-TIME
    # snapshot, so a harness ENV mutation after daemon boot reaches Bash's child
    # only; and {Bash} attributes live output bytes at source, where this arm
    # stays channel-silent and buffers until the reply.
    #
    # A TRANSPORT BOUNDARY IS NOT A SANDBOX. The daemon is our own child on our
    # own uid, filesystem and network; crossing a Unix socket adds no seccomp,
    # landlock, namespace or chroot confinement. {WorkerEnv}'s posture carries
    # over verbatim -- override, not confinement: the env map merges over the
    # daemon's inherited environment, a var the map omits still reaches the
    # command, and the ONE removal lever is an explicit NIL value, which removes
    # the key server-side. Real safety is {#requires_approval?} plus
    # {Effect::Handler::Gate}, and eventually OS confinement. Never this
    # boundary.
    #
    # That removal lever is what {Exec.child_env} uses to keep lain's own
    # bundler context out of the daemon's child, and it has to: the daemon is
    # lain's own child, so it already carries BUNDLE_GEMFILE and an env map that
    # merely OMITS the key would leave that copy in place.
    class CoreExec < Tool
      # {Bash}'s Input, SHARED BY IDENTITY rather than copied: one class is
      # what makes schema drift between the two arms structurally impossible,
      # and drift would quietly invalidate the differential.
      input_model Bash::Input

      # Seconds past the command's own timeout before this side stops
      # believing the daemon will enforce it. {Exec::Core} owns the number; this
      # is an alias, because it is part of this tool's published default.
      #
      # A LOAD-TIME read, and the only one in this direction: it pins
      # `lain/exec` ahead of `lain/tools` in lib/lain.rb's manifest, so
      # reordering those entries is a NameError at require time.
      GRACE = Exec::Core::GRACE

      # The started {Core::Client} is injected: the caller owns the daemon's
      # lifecycle and its reactor. The round trip belongs to {Exec::Core}, so
      # this tool is the same shape as {Bash} -- choose nothing, render what
      # came back. `grace` is NOT kept: the backend holds it, and one fact held
      # twice is two facts the moment a caller constructs them apart.
      def initialize(client:, grace: GRACE)
        super()
        @exec = Exec::Core.new(client:, grace:)
      end

      def name = "core_exec"

      # In step with {Bash}'s, and deliberately NOT a copy of it. The shared
      # {Bash::Input} tells the model a fully understood command can skip the
      # shell "wherever the backend running it takes argv"; {Exec::Core} takes
      # none, and this tool only ever sends a String. So this half names the
      # same rule and then says where this transport stands under it, rather
      # than borrowing a conditional that is false here -- which is the defect
      # the day someone wires this tool up and reads only its own string.
      def description
        "Runs a shell command in the out-of-process lain-core daemon and " \
          "returns its exit status, stdout, and stderr. A command that is " \
          "fully understood can run as argv with no shell process at all, " \
          "but only where the backend takes argv, and the daemon does not: " \
          "`sh -c` runs everything sent here. The command is killed " \
          "server-side if it runs past its timeout."
      end

      # Tier 3: the model fully controls `command`. The transport does not
      # change the tier, because this boundary confines nothing.
      def requires_approval? = true

      protected

      def perform(input, invocation)
        worker_env = session_of(invocation).worker_env
        render(@exec.call(**request(input, worker_env)))
      rescue Exec::Unenforced => e
        # The boundary missed its OWN deadline, which is not the command
        # hitting one -- rescued before its superclass so the two differ.
        Tool::Result.error(e.message)
      rescue Exec::Timeout => e
        timeout_error(input, e)
      rescue Core::Died, Core::Client::Stopped => e
        boundary_failed(e)
      rescue Core::Client::Refused => e
        spawn_refusal(e, input, worker_env)
      end

      private

      # Cwd resolution lives on {WorkerEnv#resolve} -- the one rule shared with
      # {Bash}, so the two transports cannot drift apart on it.
      def request(input, worker_env)
        { command: input.command, cwd: worker_env.resolve(input.cwd),
          env: worker_env.env, timeout: seconds_of(input) }
      end

      # stdout and stderr arrive BINARY (msgpack bin); the template's
      # ASCII-only literals interpolate compatibly, so arbitrary bytes survive.
      #
      # Its whole {Tool::Result} is returned, REFUSAL INCLUDED:
      # {Bash::OUTPUT_BOUND} is applied inside that one rendering precisely so
      # this arm cannot have a different ceiling, and wrapping its answer in a
      # second `Result.ok` here would relabel a refusal as a success.
      def render(capture)
        Bash.render_output(exit_status: capture.exit_status,
                           stdout: capture.stdout, stderr: capture.stderr)
      end

      def seconds_of(input) = input.timeout || Bash::DEFAULT_TIMEOUT

      # Boundary death is a tool ERROR, never a raise past the loop: loud,
      # named and immediate -- the client already failed this in-flight call
      # the moment the daemon went.
      def boundary_failed(error)
        Tool::Result.error("lain-core boundary failed: #{error.class}: #{error.message}")
      end

      # A spawn-shaped refusal -- in practice a cwd that does not exist, since
      # argv[0] is always `sh` -- becomes a readable error naming the cwd, the
      # posture-parity half of {Bash}'s exit-1-with-backtrace shape. Any OTHER
      # refusal is a client bug and stays a raise.
      def spawn_refusal(error, input, worker_env)
        raise error unless error.message.start_with?("spawn failed")

        Tool::Result.error("#{error.message} (cwd: #{worker_env.resolve(input.cwd)})")
      end

      # Word for word {Bash}'s own timeout sentence, over an {Exec::Timeout}
      # carrying the kill-time partial capture -- which is what makes the two
      # arms' timeout POSTURE parity rather than an accident.
      def timeout_error(input, error)
        Tool::Result.error("command timed out after #{seconds_of(input)}s: #{error.message}")
      end
    end
  end
end
