# frozen_string_literal: true

require "async"

module Lain
  module Tools
    # Tier 3 (free-form), the SAME command shape as {Bash} -- a String through
    # `sh -c`, the model fully in control of it -- but executed OUT of process
    # by the lain-core daemon ({Core::Client#call} over msgpack-RPC). This is
    # the exec boundary's comparison arm: NOT in exe/lain's base_tools and
    # never wired into a shipped toolset; a bench constructs it explicitly
    # next to {Bash} to measure the transport. The differential spec pins the
    # two byte-for-byte identical for process OUTPUT content; spawn failure
    # and timeout are POSTURE parity instead (both arms return a result the
    # model can read), because their sources differ structurally -- mixlib
    # fails inside its forked child and formats its own exception, the daemon
    # fails at spawn or kills server-side and says so in the reply.
    #
    # Two more inherent asymmetries, accepted for C3: {Bash} forks from
    # call-time ENV while the daemon merges the override map over its
    # BOOT-TIME snapshot, so a harness ENV mutation after daemon boot reaches
    # Bash's child only; and {Bash} attributes live output bytes at source
    # onto the invocation's channel, while this arm stays channel-silent and
    # buffers everything until the reply (no streaming in the RPC protocol).
    #
    # A TRANSPORT BOUNDARY IS NOT A SANDBOX. The daemon is our own child on
    # our own uid, filesystem, and network; crossing a Unix socket adds no
    # seccomp, landlock, namespace, or chroot confinement. {WorkerEnv}'s
    # posture carries over verbatim: override, not confinement -- the env map
    # merges over the daemon's inherited environment, a var the map omits
    # still reaches the command, and the ONE removal lever is an explicit nil
    # value, mapped to msgpack nil, which REMOVES the key server-side (nil
    # removes, never empty-string; see lib/lain/worker_env.rb and
    # crates/lain-core/src/exec.rs). Real safety is {#requires_approval?} plus
    # Effect::Handler::Gate, and eventually OS confinement in a later chunk --
    # never this boundary.
    class CoreExec < Tool
      # {Bash}'s Input, SHARED BY IDENTITY rather than copied: one class is
      # what makes schema drift between the two arms structurally impossible,
      # and drift would quietly invalidate the differential.
      input_model Bash::Input

      # Seconds past the command's own timeout before this side stops
      # believing the daemon will enforce it. The caller owns its deadline:
      # pre-3b8c047, pipe-holding grandchildren held a 0.5s server timeout
      # for 5.0s -- a boundary that misses its own deadline must fail in the
      # tool's words, not park the loop. Generous, because on a healthy
      # daemon it covers only kill+reap+reply latency.
      GRACE = 5.0

      # The started {Core::Client} is injected: the caller owns the daemon's
      # lifecycle (and the Async reactor it runs in); this tool owns one RPC
      # round trip per command.
      def initialize(client:, grace: GRACE)
        super()
        @client = client
        @grace = grace
      end

      def name = "core_exec"

      def description
        "Runs a shell command via `sh -c` in the out-of-process lain-core " \
          "daemon and returns its exit status, stdout, and stderr. The " \
          "command is killed server-side if it runs past its timeout."
      end

      # Tier 3: the model fully controls `command`, exactly as it does for
      # {Bash} (bash.rb's own #requires_approval? note applies unchanged) --
      # the transport does not change the tier, because this boundary
      # confines nothing.
      def requires_approval? = true

      protected

      def perform(input, invocation)
        worker_env = session_of(invocation).worker_env
        outcome = within_deadline(input) { @client.call("exec", [wire_params(input, worker_env)]) }
        return timeout_error(input, outcome) if outcome.fetch("timed_out")

        Tool::Result.ok(format_output(outcome))
      rescue Core::Died, Core::Client::Stopped => e
        # Boundary death is a tool ERROR, never a raise past the loop (the
        # Gate convention): loud, named, and immediate -- the client already
        # failed this in-flight call the moment the daemon went.
        Tool::Result.error("lain-core boundary failed: #{e.class}: #{e.message}")
      rescue Core::Client::Refused => e
        spawn_refusal(e, input, worker_env)
      rescue Async::TimeoutError
        deadline_error(input)
      end

      private

      def wire_params(input, worker_env)
        {
          "argv" => ["sh", "-c", input.command],
          "cwd" => worker_env.resolve(input.cwd),
          # The WorkerEnv hash rides the wire as-is: an explicit-nil value
          # packs as msgpack nil, the server's remove-the-key marker -- the
          # same scrub {Bash} gets from mixlib's `ENV[k] = nil` in its child.
          "env" => worker_env.env,
          "timeout_ms" => (seconds_of(input) * 1000).to_i
        }
      end

      def seconds_of(input) = input.timeout || Bash::DEFAULT_TIMEOUT

      def within_deadline(input, &rpc)
        Async::Task.current.with_timeout(seconds_of(input) + @grace, &rpc)
      end

      # A spawn-shaped refusal (in practice: the cwd does not exist, since
      # argv[0] is always `sh`) becomes a readable error naming the cwd --
      # the posture-parity half of {Bash}'s exit-1-with-backtrace shape. Any
      # OTHER refusal is a client bug and stays a raise for the handler.
      def spawn_refusal(error, input, worker_env)
        raise error unless error.message.start_with?("spawn failed")

        Tool::Result.error("#{error.message} (cwd: #{worker_env.resolve(input.cwd)})")
      end

      # The kill-time partial capture rides the reply; discarding it would
      # tell the model less than {Bash} does (mixlib embeds captured output
      # in CommandTimeout's message, whose shape this mirrors).
      def timeout_error(input, outcome)
        Tool::Result.error(
          "command timed out after #{seconds_of(input)}s: killed server-side by lain-core\n" \
          "---- Begin output of #{input.command} ----\n" \
          "STDOUT: #{outcome.fetch("stdout")}\n" \
          "STDERR: #{outcome.fetch("stderr")}\n" \
          "---- End output of #{input.command} ----"
        )
      end

      def deadline_error(input)
        Tool::Result.error("lain-core failed to enforce the #{seconds_of(input)}s timeout " \
                           "within #{@grace}s grace -- no reply from the boundary")
      end

      # {Bash.render_output} from the wire's fields. stdout and stderr arrive
      # BINARY (msgpack bin); the template's ASCII-only literals interpolate
      # compatibly, so arbitrary bytes survive intact.
      def format_output(outcome)
        Bash.render_output(exit_status: outcome.fetch("exit_status"),
                           stdout: outcome.fetch("stdout"), stderr: outcome.fetch("stderr"))
      end
    end
  end
end
