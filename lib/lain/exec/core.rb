# frozen_string_literal: true

require "async"

module Lain
  module Exec
    # The out-of-process backend: the same `sh -c` command shape, executed by
    # the lain-core daemon over msgpack-RPC. One RPC round trip per command; the
    # caller owns the daemon's lifecycle and the Async reactor it runs in.
    #
    # ⚠️ This class SHADOWS {Lain::Core} for everything lexically inside
    # `Lain::Exec` -- a bare `Core::Client` here resolves to
    # `Lain::Exec::Core::Client` and dies. Root-qualify (`::Lain::Core`) at any
    # such site; nothing under `lib/lain/exec/` needs one today, which is why
    # there is a comment instead of a constant.
    #
    # A TRANSPORT BOUNDARY IS NOT A SANDBOX. The daemon is our own child on our
    # own uid, filesystem and network. It is also, being lain's own child, a
    # process that already carries lain's BUNDLE_GEMFILE -- so a scrub that
    # merely OMITS a key leaves the daemon's copy in place, and only the
    # explicit nil {Exec.child_env} writes (msgpack nil, the server's
    # remove-the-key marker) takes it away.
    class Core
      # Seconds past the command's own timeout before this side stops believing
      # the daemon will enforce it. Pre-3b8c047, pipe-holding grandchildren held
      # a 0.5s server timeout for 5.0s, and a boundary that misses its own
      # deadline must fail rather than park the loop. Generous, because on a
      # healthy daemon it covers only kill+reap+reply latency.
      GRACE = 5.0

      # @param client [#call] a started {Lain::Core::Client}
      # @param grace [Numeric] seconds past `timeout` to wait for a reply
      def initialize(client:, grace: GRACE)
        @client = client
        @grace = grace
        freeze
      end

      # @param _term [Array<Array<String>>] the term a caller is about to offer
      # @return [false] for every term -- the wire has one command shape, and
      #   {#accepts!} refuses by reading this answer rather than restating it
      def takes_term?(_term) = false

      # Live sinks are accepted and dropped: the RPC protocol carries no
      # streaming, so this arm buffers everything until the reply. That is an
      # inherent asymmetry with {Local} rather than an omission, and an accepted
      # one: a caller wanting live bytes reaches for {Local}.
      #
      # @param command [String] the shell command; a TERM has no wire shape here
      # @param cwd [String] already resolved by the caller ({WorkerEnv#resolve})
      # @param env [Hash] the caller's overrides, before the framework scrub
      # @param timeout [Numeric] seconds before the daemon kills the command
      # @param _no_live_output [Hash] the live sinks {Local} streams into,
      #   accepted so the two backends answer one message and dropped here
      # @return [Capture] what ran, whatever its exit status
      # @raise [Unsupported] when handed anything but a String
      # @raise [Timeout] when the daemon killed the command server-side
      # @raise [Unenforced] when no reply arrived within `grace` -- a {Timeout},
      #   so one rescue still covers both
      def call(command:, cwd:, env:, timeout:, **_no_live_output)
        accepts!(command)
        outcome = within_deadline(timeout) { @client.call("exec", [params(command, cwd, env, timeout)]) }
        raise Timeout, killed(command, outcome) if outcome.fetch("timed_out")

        Capture.new(exit_status: outcome.fetch("exit_status"),
                    stdout: outcome.fetch("stdout"), stderr: outcome.fetch("stderr"))
      rescue Async::TimeoutError
        raise Unenforced, "lain-core failed to enforce the #{timeout}s timeout " \
                          "within #{@grace}s grace -- no reply from the boundary"
      end

      private

      # The wire has ONE command shape. A term packed here would go out as
      # `["sh", "-c", [["printf", "hi"]]]`, which the daemon rejects at decode --
      # arriving back as a spawn-shaped Refused a caller then misreports as a
      # bad cwd. Refusing it at the door says what actually went
      # wrong; there is deliberately no join back to a string, for the reason
      # {Shell::Pipeline} gives for having no path from a term to one.
      def accepts!(command)
        return if command.is_a?(String) || takes_term?(command)

        raise Unsupported, "lain-core runs `sh -c <string>` and has no wire shape for a term: #{command.inspect}"
      end

      def params(command, cwd, env, timeout)
        {
          "argv" => ["sh", "-c", command],
          "cwd" => cwd,
          "env" => Exec.child_env(env),
          "timeout_ms" => (timeout * 1000).to_i
        }
      end

      def within_deadline(timeout, &rpc)
        Async::Task.current.with_timeout(timeout + @grace, &rpc)
      end

      # The kill-time partial capture rides the reply; discarding it would tell
      # the model less than {Local} does, whose `Mixlib::ShellOut::CommandTimeout`
      # embeds the captured output in its own message. This mirrors that shape.
      def killed(command, outcome)
        "killed server-side by lain-core\n" \
          "---- Begin output of #{command} ----\n" \
          "STDOUT: #{outcome.fetch("stdout")}\n" \
          "STDERR: #{outcome.fetch("stderr")}\n" \
          "---- End output of #{command} ----"
      end
    end
  end
end
