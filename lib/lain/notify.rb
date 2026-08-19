# frozen_string_literal: true

require "async"
require "cgi/escape"
require "mixlib/shellout"

module Lain
  # A desktop-notification surface over `dunstify`. Joins the SAME seam
  # {Frontend::ApprovalPolicy} (I4) joins Gate through: {Approval::Queue}
  # neither knows nor cares which surface answers a {Approval::Queue::Pending}
  # -- {#watch} sweeps the parked set, {#decide} answers one pending, and two
  # surfaces racing over the same pending is normal (first answer wins, the
  # queue's own doctrine). It OBSERVES and never consumes, which is not a
  # detail: see {#watch}. {#question} is unrelated to the queue: it fires a
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
  # calling fiber is a `Thread::Queue`: Ruby's Fiber::SchedulerInterface
  # hooks Queue's blocking pop (`block`/`unblock`, confirmed against this
  # project's `async` (2.42) in `Async::Scheduler#block`/`#unblock`) as a
  # FIBER park, not an OS-thread block -- and the identical code is an
  # ordinary blocking wait with no reactor present at all (a bare script, a
  # spec with no `Sync` block), so nothing here depends on `async` running.
  #
  # THAT THREAD DOES EXACTLY ONE THING: it runs the shellout and pushes the
  # answer. It reads only the ivars fixed at construction (`@command`,
  # `@shell_out_factory`, `@timeout_ms`), writes none, and decides no
  # {Pending} -- so nothing it can reach is state a sweep also mutates.
  # {#sweep} DISPATCHES a notification per parked pending and drains the
  # finished ones on a later pass, so a call that parks while an earlier
  # notification is still on screen gets its own popup at once instead of in
  # five minutes' time (QA round 5, F24: `dunstify -A` blocks for the queue's
  # whole 300s window, so waiting inline meant one approval per window however
  # many a turn gated).
  #
  # Applying the verdict stays on the sweep fiber, and that is a constraint
  # rather than a taste. {Approval::Queue::Pending#decide}'s lock-free
  # single-shot resolution is safe "only because ... two FIBERS cannot both
  # pass the guard" -- a fiber argument, which two OS threads do not satisfy --
  # and `Promise#resolve` reaches an `Async::Condition` that resumes
  # reactor-owned fibers, which from a foreign thread is a `FiberError`. So
  # the verdict crosses back as data and this fiber decides.
  #
  # {#decide} has no caller in `lib/` or `exe/`, and that is not an oversight to
  # be tidied away: it is the one-pending INLINE form the surface loop
  # deliberately stopped using, and it is spec-facing -- {Null#decide}'s mirror,
  # the `:desktop` real-dunstify probe's only entry, and the sharer of {#settle}
  # that keeps the inline and dispatched fail-closed rules from drifting apart.
  # Do not grep for a caller and conclude it is dead.
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
    # That group is PER CHILD, which is what makes this backstop safe now that
    # N notifications can be in flight at once. `Mixlib::ShellOut`'s forked
    # child calls `Process.setsid` before exec (3.4.10, `shellout/unix.rb:337`,
    # whose own comment gives the same reason), so its pgid is its own pid and
    # `child_pgid` is `-@child_pid` (`:192-195`) -- one notification's reaper
    # cannot reach another's dunstify. A shared group would have made the first
    # timeout kill every live popup on the screen.
    #
    # In the ordinary case this backstop never fires first: with
    # `DEFAULT_TIMEOUT_MS` at the queue's own window, {Approval::Queue}'s
    # `Async::Task#with_timeout` expires and denies (surface: "timeout") a
    # tick before this one ever could, so the QUEUE attributes the denial to
    # itself, honestly. This grace only outlives that -- it exists to reap
    # the now-orphaned dunstify process afterward, not to race the queue for
    # who gets to decide.
    SHELLOUT_GRACE_MS = 5_000

    # Between sweeps of the parked set. {QueueSurface::DEFAULT_POLL_INTERVAL}'s
    # value and its reason: a surface is a sibling fiber, so the sleep is a
    # scheduler yield rather than a wall-clock stall.
    POLL_INTERVAL = Approval::QueueSurface::DEFAULT_POLL_INTERVAL

    # What `LAIN_DESKTOP` forces, in either direction; any other value (unset
    # included) leaves the caller's own answer standing. One spelling, reused:
    # the `:desktop` seam in this class's spec already means "this shell may
    # reach the real desktop" by `LAIN_DESKTOP=1`, and `=0` is how an agent
    # driving a real `lain chat` silences a flag that defaults to on.
    OVERRIDE = { "1" => true, "0" => false }.freeze

    class << self
      # CONSENT, then capability -- in that order, and the order is the fix.
      # `dunstify` on PATH says the desktop CAN be reached; it never says this
      # process MAY reach it. Presence was read as consent until 2026-08-05,
      # when nine notifications reading "lain is waiting for a verdict" landed
      # on a working human's screen from agents' trees -- because every spec,
      # probe and subagent in this repository runs on the SAME machine, with the
      # same PATH, as the human it would interrupt. So `desktop:` defaults to
      # OFF and whoever owns the human's attention says so: `exe/lain`'s
      # `--desktop` flag, on by default, is that caller for an interactive chat.
      #
      # It is the placement rule the Rust boundary already states -- a component
      # that sniffs `isatty` owns the terminal, so colour arrives as a resolved
      # argument instead. Reaching the desktop is the same shape, and
      # {CLI::FleetWindows.for} is its sibling: an opt-in flag first, `$TMUX`
      # second, never the environment alone.
      #
      # @param command [String] the dunstify binary, resolved through PATH
      # @param desktop [Boolean] whether this caller owns the human's attention
      # @return [Notify, Null] the real adapter only when BOTH hold, {Null}
      #   otherwise -- the Null Object seam ({Sink::Null}'s idiom), so a caller
      #   never writes `if notifier`.
      def for(command: "dunstify", desktop: false, **)
        consented?(desktop) && on_path?(command) ? new(command:, **) : Null.new
      end

      private

      # The env var has the last word because it is the MACHINE's answer where
      # the flag is one run's; a `fetch` defaulting to the caller's own answer is
      # the whole of that three-valued rule.
      def consented?(desktop) = OVERRIDE.fetch(ENV.fetch("LAIN_DESKTOP", nil), desktop)

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
    # @param journal [#<<] where a sweep that raised is recorded, {QueueSurface}'s
    #   own seam and its default: the shared Null channel, so no caller guards
    #   `if journal`. A desktop surface that quietly stopped notifying is the
    #   failure this exists to make visible, so wiring a real one is worth doing.
    def initialize(command: "dunstify", shell_out_factory: Mixlib::ShellOut.public_method(:new),
                   timeout_ms: DEFAULT_TIMEOUT_MS, journal: Channel::Null::INSTANCE)
      @command = command
      @shell_out_factory = shell_out_factory
      @timeout_ms = timeout_ms
      @journal = journal
      # Faults already journaled, {QueueSurface}'s reason: keyed by the
      # failure's own text, because that is what a reader would see repeated.
      @reported = {}
      # Identity-keyed, {QueueSurface}'s reason exactly: a Pending is a plain
      # object, and one notification per pending is the contract -- a poll that
      # re-raised a dismissed one every 50ms would be its own defect.
      #
      # TOUCHED ONLY BY THE SWEEP FIBER, and saying so matters more than it did:
      # N shellout Threads now hold a reference to the same Pendings, so an
      # unsynchronised read of this Hash from one of them would be a real data
      # race. None of them can reach it -- {#fired}'s Thread is handed an argv
      # and a queue and is given nothing else to touch.
      @raised = {}.compare_by_identity
      # The notifications currently ON SCREEN: pending => the {Thread::Queue}
      # its answer will arrive on. One queue per notification, so an answer is
      # correlated to the pending it answers by construction rather than by a
      # key, and answering one says nothing about any other. Same ownership rule
      # as `@raised`, for the same reason.
      @inflight = {}.compare_by_identity
      @pruning = Approval::QueueSurface::Pruning.new
    end

    # The surface loop: sweep the PARKED set and raise a notification for each
    # pending this surface has not already asked about. Runs in its own fiber
    # beside every other surface watching the same queue (the exe hosts and
    # stops it).
    #
    # OBSERVE, NEVER CONSUME, and the distinction is the whole of T15.
    # {Approval::Queue}'s arrival queue delivers each pending to exactly ONE
    # `#dequeue` caller ({Async::Queue} delegates to a `Thread::Queue`), and
    # that caller is the human's terminal surface -- the rule
    # {Approval::QueueSurface}'s class comment already states, and the rule this
    # method used to break.
    #
    # What draining it cost, stated exactly, because the obvious reading claims
    # more than the queue does. Both surfaces park; the first arrival goes to
    # whichever parked first ({CLI::Repl::ApprovalSurfaces#watch} spawns the TTY
    # one first), and after answering it the TTY surface LEAVES the queue to ask
    # a person while this one re-parks at once -- so the next arrival came here.
    # This one then blocked inside {#decide} for dunstify's whole wait, and
    # while blocked it was not parked, so an arrival AFTER that went back to the
    # terminal (measured: prompts=2, verdicts=[true, false, true]). It is the
    # HELD call that was lost, not every later one. That changes nothing about
    # the outcome -- the run is parked on the held call, so in practice there is
    # no later one -- but the mechanism is a stolen-and-held pending, not a
    # surface that captures the queue. Measured against a live `lain chat` on
    # 2026-08-18: call two was taken here and held, so the chat pane -- the only
    # surface a `--no-nvim` session has -- rendered nothing and read nothing,
    # and the session sat until the queue's clock denied it (round 4, F18).
    #
    # Not a {QueueSurface} subclass, though this is exactly its shape, and the
    # reason is TAXONOMY rather than any runtime effect: that subclass list is
    # read as "the machine judges" ({Approval::Escalation}'s own vocabulary),
    # and this is a HUMAN surface -- a person clicks the button. Subclassing
    # would in fact have changed nothing mechanical, and a first draft of this
    # comment said otherwise: `Escalation::Surfaces::AUTOMATIC` is a frozen
    # literal, `QueueSurface.subclasses` is used only as a spec-side generator,
    # and that spec's `unaccounted` already subtracts {SURFACE}. What IS shared
    # is the seen-set and its release, which is genuinely one question
    # ({QueueSurface::Pruning}); the rest of the machinery below is a copy, and
    # the concern extraction that would end the copying is its own card.
    def watch(queue)
      loop do
        swept(queue)
        Async::Task.current.sleep(POLL_INTERVAL)
      end
    end

    # One pass, in three parts: apply the verdicts that have come back since the
    # last pass, release the seen-set entries of everything now settled, then
    # raise a notification for each parked pending this surface has neither
    # asked about nor seen settled.
    #
    # NONE OF THE THREE BLOCKS, which is the whole of what changed. The
    # enumeration is materialized and consumed with no yield point anywhere in
    # it, so it cannot go stale under a concurrent park or settle the way it
    # could when each element waited for a human -- and the pending that parks
    # last is asked about in the same pass as the one that parked first.
    #
    # Public because {#swept} is what the loop calls and a caller driving one
    # deterministic pass should not have to reach through the guard.
    def sweep(queue)
      settle_answered
      @pruning.call(@raised)
      queue.select { |pending| unraised?(pending) }.each { |pending| notify_about(pending) }
    end

    # Answer ONE pending approval INLINE: fire a notification with Approve/Deny
    # buttons and park this fiber on whichever action (or non-action) dunstify
    # reports. Fails closed on anything that isn't literally {APPROVE} -- a Deny
    # click, a dismissal, an expiry, or the shellout itself raising all deny.
    #
    # The surface loop no longer comes through here, and that is F24's fix:
    # waiting inline is exactly what let one unanswered popup hold every later
    # approval for the queue's whole window. This stays as the ONE-pending form
    # -- {Null#decide}'s mirror, and what a caller answering a single approval
    # with nothing else in flight wants -- and it shares its fail-closed rule
    # with the drain, in {#settle}, so the two cannot come to disagree about
    # what an answer means.
    #
    # @param pending [Lain::Approval::Queue::Pending]
    # @return [Boolean] whether THIS surface's decision won the race
    def decide(pending)
      settle(pending, run(approval_args(pending)))
    end

    # A plain informational notification -- no actions, nothing to decide.
    # Names the ASKING agent so a human glancing at their desktop knows who's
    # asking before they alt-tab to answer for real, at a real surface.
    #
    # Deliberately NOT markup-escaped, unlike {#approval_args}: this one offers
    # no buttons and decides nothing, so the worst a crafted `text` buys is a
    # bolded notification. Re-wording a question whose answer is given elsewhere
    # is not the same hazard as re-wording one answered by a click.
    #
    # @return [nil]
    def question(agent:, text:)
      run(question_args(agent:, text:))
      nil
    end

    private

    # {QueueSurface#swept} verbatim, and it stopped being optional here with
    # T15. A raise inside the sweep kills this FIBER, and a dead surface fiber
    # is silent -- async logs "Task may have ended with unhandled exception" to
    # a stderr nobody in a full-screen chat is reading, and every later approval
    # simply never reaches the desktop. Pre-T15 that cost the notifications for
    # arrivals this surface happened to win; post-T15 it raises the notification
    # for EVERY approval, so its silent death now deletes desktop notification
    # outright. `Async::Stop` descends from Exception, so stopping the task
    # still unwinds the loop.
    def swept(queue)
      sweep(queue)
    rescue StandardError => e
      journal_fault(e)
    end

    # Once per distinct failure, because a 50ms poll over a permanently broken
    # queue would otherwise flood the Journal with one repeated line. The record
    # wears {QueueSurface::FAULT_TYPE}'s shape rather than a second one of its
    # own, so a reader has ONE record type for "a surface fell over". The inner
    # rescue is the point of the whole method: evidence about a failure must
    # never be able to kill the fiber this guard exists to keep alive
    # ({Approval::Queue#degrade}'s answer to the same problem).
    def journal_fault(error)
      text = "#{error.class}: #{error.message}"
      return if @reported.key?(text)

      @reported[text] = true
      @journal << { "type" => Approval::QueueSurface::FAULT_TYPE, "surface" => SURFACE, "error" => text }
    rescue StandardError
      nil
    end

    # A pending is asked about ONCE, and never one a sibling surface (or the
    # queue's own clock) has already settled -- {QueueSurface#mine?}'s two
    # halves, minus the `judges?` filter this surface has no use for: dunst
    # raises every gated call, which is what a notifier is for.
    def unraised?(pending) = !pending.decided? && !@raised.key?(pending)

    # Marked BEFORE the ask, not after: the notification stays on screen for the
    # whole of dunstify's wait, and the sweeps that run in the meantime (twenty
    # a second) must not raise a second one for the pending this one is already
    # showing.
    #
    # Then asked AGAIN whether it is still undecided -- and that guard is
    # UNREACHABLE on the shipped call graph, which is said here rather than left
    # for the next reader to discover as dead-looking code. Nothing between
    # {#sweep}'s `select` and this line yields, so a pending that satisfied
    # {#unraised?} one frame ago cannot have settled since; branch coverage over
    # an ordinary parked set shows zero hits on the early return. It fires only
    # for an Enumerable that settles a pending as it yields it, which is the
    # shape its one spec example has to build by hand.
    #
    # It is kept, and not as insurance. It used to be a real guarantee: each
    # element of the snapshot waited for a human before the next was reached, so
    # every element after the first was stale by the time this got to it. T4b
    # puts a yield point back between the snapshot and the ask when it adds the
    # withdrawal, so deleting the guard now would only mean rediscovering it
    # then.
    #
    # What no guard here can close is the raise-then-settle window, and it is
    # the price of dispatching: a sibling surface that settles a pending a
    # moment after this fires leaves a live popup naming a call somebody has
    # already answered, for as long as 305s -- `-u critical` is exempt from
    # auto-expiry (see {SHELLOUT_GRACE_MS}) and only that backstop ends it.
    # SO T4 IS HALF OF F24 AND MUST NOT BE READ AS SHIPPED UNTIL T4b LANDS:
    # T4b correlates a notification handle and WITHDRAWS the popup whose pending
    # somebody else answered. Until it does, this surface leaves MORE stale
    # popups on screen than the serialised version did -- knowingly, and this is
    # the paragraph that says so.
    def notify_about(pending)
      @raised[pending] = true
      return if pending.decided?

      @inflight[pending] = fired(approval_args(pending))
    end

    # The verdicts that arrived since the last pass, applied HERE -- on the
    # sweep fiber, never on the Thread that did the waiting (see the class
    # comment for why that is not negotiable). A queue that reports itself
    # non-empty holds exactly one answer and only this fiber ever pops one, so
    # the pop below cannot block.
    def settle_answered
      @inflight.reject { |_pending, answers| answers.empty? }.each do |pending, answers|
        @inflight.delete(pending)
        settle(pending, answers.pop)
      end
    end

    # Fail-closed, in ONE place for both the inline and the dispatched path:
    # anything that isn't literally {APPROVE} -- a Deny click, one of dunst's
    # numeric close-reason codes, or the empty string {#capture} answers with
    # when the shellout raised -- is a denial.
    #
    # @return [Boolean] whether THIS surface's answer won. A sibling surface, or
    #   the queue's own clock, having settled it first makes that false, which
    #   is normal operation and the queue's own doctrine rather than an error.
    def settle(pending, answer) = pending.decide(answer == APPROVE, surface: SURFACE)

    # THE THIRD DECIDING SURFACE, so it carries the same warning the other two
    # do. A click on Approve here signs a full approval in the Journal as
    # {SURFACE}, racing the TTY prompt and the editor's list -- so a
    # notification naming only the tool and its input would let a human release
    # a file's secrets having been shown nothing about them. The sentence is
    # {Approval::Queue::Outstanding#preamble}, the terminal's and the editor's
    # own, which is the whole reason it lives on the value rather than in a
    # frontend.
    def approval_args(pending)
      ["-a", "lain", "-u", "critical", "-t", @timeout_ms.to_s,
       "-A", "#{APPROVE},Approve", "-A", "#{DENY},Deny",
       markup_safe("#{pending.outstanding.preamble}approve #{pending.tool}?"),
       markup_safe(pending.input.inspect)]
    end

    # dunst renders Pango markup, so on THIS surface alone a `<` or an `&` is
    # markup rather than text -- and every field above is model-influenced (the
    # tool name and input come from a tool_use block, the path from the file the
    # model asked to read). `inspect` escapes control bytes and quotes and does
    # not touch either character, which is why it is not enough here and is
    # enough everywhere else.
    #
    # The cosmetic cost is real and is the smaller one: a dunst configured
    # `markup = strip` shows `&lt;` literally rather than `<`. A notification
    # that reads slightly wrong beats one a crafted path can re-word.
    def markup_safe(text) = CGI.escapeHTML(text)

    def question_args(agent:, text:)
      ["-a", "lain", "-u", "normal", "-t", @timeout_ms.to_s, "#{agent} asks", text]
    end

    # One notification, DISPATCHED and not waited on. The Thread runs the
    # blocking shellout and pushes exactly one answer onto the queue handed
    # back; that is the whole of its job. It touches no state of this object's
    # and decides no {Pending}, which is what keeps `@raised`, `@inflight` and
    # every Pending single-fiber-owned.
    #
    # @return [Thread::Queue] where this notification's answer will arrive
    def fired(args)
      answers = Thread::Queue.new
      # Not joined: #capture's own timeout bounds this Thread's lifetime, and
      # the queue is what actually carries the result back.
      Thread.new { answers.push(capture(args)) }
      answers
    end

    # The inline form, for {#decide} and {#question}: dispatch, then park THIS
    # fiber on the answer. See the class comment -- `Thread::Queue#pop` is the
    # fiber-scheduler-safe bridge back, and an ordinary blocking wait where
    # there is no reactor at all.
    def run(args) = fired(args).pop

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
