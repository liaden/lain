# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  # A desktop-notification surface over `dunstify`. Joins the SAME seam
  # {Frontend::ApprovalPolicy} (I4) joins Gate through: {Approval::Queue}
  # neither knows nor cares which surface answers a {Approval::Queue::Pending}
  # -- {#watch} parks on the queue, {#decide} answers one arrival, and two
  # surfaces racing over the same pending is normal (first answer wins, the
  # queue's own doctrine). {#question} is unrelated to the queue: it fires a
  # plain informational notification for `ask_human`, where answering happens
  # at a real surface (the TTY prompt), never a notification click.
  #
  # `dunstify -A action,label` (repeatable) BLOCKS the dunstify PROCESS itself
  # until the human clicks a button, dismisses the notification, or its own
  # `-t` window expires -- a real, possibly long wait (confirmed by hand:
  # `dunstify -t 1000 -A a,A -A b,B SUMMARY BODY` took the full second and
  # printed dunst's own numeric close-reason code, never one of our action
  # identifiers, when nothing was clicked). That wait runs on a dedicated
  # Thread, never inline in the calling Fiber: Mixlib::ShellOut's internal
  # wait is not a primitive this project has verified as
  # Fiber::SchedulerInterface-safe the way Kernel#sleep/IO#read are (`async`
  # hooks those directly), so trusting it not to stall the WHOLE reactor
  # thread -- every other fiber in the process, not just this one -- is not a
  # chance worth taking for a notifications adapter. The bridge back to the
  # calling fiber is a `Thread::Queue#pop`: Ruby's Fiber::SchedulerInterface
  # hooks Queue's blocking pop (`block`/`unblock`, confirmed against this
  # project's `async` (2.42) in `Async::Scheduler#block`/`#unblock`) as a
  # FIBER park, not an OS-thread block -- and the identical code is an
  # ordinary blocking wait with no reactor present at all (a bare script, a
  # spec with no `Sync` block), so nothing here depends on `async` running.
  class Notify
    # This surface's name in the approval Journal, alongside "tty".
    SURFACE = "dunst"

    # The `-A` action identifiers this surface offers. Neither is numeric, so
    # neither can ever collide with one of dunstify's own close-reason codes
    # (1 expired, 2 dismissed, 3 closed via the API, 4 undefined) -- the
    # signal that tells {#decide} "nothing was clicked" is exactly "the
    # answer isn't APPROVE".
    APPROVE = "approve"
    DENY = "deny"

    # Derived from the queue's OWN window, not a second opinion of it: the
    # QUEUE'S timeout must govern, never a surface's. A surface backstop
    # shorter than the queue's window would deny the shared Pending on the
    # surface's clock and journal that denial as surface: "dunst" with a
    # latency that measures nothing real -- corrupted evidence on a bench
    # where decision latency IS the experiment record. Referencing the
    # source of truth (rather than copying its value with a comment
    # promising they agree) is what keeps the two from drifting apart
    # silently; see the spec pinning this inequality.
    DEFAULT_TIMEOUT_MS = Approval::Queue::DEFAULT_TIMEOUT * 1000

    # A backstop past dunstify's OWN `-t`, verified load-bearing by hand: a
    # critical-urgency notification (what {#decide} sends, deliberately, so
    # an approval prompt does not silently vanish) is exactly the case the
    # freedesktop notification spec exempts from auto-expiry, and this
    # desktop's dunst honors that -- a live `dunstify -u critical -t 1200 -A
    # ...` sat past its `-t` window with no human present, an orphaned
    # process, until killed by hand. Mixlib::ShellOut's own `timeout:` is the
    # guarantee dunstify's `-t` is not: it SIGTERMs (then SIGKILLs) the whole
    # process group if the subprocess outlives it, {Mixlib::ShellOut::CommandTimeout}
    # lands in {#capture}'s `rescue`, and the fail-closed deny fires exactly
    # as it would for a real dismissal.
    #
    # In the ordinary case this backstop never fires first: with
    # `DEFAULT_TIMEOUT_MS` at the queue's own window, {Approval::Queue}'s
    # `Async::Task#with_timeout` expires and denies (surface: "timeout") a
    # tick before this one ever could, so the QUEUE attributes the denial to
    # itself, honestly. This grace only outlives that -- it exists to reap
    # the now-orphaned dunstify process afterward, not to race the queue for
    # who gets to decide.
    SHELLOUT_GRACE_MS = 5_000

    class << self
      # @return [Notify, Null] the real adapter when `command` resolves on
      #   PATH, {Null} otherwise -- the Null Object seam ({Sink::Null}'s
      #   idiom), so a caller never writes `if notifier`.
      def for(command: "dunstify", **)
        on_path?(command) ? new(command:, **) : Null.new
      end

      private

      def on_path?(command)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, command)
          File.file?(path) && File.executable?(path)
        end
      end
    end

    # @param command [String] the dunstify binary, resolved through the shell's PATH
    # @param shell_out_factory [#call] builds the subprocess object; injected
    #   so specs substitute a double that runs no real process (the same seam
    #   {Tools::Bash} uses for `Mixlib::ShellOut`)
    # @param timeout_ms [Integer] dunstify's own `-t`: how long an unanswered
    #   notification waits before it expires and reports a close reason
    def initialize(command: "dunstify", shell_out_factory: Mixlib::ShellOut.public_method(:new),
                   timeout_ms: DEFAULT_TIMEOUT_MS)
      @command = command
      @shell_out_factory = shell_out_factory
      @timeout_ms = timeout_ms
    end

    # The surface loop: park on the queue, decide each arrival. Runs in its
    # own fiber beside any other surface watching the same queue (the exe
    # hosts and stops it, the identical shape {Frontend::ApprovalPolicy#watch} is).
    def watch(queue)
      loop { decide(queue.dequeue) }
    end

    # Answer ONE pending approval: fire a notification with Approve/Deny
    # buttons, decide from whichever action (or non-action) dunstify reports.
    # Fails closed on anything that isn't literally {APPROVE} -- a Deny click,
    # a dismissal, an expiry, or the shellout itself raising all deny.
    #
    # @param pending [Lain::Approval::Queue::Pending]
    # @return [Boolean] whether THIS surface's decision won the race
    def decide(pending)
      pending.decide(run(approval_args(pending)) == APPROVE, surface: SURFACE)
    end

    # A plain informational notification -- no actions, nothing to decide.
    # Names the ASKING agent so a human glancing at their desktop knows who's
    # asking before they alt-tab to answer for real, at a real surface.
    #
    # @return [nil]
    def question(agent:, text:)
      run(question_args(agent:, text:))
      nil
    end

    private

    def approval_args(pending)
      ["-a", "lain", "-u", "critical", "-t", @timeout_ms.to_s,
       "-A", "#{APPROVE},Approve", "-A", "#{DENY},Deny",
       "approve #{pending.tool}?", pending.input.inspect]
    end

    def question_args(agent:, text:)
      ["-a", "lain", "-u", "normal", "-t", @timeout_ms.to_s, "#{agent} asks", text]
    end

    # See the class comment: dunstify's wait runs on a dedicated Thread, and
    # `Thread::Queue#pop` is the fiber-scheduler-safe bridge back.
    def run(args)
      queue = Thread::Queue.new
      # Not joined: #capture's own timeout bounds this Thread's lifetime, and
      # `queue.pop` below is what actually waits for its result.
      Thread.new { queue.push(capture(args)) }
      queue.pop
    end

    # Fails closed on any shellout error (a vanished binary, a broken D-Bus
    # session) rather than raising out of a notification surface -- an
    # approval nobody could actually be asked about must still refuse, never
    # wedge (Gate's own doctrine, Approval::Queue's own timeout inherits it).
    def capture(args)
      shell_out = @shell_out_factory.call(@command, *args, timeout: shellout_timeout_seconds)
      shell_out.run_command
      shell_out.stdout.to_s.strip
    rescue StandardError
      ""
    end

    # dunstify's own `-t` (milliseconds) plus {SHELLOUT_GRACE_MS}, in seconds,
    # for `Mixlib::ShellOut`'s `timeout:` -- deliberately looser than `-t` so
    # a well-behaved dunstify (a normal-urgency {#question}, or a critical one
    # a human actually dismissed) reports its OWN real close reason first;
    # this is only the backstop for the one confirmed not to.
    def shellout_timeout_seconds
      (@timeout_ms + SHELLOUT_GRACE_MS) / 1000.0
    end

    # No dunstify on PATH: every method is a documented no-op, so a caller
    # never guards with `if notifier`. {#decide} still denies fail-closed --
    # an approval nobody here can answer refuses at once, the same doctrine
    # {Approval::Queue}'s own timeout enforces after ITS window -- but
    # {#watch} never touches the queue at all, so a pending this surface
    # cannot serve is left for whichever OTHER surface (the TTY prompt) is
    # actually watching, rather than being raced away from it.
    class Null
      def watch(_queue) = nil
      def decide(pending) = pending.deny(surface: SURFACE)
      def question(**) = nil
    end
  end
end
