# frozen_string_literal: true

require "async"
require "cgi/escape"
require "mixlib/shellout"
require "securerandom"

module Lain
  # A desktop-notification surface over `dunstify`, joining {Approval::Queue}
  # at the same seam {Frontend::ApprovalPolicy} does. It OBSERVES the parked set
  # and never consumes an arrival; two surfaces racing over one
  # {Approval::Queue::Pending} is normal, first answer wins. {#question} is
  # unrelated to the queue -- an informational popup for `ask_human`, answered
  # at a real surface rather than by a click.
  #
  # `dunstify -A action,label` BLOCKS the dunstify PROCESS until the human
  # clicks, dismisses, or its `-t` expires (confirmed by hand: `dunstify -t 1000
  # -A a,A -A b,B SUMMARY BODY` took the full second and printed dunst's own
  # numeric close-reason code, never one of our action identifiers). That wait
  # runs on a dedicated Thread rather than inline in the calling Fiber:
  # Mixlib::ShellOut's internal wait is not a primitive this project has
  # verified as Fiber::SchedulerInterface-safe the way Kernel#sleep and IO#read
  # are, and stalling the whole reactor thread is not a chance worth taking for
  # a notifications adapter. The bridge back is a `Thread::Queue`, whose
  # blocking pop the fiber scheduler hooks as a FIBER park (confirmed against
  # this project's `async` 2.42, in `Async::Scheduler#block`/`#unblock`) and
  # which is an ordinary blocking wait where no reactor is running at all. Each
  # such Thread runs one shellout and pushes one result: it reads only what
  # {Dispatch} was built with and decides no Pending, so nothing it can reach is
  # state the sweep also mutates.
  #
  # Waiting INLINE is what {#sweep} exists to avoid: `dunstify -A` blocks for
  # the queue's whole 300s window, so an inline wait meant one approval per
  # window however many a turn gated (QA round 5). Dispatching per parked
  # pending instead left popups naming calls somebody had already answered, so
  # each notification carries an id this surface CHOOSES (`-r`, see
  # {HANDLE_ID_FLOOR}) and {#withdraw_settled} closes the popup of any pending a
  # sibling surface settled meanwhile. Withdrawal is best-effort throughout: a
  # desktop that cannot close a notification leaves it up, never raises.
  #
  # Applying the verdict stays on the sweep fiber, and that is a constraint
  # rather than a taste. {Approval::Queue::Pending#decide}'s lock-free
  # single-shot resolution is safe only because two FIBERS cannot both pass the
  # guard -- which two OS threads do not satisfy -- and `Promise#resolve` reaches
  # an `Async::Condition` that resumes reactor-owned fibers, a `FiberError` from
  # a foreign thread. So the verdict crosses back as data and this fiber decides.
  #
  # {#decide} has no caller in `lib/` or `exe/` and is not dead: it is the
  # one-pending INLINE form the loop deliberately stopped using, and it is
  # spec-facing -- {Null#decide}'s mirror and the `:desktop` real-dunstify
  # probe's only entry.
  class Notify
    # This surface's name in the approval Journal, alongside "tty".
    SURFACE = "dunst"

    # The `-A` action identifiers this surface offers. Neither is numeric, so
    # neither can collide with one of dunstify's own close-reason codes (1
    # expired, 2 dismissed, 3 closed via the API, 4 undefined) -- the signal for
    # "nothing was clicked" is exactly "the answer isn't APPROVE".
    APPROVE = "approve"
    DENY = "deny"

    # Derived from the queue's OWN window, never a second opinion of it. A
    # surface backstop shorter than the queue's window would deny the shared
    # Pending on the surface's clock and journal that denial as surface: "dunst"
    # with a latency measuring nothing real -- corrupted evidence on a bench
    # where decision latency IS the experiment record. Referencing the source of
    # truth rather than copying its value is what keeps the two from drifting;
    # see the spec pinning this inequality.
    DEFAULT_TIMEOUT_MS = Approval::Queue::DEFAULT_TIMEOUT * 1000

    # A backstop past dunstify's OWN `-t`, verified load-bearing by hand: a
    # critical-urgency notification (what {#decide} sends, deliberately, so an
    # approval prompt does not silently vanish) is exactly the case the
    # freedesktop notification spec exempts from auto-expiry, and this desktop's
    # dunst honors that -- a live `dunstify -u critical -t 1200 -A ...` sat past
    # its window with no human present, an orphaned process, until killed by
    # hand. Mixlib::ShellOut's own `timeout:` is the guarantee `-t` is not: it
    # SIGTERMs then SIGKILLs the whole process group,
    # {Mixlib::ShellOut::CommandTimeout} lands in {Dispatch}'s rescue, and the
    # fail-closed deny fires as it would for a real dismissal.
    #
    # That group is PER CHILD, which is what makes the backstop safe with N
    # notifications in flight. `Mixlib::ShellOut`'s forked child calls
    # `Process.setsid` before exec (3.4.10, `shellout/unix.rb:337`), so its pgid
    # is its own pid and `child_pgid` is `-@child_pid` -- one notification's
    # reaper cannot reach another's dunstify. A shared group would have made the
    # first timeout kill every live popup on the screen.
    #
    # Ordinarily this never fires first: with `DEFAULT_TIMEOUT_MS` at the
    # queue's own window, {Approval::Queue}'s `Async::Task#with_timeout` expires
    # and denies (surface: "timeout") a tick before this one could, so the QUEUE
    # attributes the denial to itself. This grace only outlives that, to reap
    # the orphaned dunstify afterward -- not to race the queue for who decides.
    SHELLOUT_GRACE_MS = 5_000

    # {#withdraw}'s own clock, deliberately NOT {Dispatch}'s approval timeout.
    # `dunstify -C` asks nothing of a human: it is a D-Bus round trip that
    # returned instantly in every measurement, so the 305s backstop an approval
    # needs would, against a WEDGED dunst, park one thread per stale popup for
    # five minutes. This bounds it at something a stuck desktop cannot hoard.
    WITHDRAW_TIMEOUT_SECONDS = 5.0

    # Between sweeps of the parked set; a surface is a sibling fiber, so the
    # sleep is a scheduler yield rather than a wall-clock stall.
    POLL_INTERVAL = Approval::QueueSurface::DEFAULT_POLL_INTERVAL

    # The id space {Onscreen} allocates `-r` ids from. Both figures are about
    # NOT COLLIDING, with two different parties.
    #
    # With the DESKTOP: dunst numbers its own notifications from a small counter
    # climbing by one per notification (measured 2026-08-19 with `--print-id`:
    # 191, then 192), and a self-assigned `-r` id does NOT advance it -- an id
    # from up here is one dunst will not reach, so {#withdraw} can never close a
    # notification belonging to the human's browser or music player.
    #
    # With another LAIN: a fixed base plus a per-process counter would hand two
    # concurrent sessions on one desktop the same ids, so one session's
    # withdrawal would close the other's popup. Drawing each id at random from a
    # space this wide makes that negligible with no coordination between
    # processes, which is the only kind available here.
    HANDLE_ID_FLOOR = 1_000_000
    HANDLE_ID_SPACE = 1_000_000_000

    # What `LAIN_DESKTOP` forces, in either direction; any other value (unset
    # included) leaves the caller's own answer standing.
    OVERRIDE = { "1" => true, "0" => false }.freeze

    class << self
      # CONSENT, then capability -- in that order, and the order is the fix.
      # `dunstify` on PATH says the desktop CAN be reached; it never says this
      # process MAY reach it. Presence was read as consent until 2026-08-05,
      # when nine notifications reading "lain is waiting for a verdict" landed
      # on a working human's screen from agents' trees -- because every spec,
      # probe and subagent in this repository runs on the SAME machine, with the
      # same PATH, as the human it would interrupt. So `desktop:` defaults to
      # OFF and whoever owns the human's attention says so; {CLI::FleetWindows.for}
      # is the sibling of that rule.
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
      # the flag is one run's; the `fetch` default is the whole three-valued rule.
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
    # @param journal [#<<] where a sweep that raised is recorded, defaulting to
    #   the shared Null channel so no caller guards `if journal`. A desktop
    #   surface that quietly stopped notifying is the failure this makes visible.
    def initialize(command: "dunstify", shell_out_factory: Mixlib::ShellOut.public_method(:new),
                   timeout_ms: DEFAULT_TIMEOUT_MS, journal: Channel::Null::INSTANCE)
      # `command` and `shell_out_factory` are NOT kept: {Dispatch} owns the
      # subprocess. `timeout_ms` stays because the argv builders spell it into `-t`.
      @timeout_ms = timeout_ms
      @journal = journal
      # Keyed by the failure's own text: that is what a reader would see repeated.
      @reported = {}
      # Identity-keyed, a Pending being a plain object, and TOUCHED ONLY BY THE
      # SWEEP FIBER -- as is `@onscreen`, which binds harder still because it is
      # the handle map {#withdraw_settled} reads. N shellout Threads hold
      # references to the same Pendings, so an unsynchronised read of either
      # from one of them would be a real data race; none can reach them, being
      # handed an argv and a queue and nothing else to touch.
      @raised = {}.compare_by_identity
      @onscreen = Onscreen.new
      @withdrawals = Withdrawals.new
      @dispatch = Dispatch.new(command:, shell_out_factory:, timeout_ms:)
      @pruning = Approval::QueueSurface::Pruning.new
    end

    # The surface loop, in its own fiber beside every other surface watching the
    # same queue (the exe hosts and stops it).
    #
    # OBSERVE, NEVER CONSUME. {Approval::Queue}'s arrival queue delivers each
    # pending to exactly ONE `#dequeue` caller, and that caller is the human's
    # terminal surface -- the rule this method used to break. What draining it
    # cost, stated exactly because the obvious reading claims more than the
    # queue does: it was the HELD call that was lost, not every later one. Both
    # surfaces park, the first arrival goes to whichever parked first, and this
    # one then blocked inside {#decide} for dunstify's whole wait, so an arrival
    # after that went back to the terminal (measured: prompts=2, verdicts=[true,
    # false, true]). In practice there is no later one, because the run is
    # parked on the held call: measured against a live `lain chat` on
    # 2026-08-18, call two was taken here and held, the chat pane -- a
    # `--no-nvim` session's only surface -- rendered nothing, and the session sat
    # until the queue's clock denied it.
    #
    # Not a {QueueSurface} subclass, and the reason is TAXONOMY rather than any
    # runtime effect: that subclass list reads as "the machine judges", and a
    # person clicks this button. What IS genuinely shared is the seen-set and
    # its release ({QueueSurface::Pruning}); the rest below is a copy.
    def watch(queue)
      loop do
        swept(queue)
        Async::Task.current.sleep(POLL_INTERVAL)
      end
    end

    # NONE OF THE FOUR STEPS BLOCKS, and that is the whole of the non-blocking
    # sweep. The enumeration is materialized and consumed with no yield point in
    # it, so it cannot go stale under a concurrent park or settle, and the
    # pending that parks last is asked about in the same pass as the one that
    # parked first. The withdrawal keeps that property rather than spending it:
    # it DISPATCHES `dunstify -C` the way a notification is dispatched, costing
    # this fiber a `Thread.new` and nothing else.
    #
    # Draining first is a small economy, NOT an invariant -- said plainly
    # because an earlier edition called it load-bearing and a reviewer disproved
    # that by swapping the two lines and watching the suite stay green. A `-C`
    # for an id dunst no longer holds is a silent exit-0 no-op (measured).
    #
    # Public so a caller driving one deterministic pass need not reach through
    # {#swept}'s guard.
    def sweep(queue)
      settle_answered
      withdraw_settled
      @withdrawals.faults.each { |fault| journal_fault(fault) }
      @pruning.call(@raised)
      queue.select { |pending| unraised?(pending) }.each { |pending| notify_about(pending) }
    end

    # Answer ONE pending approval INLINE: fire a notification with Approve/Deny
    # buttons and park this fiber on whichever action (or non-action) dunstify
    # reports. Fails closed on anything that isn't literally {APPROVE}.
    #
    # The surface loop no longer comes through here -- waiting inline is exactly
    # what let one unanswered popup hold every later approval for the queue's
    # whole window. It stays as the ONE-pending form, sharing its fail-closed
    # rule with the drain in {#settle} so the two cannot come to disagree about
    # what an answer means.
    #
    # @param pending [Lain::Approval::Queue::Pending]
    # @return [Boolean] whether THIS surface's decision won the race
    def decide(pending)
      settle(pending, @dispatch.run(approval_args(pending, Onscreen.next_id)))
    end

    # A plain informational notification -- no actions, nothing to decide. Names
    # the ASKING agent so a human glancing at their desktop knows who is asking
    # before they alt-tab to answer for real.
    #
    # Deliberately NOT markup-escaped, unlike {#approval_args}: this offers no
    # buttons and decides nothing, so the worst a crafted `text` buys is a
    # bolded notification. Re-wording a question whose answer is given elsewhere
    # is not the hazard that re-wording one answered by a click is.
    #
    # @return [nil]
    def question(agent:, text:)
      @dispatch.run(question_args(agent:, text:))
      nil
    end

    private

    # A raise inside the sweep kills this FIBER, and a dead surface fiber is
    # silent -- async logs "Task may have ended with unhandled exception" to a
    # stderr nobody in a full-screen chat is reading, and every later approval
    # simply never reaches the desktop. `Async::Stop` descends from Exception,
    # so stopping the task still unwinds the loop.
    def swept(queue)
      sweep(queue)
    rescue StandardError => e
      journal_fault(e)
    end

    # Once per distinct failure, because a 50ms poll over a permanently broken
    # queue would otherwise flood the Journal with one repeated line. It wears
    # {QueueSurface::FAULT_TYPE}'s shape so a reader has ONE record type for "a
    # surface fell over". The inner rescue is the point of the method: evidence
    # about a failure must never kill the fiber this guard keeps alive.
    def journal_fault(error)
      text = "#{error.class}: #{error.message}"
      return if @reported.key?(text)

      @reported[text] = true
      @journal << { "type" => Approval::QueueSurface::FAULT_TYPE, "surface" => SURFACE, "error" => text }
    rescue StandardError
      nil
    end

    # Asked about ONCE, and never one a sibling surface or the queue's own clock
    # has settled. {QueueSurface#mine?} minus its `judges?` filter: dunst raises
    # every gated call, which is what a notifier is for.
    def unraised?(pending) = !pending.decided? && !@raised.key?(pending)

    # Marked BEFORE the ask: the notification stays on screen for the whole of
    # dunstify's wait, and the sweeps that run meanwhile (twenty a second) must
    # not raise a second one for the pending this one is already showing.
    #
    # The `decided?` guard below is UNREACHABLE on the shipped call graph, said
    # here so the next reader does not delete it as dead-looking code. Nothing
    # between {#sweep}'s `select` and this line yields, so a pending that
    # satisfied {#unraised?} one frame ago cannot have settled since; branch
    # coverage over an ordinary parked set shows zero hits. It fires only for an
    # Enumerable that settles a pending as it yields it -- and that one spec
    # example is what would notice a later card spending the no-yield property.
    #
    # What no guard here can close is the raise-then-settle window: a sibling
    # surface settling a pending a moment after this fires leaves a popup naming
    # an answered call. {#withdraw_settled} closes it on the next sweep, 50ms
    # later; before withdrawal existed only the 305s backstop ended it, `-u
    # critical` being exempt from auto-expiry (see {SHELLOUT_GRACE_MS}).
    def notify_about(pending)
      @raised[pending] = true
      return if pending.decided?

      @onscreen.add(pending) { |id| @dispatch.fired(approval_args(pending, id)) }
    end

    # Close the popups whose pending somebody else answered while dunstify was
    # still blocked on it, and leave every other one alone. ORDERED FROM THIS
    # FIBER, NEVER FROM A SHELLOUT THREAD -- {Onscreen} is the handle map as well
    # as the answer map, and a Thread reading it would be the data race
    # {#initialize} rules out.
    #
    # {Onscreen#withdrawing} keeps the entry rather than dropping it, because
    # the notification is withdrawn and its dunstify is not: closing the popup
    # out from under a blocked `dunstify -A` makes it report a close reason
    # (measured against real dunst: `3`, "closed via the API"), and that answer
    # is still owed a drain. It reaches {Approval::Queue::Pending#decide} as a
    # deny that RETURNS FALSE, the pending being already decided -- the
    # correlation's own witness, with a spec on it.
    #
    # EVERY settled pending, including one the QUEUE'S OWN CLOCK denied. An
    # earlier edition excluded `timed_out?` on the ground that "the timeout path
    # already reaps itself", and that ground was FALSE. Three readings were taken
    # before the real rule came out, so all of it is written down; this has
    # already been rediscovered three times.
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
    # AND AN UNANSWERED APPROVAL IS BY CONSTRUCTION AN IDLE DESKTOP: the queue's
    # 300s window is 2.5x that threshold, so in the only case this surface
    # exists for the popup never expires, and once the grace period reaps the
    # process nothing else can close it. Two independent leaks, `-t` closes
    # neither.
    #
    # Do not "fix" this by marking the notification `transient` to bypass the
    # idle rule (dunstrc's `[transient_disable]` is commented out, so it would
    # work): a transient approval popup silently vanishes while the human is
    # away, which is precisely what `-u critical` is here to prevent.
    #
    # Withdrawing depends on expiry not at all, which is why it closes both, and
    # it also closes a second-order gap: {DEFAULT_TIMEOUT_MS} is pinned to the
    # queue's window only as `>=`, so a {Approval::Queue} built with a SHORTER
    # timeout denies on its own clock while this surface's popup stays lit. The
    # `>=` is deliberate -- a longer surface window is legitimate, a shorter one
    # would misattribute the denial. It races nothing: `decided?` is the
    # precondition, so the verdict is already in.
    def withdraw_settled
      @onscreen.withdrawing(&:decided?).each { |id| withdraw(id) }
    end

    # BEST-EFFORT, and dispatched rather than waited on so a D-Bus round trip to
    # a wedged dunst cannot stall the reactor. `-C` goes through the SAME
    # {Dispatch}, and so the same binary, rather than reaching for `dunstctl`:
    # {.for}'s `on_path?` consent check already covers it, the injected
    # `shell_out_factory` seam already observes it, and a desktop with dunstify
    # but no dunstctl is not one this surface silently stops withdrawing on.
    #
    # Its ANSWER is nobody's business -- `-C` prints nothing on success -- but
    # its FAILURE is, so the result goes to {Withdrawals} for the sweep to
    # journal. Every way it can fail degrades to the pre-withdrawal behaviour:
    # the popup stays up, which is worse UX rather than the failure that
    # matters, which would be raising out of the sweep and leaving the session
    # with no desktop approvals at all.
    def withdraw(id) = @withdrawals.add(@dispatch.attempted(["-C", id.to_s]))

    # The verdicts that arrived since the last pass, applied HERE -- on the sweep
    # fiber, never on the Thread that did the waiting (see the class comment for
    # why that is not negotiable).
    def settle_answered
      @onscreen.answered.each { |pending, answer, id| settle_closed(pending, answer, id) }
    end

    # The popup is normally GONE by the time its answer arrives: dunst closed it
    # in order to produce that answer. The exception is a dunstify that was
    # KILLED rather than answered -- {SHELLOUT_GRACE_MS}'s backstop SIGTERMs then
    # SIGKILLs, and a killed dunstify leaves its notification on screen
    # (measured). Then `id` is still set, the popup still lit, and nothing else
    # will ever close it.
    #
    # Only worth a `-C` when somebody else already decided the pending, which is
    # where the popup is both stale AND still ours to close. On the ordinary
    # path this surface's own answer wins, `decided?` is false until {#settle}
    # runs a line later, and no withdrawal is issued -- which keeps a `-C` off
    # the end of every approval. The residual is correct rather than tolerated:
    # if THIS surface's kill-deny wins the race (reachable only with a
    # `timeout_ms` shorter than the queue's, which is specs and never the
    # shipped wiring), the handle is dropped with no `-C`, the deny being this
    # surface's to make and the popup already gone with its process.
    def settle_closed(pending, answer, id)
      withdraw(id) if id && pending.decided?
      settle(pending, answer)
    end

    # Fail-closed, in ONE place for both the inline and the dispatched path:
    # anything that isn't literally {APPROVE} -- a Deny click, one of dunst's
    # numeric close-reason codes, or the empty string {Dispatch} answers with
    # when the shellout raised -- is a denial.
    #
    # @return [Boolean] whether THIS surface's answer won. A sibling surface, or
    #   the queue's own clock, having settled it first makes that false, which
    #   is normal operation rather than an error.
    def settle(pending, answer) = pending.decide(answer == APPROVE, surface: SURFACE)

    # THE THIRD DECIDING SURFACE, so it carries the same warning the other two
    # do: a click on Approve here signs a full approval in the Journal, so a
    # notification naming only the tool and its input would let a human release
    # a file's secrets having been shown nothing about them. The sentence is
    # {Approval::Queue::Outstanding#preamble}, the terminal's and the editor's
    # own, which is why it lives on the value rather than in a frontend.
    #
    # `-r` is the whole of the correlation: dunst honours an id the CALLER picks
    # for a notification it has never seen (measured -- two popups raised at
    # 900001 and 900002 displayed side by side and closed independently), so the
    # handle needs nothing read back off stdout. The inline {#decide} passes one
    # too, though nothing will ever withdraw it: one argv builder that cannot
    # drift beats a second differing only by a flag.
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
    # The cosmetic cost is the smaller one: a dunst configured `markup = strip`
    # shows `&lt;` literally. A notification that reads slightly wrong beats one
    # a crafted path can re-word.
    def markup_safe(text) = CGI.escapeHTML(text)

    def question_args(agent:, text:)
      ["-a", "lain", "-u", "normal", "-t", @timeout_ms.to_s, "#{agent} asks", text]
    end

    # Running `dunstify` OFF the reactor thread -- the one job in this file that
    # is about PROCESSES rather than approvals. The class comment holds the
    # argument for why it cannot be done inline.
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
      # then park THIS fiber on the answer.
      def run(args) = fired(args).pop

      # A command whose ANSWER is nobody's business but whose FAILURE is.
      #
      # @return [Thread::Queue] carrying one StandardError, or nil
      def attempted(args) = dispatched { faulted(args) }

      private

      # Not joined: the shellout's own timeout bounds the Thread's lifetime, and
      # the queue is what carries the result back.
      def dispatched
        results = Thread::Queue.new
        Thread.new { results.push(yield) }
        results
      end

      # Fails closed on any shellout error (a vanished binary, a broken D-Bus
      # session) rather than raising out of a notification surface -- an
      # approval nobody could actually be asked about must still refuse, never
      # wedge.
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

      # Deliberately looser than dunstify's `-t` so a well-behaved dunstify
      # reports its OWN real close reason first; this is only the backstop for
      # one confirmed not to.
      def shellout_timeout_seconds = (@timeout_ms + SHELLOUT_GRACE_MS) / 1000.0
    end

    # The `-C` shellouts dispatched and not yet heard back from. Best-effort
    # must not mean INVISIBLE: a desktop where `-C` is unsupported, or where
    # dunstify went missing between the raise and the withdrawal, would
    # otherwise fail silently for the whole session -- the "a surface quietly
    # stopped working" failure {Notify#journal_fault} exists to make visible.
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

    # The notifications this surface has on screen, keyed by the
    # {Approval::Queue::Pending} each asks about. An object because it holds an
    # invariant {Notify} would otherwise state three times: a notification is
    # ANSWERED once and WITHDRAWN once, and those are different events that can
    # happen in either order to the same handle. Identity-keyed, and
    # single-fiber-owned: every method here is called from the sweep and
    # nowhere else.
    class Onscreen
      # One notification on screen: the id this surface told dunst to use
      # (`-r`), and the {Thread::Queue} its answer will arrive on. One queue per
      # notification, so an answer is correlated to the pending it answers by
      # construction rather than by a key.
      #
      # The id is CHOSEN rather than read back, which keeps {Dispatch}'s
      # single-value stdout contract intact: `--print-id` writes the id onto the
      # same stream the action key arrives on (measured: "191\n2" for a
      # notification carrying `-A` actions), so parsing it would have made every
      # approval read as "not approve" and silently deny.
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
      # remember the handle its answer will come back on. Yielded rather than
      # returned because the argv needs it BEFORE there is anything to remember.
      def add(pending)
        id = self.class.next_id
        @notifications[pending] = Notification.new(id:, answers: yield(id))
      end

      # The verdicts that have arrived since the last pass, taken OUT of the map
      # as they are handed over: this surface owes each answer exactly one
      # application. A queue that reports itself non-empty holds exactly one
      # answer and only the sweep fiber ever pops one, so `pop` cannot block.
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
      # The entry is REPLACED, not deleted, which is why `showing?` exists: the
      # popup is gone but its `dunstify` is still running and still owes an
      # answer that {#answered} must collect. Dropping the row here would leak
      # that answer and the Thread carrying it.
      #
      # @return [Array<Integer>] ids to close
      def withdrawing
        going = @notifications.select { |pending, notification| notification.showing? && yield(pending) }
        going.each { |pending, notification| @notifications[pending] = notification.withdrawn }
        going.map { |_pending, notification| notification.id }
      end
    end

    # ON THE SIZE OF THIS FILE, ruled at review: five objects in one file is NOT
    # yet too many, since each holds exactly one invariant and a reader finds
    # every one of them from {#sweep}. THE NEXT ADDITION SHOULD OPEN A
    # `lain/notify/` SUBTREE rather than becoming a sixth nested class here.

    # No dunstify on PATH: every method is a documented no-op, so a caller never
    # guards with `if notifier`. {#decide} still denies fail-closed, but
    # {#watch} never touches the queue at all -- a pending this surface cannot
    # serve is left for whichever OTHER surface is actually watching, rather
    # than being raced away from it.
    class Null
      def watch(_queue) = nil
      def decide(pending) = pending.deny(surface: SURFACE)
      def question(**) = nil
    end
  end
end
