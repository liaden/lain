# frozen_string_literal: true

require "async"
require "cgi/escape"
require "mixlib/shellout"
require "securerandom"

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
  # result. It belongs to {Dispatch} and reads only what {Dispatch} was built
  # with, writes none of it, and decides no {Pending} -- so nothing it can reach
  # is state a sweep also mutates.
  # {#sweep} DISPATCHES a notification per parked pending and drains the
  # finished ones on a later pass, so a call that parks while an earlier
  # notification is still on screen gets its own popup at once instead of in
  # five minutes' time (QA round 5, F24: `dunstify -A` blocks for the queue's
  # whole 300s window, so waiting inline meant one approval per window however
  # many a turn gated).
  #
  # F24's other half is that a popup went on naming a call somebody had already
  # answered. Each notification therefore carries an id this surface CHOOSES
  # (`-r`, see {HANDLE_ID_FLOOR}) rather than one read back off stdout, and
  # {#withdraw_settled} closes the popup of any pending a sibling surface
  # settled while dunstify was still blocked on it. That withdrawal is ordered
  # from the sweep fiber and is best-effort throughout: a desktop that cannot
  # close a notification degrades to leaving it up, never to a surface that
  # raises.
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

    # {#withdraw}'s own clock, and deliberately NOT {#shellout_timeout_seconds}.
    # `dunstify -C` asks nothing of a human: it is a D-Bus round trip that
    # returned instantly in every measurement, so the 305s backstop an approval
    # needs would, against a WEDGED dunst, park one thread per stale popup for
    # five minutes. This bounds it at something a stuck desktop cannot hoard.
    WITHDRAW_TIMEOUT_SECONDS = 5.0

    # Between sweeps of the parked set. {QueueSurface::DEFAULT_POLL_INTERVAL}'s
    # value and its reason: a surface is a sibling fiber, so the sleep is a
    # scheduler yield rather than a wall-clock stall.
    POLL_INTERVAL = Approval::QueueSurface::DEFAULT_POLL_INTERVAL

    # The floor of the id space {Onscreen} allocates `-r` ids from, and the
    # width above it. Both are about NOT COLLIDING, with two different parties.
    #
    # With the DESKTOP: dunst numbers its own notifications from a small
    # counter that climbs by one per notification (measured 2026-08-19 with
    # `--print-id`: 191, then 192), and a self-assigned `-r` id does NOT
    # advance it -- an id from up here is one dunst will not reach, so
    # {#withdraw} can never close a notification belonging to the human's
    # browser or music player.
    #
    # With another LAIN: a fixed base plus a per-process counter would hand two
    # concurrent sessions on one desktop the same ids, so one session's
    # withdrawal would close the other's popup -- the shared-scratchpad failure
    # in a different costume. Drawing each id at random from a space this wide
    # makes that collision negligible without any coordination between
    # processes, which is the only kind available here.
    HANDLE_ID_FLOOR = 1_000_000
    HANDLE_ID_SPACE = 1_000_000_000

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
      # `command` and `shell_out_factory` are NOT kept: {Dispatch} owns the
      # subprocess and nothing up here reads either one. `timeout_ms` stays
      # because the argv builders spell it into `-t`.
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
      # race. None of them can reach it -- a {Dispatch} Thread is handed an argv
      # and a queue and is given nothing else to touch.
      @raised = {}.compare_by_identity
      # The notifications currently on screen and their dunst handles. Same
      # ownership rule as `@raised` and for the same reason -- TOUCHED ONLY BY
      # THE SWEEP FIBER -- and it binds harder here, because this is the handle
      # map {#withdraw_settled} reads to decide which popup to close.
      @onscreen = Onscreen.new
      # Withdrawal faults, drained and journaled by the sweep -- see {Withdrawals}.
      @withdrawals = Withdrawals.new
      @dispatch = Dispatch.new(command:, shell_out_factory:, timeout_ms:)
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

    # One pass, in four parts: apply the verdicts that have come back since the
    # last pass, withdraw the popups whose pending somebody else answered in the
    # meantime, release the seen-set entries of everything now settled, then
    # raise a notification for each parked pending this surface has neither
    # asked about nor seen settled.
    #
    # NONE OF THE FOUR BLOCKS, and that is still the whole of what T4 changed.
    # The enumeration is materialized and consumed with no yield point anywhere
    # in it, so it cannot go stale under a concurrent park or settle the way it
    # could when each element waited for a human -- and the pending that parks
    # last is asked about in the same pass as the one that parked first. T4b's
    # withdrawal keeps that property rather than spending it: it DISPATCHES
    # `dunstify -C` the same way a notification is dispatched, so ordering one
    # costs this fiber a `Thread.new` and nothing else.
    #
    # Draining comes first as a small economy, NOT as an invariant -- said
    # plainly because an earlier edition of this comment called it load-bearing
    # and a reviewer disproved that by swapping the two lines and watching the
    # suite stay green. A pending whose own notification has already answered is
    # gone from the handle map by the time {#withdraw_settled} looks, so this
    # order saves a `-C` for a popup that closed itself; the other order merely
    # spends one, and a `-C` for an id dunst no longer holds is a silent exit-0
    # no-op (measured). Nothing depends on it.
    #
    # Public because {#swept} is what the loop calls and a caller driving one
    # deterministic pass should not have to reach through the guard.
    def sweep(queue)
      settle_answered
      withdraw_settled
      @withdrawals.faults.each { |fault| journal_fault(fault) }
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
      settle(pending, @dispatch.run(approval_args(pending, Onscreen.next_id)))
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
      @dispatch.run(question_args(agent:, text:))
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
    # every element after the first was stale by the time this got to it.
    #
    # T4b was expected to put a yield point back here when it added the
    # withdrawal, and DID NOT -- said plainly because the previous edition of
    # this comment promised it would. Withdrawal dispatches rather than waits
    # ({#withdraw}), so {#sweep} still runs start to finish without yielding and
    # this guard is still reachable only from an Enumerable that settles a
    # pending as it yields it. It stays anyway: it costs one predicate on a path
    # that already spawns a process, and its one spec example is what would
    # notice if a later card spent the no-yield property without saying so.
    #
    # What no guard here can close is the raise-then-settle window: a sibling
    # surface that settles a pending a moment after this fires leaves a popup
    # naming a call somebody has already answered. That popup is no longer
    # permanent -- {#withdraw_settled} closes it on the next sweep, 50ms later,
    # which together with T4 is the whole of F24. `-u critical` is exempt from
    # auto-expiry (see {SHELLOUT_GRACE_MS}), so before T4b landed only the 305s
    # backstop ended it.
    def notify_about(pending)
      @raised[pending] = true
      return if pending.decided?

      @onscreen.add(pending) { |id| @dispatch.fired(approval_args(pending, id)) }
    end

    # Close the popups whose pending somebody else answered while dunstify was
    # still blocked on it, and leave every other one alone.
    #
    # ORDERED FROM THIS FIBER, NEVER FROM A SHELLOUT THREAD, which is T4's
    # constraint widened to {Onscreen}'s new job: it is the handle map as well
    # as the answer map now, and a Thread reading it to decide what to close
    # would be the data race `@raised`'s own comment rules out. The Threads are
    # handed an argv and a queue and are given nothing else to touch.
    #
    # {Onscreen#withdrawing} keeps the entry rather than dropping it, because
    # the notification is withdrawn and its dunstify is not: closing the popup
    # out from under a blocked `dunstify -A` makes it report a close reason
    # (measured against real dunst: `3`, "closed via the API"), and that answer
    # is still owed a drain. It lands in {#settle}'s fail-closed path and
    # reaches {Approval::Queue::Pending#decide} as a deny that RETURNS FALSE,
    # the pending being already decided. That losing return is the
    # correlation's own witness and there is a spec on it.
    # EVERY settled pending, including one the QUEUE'S OWN CLOCK denied. An
    # earlier edition of this method excluded `timed_out?` on the ground that
    # "the timeout path already reaps itself", and that ground was FALSE. Three
    # readings were taken before the real rule came out, so all of it is written
    # down: this is the kind of wrong that gets rediscovered otherwise, and it
    # has already been rediscovered three times.
    #
    # - {SHELLOUT_GRACE_MS} reaps the PROCESS, not the POPUP. A notification
    #   survives SIGTERM and SIGKILL of the dunstify that raised it (measured:
    #   process dead, `dunstctl count displayed` still 1). Only an explicit
    #   close removes it.
    # - The client's `-t` IS honoured, and {#approval_args} always passes one.
    #   Measured on an ACTIVE desktop it tracks the flag exactly: -t 2000 ->
    #   2022ms, -t 5000 -> 5057ms, close reason 1.
    # - BUT `idle_threshold = 120` (this dunstrc) makes dunst STOP EXPIRING
    #   ANYTHING while nobody has touched the keyboard or mouse for 120s. That
    #   is the discriminator, not urgency: a low-urgency twin raised at the same
    #   instant blew through its own `-t` identically, while the control -- two
    #   `-u critical -t 2000` differing only by the `transient` hint -- expired
    #   at 2.1s transient against still-lit at 6.4s plain.
    #
    # AND AN UNANSWERED APPROVAL IS BY CONSTRUCTION AN IDLE DESKTOP. The queue's
    # 300s window is 2.5x that threshold, so in the operative case -- the only
    # case this surface exists for -- the popup never expires at all, and once
    # the grace period reaps the process nothing else can ever close it. So
    # there are TWO independent leaks, and `-t` closes neither of them.
    #
    # Do not "fix" this by marking the notification `transient` to bypass the
    # idle rule (dunstrc's `[transient_disable]` is commented out, so it would
    # work): a transient approval popup silently vanishes while the human is
    # away, which is precisely what `-u critical` is here to prevent.
    #
    # Withdrawing depends on expiry not at all, which is why it closes both. The
    # second-order gap it also closes: {DEFAULT_TIMEOUT_MS} derives from the
    # queue's window but is pinned only as `>=`, so a {Approval::Queue} built
    # with a SHORTER timeout denies on its own clock while this surface's popup
    # stays lit for the rest of ITS window. The `>=` is deliberate -- a longer
    # surface window is legitimate, a shorter one would misattribute the denial.
    #
    # And it races nothing, which is what the old exclusion was really worried
    # about: `decided?` is the precondition, so the verdict is already in. This
    # closes a popup; it decides nothing.
    def withdraw_settled
      @onscreen.withdrawing(&:decided?).each { |id| withdraw(id) }
    end

    # BEST-EFFORT, in `up.rb`'s `@tmux.run`-vs-`@tmux.act` sense. `-C` goes
    # through the SAME {Dispatch} -- so the same binary -- rather than reaching
    # for `dunstctl`, which buys three things: {.for}'s `on_path?` consent check
    # already covers it, the injected `shell_out_factory` seam already observes
    # it, and a desktop with dunstify but no dunstctl is not a desktop this
    # surface silently stops withdrawing on. Dispatched, not waited on, for the
    # class comment's reason: a D-Bus round trip to a wedged dunst must not
    # stall the reactor.
    #
    # Its ANSWER is nobody's business -- `-C` prints nothing on success -- but
    # its FAILURE is, so the result goes to {Withdrawals} for the sweep to
    # journal rather than being dropped on the floor.
    #
    # Every way this can fail degrades to exactly what T4 shipped: the rescue in
    # {Dispatch} turns an absent or broken binary into a reported fault rather
    # than a raise, and a `-C` naming an id dunst no longer holds is a no-op
    # that exits 0 (measured). The popup stays up, which is the worse UX this
    # card exists to improve -- and never the failure that matters, which would
    # be raising out of the sweep and leaving the session with no desktop
    # approvals at all.
    def withdraw(id) = @withdrawals.add(@dispatch.attempted(["-C", id.to_s]))

    # The verdicts that arrived since the last pass, applied HERE -- on the
    # sweep fiber, never on the Thread that did the waiting (see the class
    # comment for why that is not negotiable). A queue that reports itself
    # non-empty holds exactly one answer and only this fiber ever pops one, so
    # the pop below cannot block.
    def settle_answered
      @onscreen.answered.each { |pending, answer, id| settle_closed(pending, answer, id) }
    end

    # The popup is normally GONE by the time its answer arrives: dunst closed it
    # in order to produce that answer, whether by a click, a dismissal or its own
    # `-t`. The exception is a dunstify that was KILLED rather than answered --
    # {SHELLOUT_GRACE_MS}'s backstop SIGTERMs then SIGKILLs, and a killed
    # dunstify leaves its notification on screen (measured). Then `id` is still
    # set, the popup is still lit, and nothing else will ever close it.
    #
    # Only worth a `-C` when somebody else already decided the pending, which is
    # the case where the popup is both stale AND still ours to close. On the
    # ordinary path this surface's own answer wins, `decided?` is false until
    # {#settle} runs a line later, and no withdrawal is issued -- which is what
    # keeps a `-C` off the end of every approval.
    #
    # Narrow residual, and it is correct rather than merely tolerated: if THIS
    # surface's own kill-deny wins the race (only reachable with a `timeout_ms`
    # shorter than the queue's, which is specs and never the shipped wiring),
    # `decided?` is false, no `-C` is issued and the handle is simply dropped.
    # The deny is this surface's to make and the popup is already gone with the
    # process that owned it.
    def settle_closed(pending, answer, id)
      withdraw(id) if id && pending.decided?
      settle(pending, answer)
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
    # `-r` is the whole of T4b's correlation: dunst honours an id the CALLER
    # picks for a notification it has never seen (measured -- two popups raised
    # at 900001 and 900002 displayed side by side and closed independently), so
    # the handle needs nothing read back off stdout. The inline {#decide} passes
    # one too, though nothing will ever withdraw it: one argv builder that
    # cannot drift beats a second one that only differs by a flag.
    def approval_args(pending, id)
      ["-a", "lain", "-u", "critical", "-t", @timeout_ms.to_s, "-r", id.to_s,
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

    # Running `dunstify` OFF the reactor thread. This is the one job in the file
    # that is about PROCESSES rather than about approvals, and the class comment
    # spends three paragraphs on why it cannot be done inline: `dunstify -A`
    # blocks for the human's whole wait, and Mixlib's internal wait is not a
    # primitive this project has verified as Fiber::SchedulerInterface-safe, so
    # trusting it not to stall every other fiber in the process is not a chance
    # worth taking for a notifications adapter.
    #
    # Every Thread it starts does exactly one thing: run one command and push
    # one result. It reads only what it was constructed with, writes none of it,
    # and decides no {Approval::Queue::Pending} -- which is what keeps `@raised`,
    # {Onscreen} and every Pending single-fiber-owned.
    class Dispatch
      def initialize(command:, shell_out_factory:, timeout_ms:)
        @command = command
        @shell_out_factory = shell_out_factory
        @timeout_ms = timeout_ms
      end

      # One notification, dispatched and not waited on.
      #
      # @return [Thread::Queue] where this notification's answer will arrive
      def fired(args) = dispatched { capture(args) }

      # The inline form, for {Notify#decide} and {Notify#question}: dispatch,
      # then park THIS fiber on the answer. `Thread::Queue#pop` is the
      # fiber-scheduler-safe bridge back, and an ordinary blocking wait where
      # there is no reactor at all.
      def run(args) = fired(args).pop

      # A command whose ANSWER is nobody's business but whose FAILURE is: the
      # queue carries the exception a broken `-C` raised, or nil when it worked.
      #
      # @return [Thread::Queue] carrying one StandardError, or nil
      def attempted(args) = dispatched { faulted(args) }

      private

      # Not joined: the shellout's own timeout bounds the Thread's lifetime, and
      # the queue is what actually carries the result back.
      def dispatched
        results = Thread::Queue.new
        Thread.new { results.push(yield) }
        results
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

      # The same call, reporting rather than swallowing. `-C` prints nothing on
      # success (measured), so stdout cannot say whether it worked and the
      # exception is the only signal there is.
      def faulted(args)
        @shell_out_factory.call(@command, *args, timeout: WITHDRAW_TIMEOUT_SECONDS).run_command
        nil
      rescue StandardError => e
        e
      end

      # dunstify's own `-t` (milliseconds) plus {SHELLOUT_GRACE_MS}, in seconds,
      # for `Mixlib::ShellOut`'s `timeout:` -- deliberately looser than `-t` so
      # a well-behaved dunstify reports its OWN real close reason first; this is
      # only the backstop for one confirmed not to.
      def shellout_timeout_seconds = (@timeout_ms + SHELLOUT_GRACE_MS) / 1000.0
    end

    # The `-C` shellouts dispatched and not yet heard back from.
    #
    # Withdrawal is best-effort, but best-effort must not mean INVISIBLE. A
    # desktop where `-C` is unsupported, or where dunstify has gone missing
    # between the raise and the withdrawal, would otherwise fail silently for
    # the whole session -- which is exactly the "a surface quietly stopped
    # working" failure {Notify#journal_fault} exists to make visible, and which
    # dropping the result queue on the floor opted out of. So each attempt's
    # outcome crosses back on its own queue and the SWEEP reports it, on the
    # sweep fiber, like every other result in this file.
    class Withdrawals
      def initialize = @inflight = []

      def add(faults) = @inflight << faults

      # The failures of every withdrawal that has finished since the last pass.
      # Ones still running stay, so a wedged `-C` is waited for rather than
      # reported as a success.
      #
      # @return [Array<StandardError>]
      def faults
        done, waiting = @inflight.partition { |queue| !queue.empty? }
        @inflight = waiting
        done.filter_map(&:pop)
      end
    end

    # The notifications this surface currently has on screen, keyed by the
    # {Approval::Queue::Pending} each one asks about. It exists as an object
    # because it holds an invariant {Notify} would otherwise state three times:
    # a notification is ANSWERED once and WITHDRAWN once, and those are
    # different events that can happen in either order to the same handle.
    #
    # Identity-keyed for {QueueSurface}'s reason -- a Pending is a plain object
    # -- and single-fiber-owned for T4's: every method here is called from the
    # sweep and from nowhere else, so none of it is reachable from the N
    # shellout Threads that hold references to the same Pendings. Those Threads
    # are handed an argv and a queue and are given nothing else to touch.
    class Onscreen
      # One notification on screen: the id this surface told dunst to use
      # (`-r`), and the {Thread::Queue} its answer will arrive on. One queue per
      # notification, so an answer is correlated to the pending it answers by
      # construction rather than by a key, and answering one says nothing about
      # any other.
      #
      # The id is CHOSEN rather than read back, which is what keeps
      # {Notify#capture}'s single-value stdout contract intact: `--print-id`
      # writes the id onto the same stream the action key arrives on (measured:
      # "191\n2" for a notification carrying `-A` actions), so parsing it would
      # have made every approval read as "not approve" and silently deny.
      #
      # `id` goes nil once the popup has been withdrawn, which is NOT the same
      # as the entry going away -- see {#withdrawing}.
      Notification = Data.define(:id, :answers) do
        def showing? = !id.nil?
        def withdrawn = with(id: nil)
      end

      # Drawn fresh per notification rather than counted up from a base: see
      # {HANDLE_ID_FLOOR} for the two collisions that avoids. On the class
      # because the inline {Notify#decide} needs an id for its `-r` too, and
      # holds no handle here for anything to withdraw.
      def self.next_id = HANDLE_ID_FLOOR + SecureRandom.random_number(HANDLE_ID_SPACE)

      def initialize = @notifications = {}.compare_by_identity

      # Mint the id, hand it to the caller to raise the notification with, and
      # remember the handle its answer will come back on. The id is yielded
      # rather than returned because the argv needs it BEFORE there is anything
      # to remember -- and minting it here is what keeps {HANDLE_ID_FLOOR}'s two
      # anti-collision arguments in one place.
      def add(pending)
        id = self.class.next_id
        @notifications[pending] = Notification.new(id:, answers: yield(id))
      end

      # The verdicts that have arrived since the last pass, taken OUT of the map
      # as they are handed over: this surface owes each answer exactly one
      # application. A queue that reports itself non-empty holds exactly one
      # answer and only the sweep fiber ever pops one, so `pop` cannot block.
      #
      # The id rides along, still set when this notification was never
      # withdrawn, so the caller can tell an answer that CLOSED its popup from
      # one that left it lit ({Notify#settle_closed}).
      #
      # @return [Array<Array(Approval::Queue::Pending, String, Integer, nil)>]
      def answered
        finished = @notifications.reject { |_pending, notification| notification.answers.empty? }
        finished.each_key { |pending| @notifications.delete(pending) }
        finished.map { |pending, notification| [pending, notification.answers.pop, notification.id] }
      end

      # The ids of the popups still on screen whose pending the block says is
      # stale, marked withdrawn as they are handed over so a 50ms poll cannot
      # re-issue the same `-C` twenty times a second.
      #
      # The entry is REPLACED, not deleted, and that is the whole reason
      # `showing?` exists rather than the map simply losing the row: the popup
      # is gone but its `dunstify` is still running and still owes an answer,
      # which {#answered} must still collect. Dropping the row here would leak
      # that answer and the Thread carrying it.
      #
      # @return [Array<Integer>] ids to close
      def withdrawing
        going = @notifications.select { |pending, notification| notification.showing? && yield(pending) }
        going.each { |pending, notification| @notifications[pending] = notification.withdrawn }
        going.map { |_pending, notification| notification.id }
      end
    end

    # ON THE SIZE OF THIS FILE, ruled at review rather than left to argument:
    # five objects in one file is NOT yet too many. {Dispatch}, {Withdrawals},
    # {Onscreen} and {Null} each hold exactly one invariant, and a reader finds
    # every one of them from {#sweep}. THE NEXT ADDITION SHOULD OPEN A
    # `lain/notify/` SUBTREE rather than becoming a sixth nested class here.

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
