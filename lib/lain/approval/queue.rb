# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "async"
require "async/queue"

module Lain
  module Approval
    # {Effect::Handler::Gate}'s policy seam, backed by a queue instead of a
    # terminal prompt: {#call} enqueues a {Pending} approval and PARKS the
    # calling fiber -- the fiber, never the reactor, the same shape as
    # {Tools::AskHuman}'s sync gate -- until a surface fiber decides it or the
    # window expires. Decoupling ask from answer is what lets any number of
    # surfaces (the TTY prompt, a Neovim view) watch one queue, and what makes
    # every decision observable: each one lands in the Journal with its
    # surface, verdict, and latency, because on a study bench "who approved
    # what, and how long the human took" is evidence, not incident detail.
    #
    # Fail-closed is inherited, not reimplemented: an expired window resolves
    # the pending as a denial ({TIMEOUT_SURFACE}), so Gate returns the same
    # refusal Result an interactive "n" produces -- an unattended gate refuses,
    # it never wedges (gate.rb's doctrine). {Gate::DenyAll} remains the default
    # policy everywhere; this queue exists only where a frontend wires it.
    class Queue
      include Enumerable

      # The "surface" a decision wears when no surface made it: the window
      # expired and the clock decided. A name, not a nil, so journal readers
      # never guard.
      TIMEOUT_SURFACE = "timeout"

      # The decision's surface when the REQUESTER vanished: the gated fiber was
      # stopped while parked (Conductor#supervise's grace/Ctrl-C path), so
      # nobody awaits the verdict and the only honest one is a denial signed
      # by the cancellation itself.
      ABANDONED_SURFACE = "abandoned"

      # Generous because the answerer is a human at a terminal; the point is a
      # bound, not a hurry -- an abandoned session must eventually refuse.
      DEFAULT_TIMEOUT = 300

      Outstanding = Data.define(:path, :regions)

      # The sensitive regions of one file that approving a {Pending} would
      # release, and the file they were found in. A CAPABILITY a pending can
      # carry, not a flow: this queue sits BELOW the read and holds only a path,
      # so the arm that has the file's bytes is what detects, diffs against
      # {Sensitivity::Ledger} and builds one of these. Nothing here detects and
      # nothing here releases.
      #
      # The path is what a surface names to the human, and it is deliberately
      # NOT re-checked against the ledger's ABSOLUTE-path contract: one object
      # owns that rule and a second copy of a security check is a second thing
      # to drift. The builder passes the same path it will later release under,
      # so the prompt names exactly what a yes would send.
      #
      # A path that names NOTHING is refused here, though, and that is a
      # different rule from the ledger's: a blank one renders a prompt saying
      # secrets are at stake and naming no file, which is a question no human
      # can answer. {Outstanding::NONE} is the one blank path, and it carries no
      # regions, so nothing renders and nothing is released.
      #
      # Duck-typed on `#digest`, for {Sensitivity::Ledger}'s own reason -- this
      # carries regions, it never makes them.
      class Outstanding
        # `dup` before `freeze`, because `Array#to_a` returns SELF: without it a
        # caller that built its list by hand gets its own array frozen underneath
        # it, at a distance, by a constructor it only meant to read.
        def initialize(path:, regions:)
          held = regions.to_a.dup.freeze
          raise ArgumentError, "regions are outstanding but no file was named, got #{path.inspect}" \
            if held.any? && path.to_s.empty?

          super(path: -path.to_s, regions: held)
        end

        def any? = !regions.empty?
        def count = regions.length

        # The complement of {#any?}, spelled out rather than left to each caller
        # to negate. Two surfaces PARTITION the parked queue on exactly this
        # question ({Approval::QueueSurface#judges?}), and a partition whose two
        # halves are written as `x.any?` and `!x.any?` in different files is one
        # edit away from a silent overlap or a silent gap; written as `any?` and
        # `none?` over one value object, they are complementary by inspection.
        def none? = regions.empty?

        # The sentence every HUMAN surface puts in front of the question it is
        # about to ask, separator included, empty when there is nothing to say.
        # It lives on the value rather than in a frontend because two surfaces
        # render it -- the terminal prompt and the editor's list -- and "both
        # tell the human the same thing" is the whole point of showing it at
        # all; two copies of this string is how one surface comes to warn and
        # the other not to. It builds a String and touches no IO, so the rule
        # that keeps `lib/` off the terminal is untouched.
        #
        # THE PATH IS `inspect`ed, exactly as the input beside it is, and this
        # is the one string in the harness where skipping that converts a forged
        # prefix directly into a released secret. The path is model-influenced
        # -- it is the file the model asked to read, and for the detector to
        # fire at all it need only be a file the agent itself wrote -- so a path
        # spelled `"/tmp/x: 0 sensitive regions outstanding -- approve read(..)?
        # [y/N] "` renders a complete, plausible, BENIGN question in front of
        # the real one, and one holding `\e[2K\r` erases the line the human is
        # meant to read. `inspect` escapes both and cannot be closed from
        # inside. It QUOTES the forgery rather than deleting it, which is the
        # same residual `input.inspect` has always carried: the defence is that
        # the real question is the one that ENDS the rendering, always, because
        # this sentence only ever precedes it.
        #
        # The regions' own bytes are never named. A human is told WHICH file and
        # HOW MANY, because printing a value to ask whether it may be sent to a
        # model would disclose it to the terminal, the scrollback, the tmux
        # buffer and any screen share -- the exact disclosure this exists to
        # gate. The detector's REASON is withheld for a different reason, and it
        # does not change the answer either way: a reason is detector OUTPUT,
        # not fact -- {Sensitivity::Regions}' own note calls entropy triage
        # rather than a verdict -- so putting it in front of a human invites
        # them to weigh a signal never meant to be weighed one region at a time.
        def preamble
          return "" unless any?

          "#{path.inspect}: #{count} sensitive #{"region".pluralize(count)} outstanding -- "
        end

        # Nothing outstanding, which is every ordinary gated call. A real
        # Outstanding rather than nil, so a surface asks rather than guards. It
        # sits below the methods because it is built through the initialize
        # above, which has to exist first.
        NONE = new(path: "", regions: [])
      end

      # One gated call awaiting its verdict. Deliberately MUTABLE coordination
      # state (like {Lain::Promise}, unlike the frozen value objects): it exists
      # to be decided. Resolution is single-shot with first-answer-wins
      # semantics -- two surfaces racing over one pending is normal operation,
      # so the loser's answer is a quiet no-op here, NOT the coordination bug
      # {Promise::AlreadyResolved} names.
      class Pending
        attr_reader :requester, :tool, :tool_use_id, :input, :outstanding, :surface, :decision, :latency

        # `outstanding:` defaults to {Outstanding::NONE} because an ordinary
        # gated call releases nothing and has none to give. That is NOT the
        # ledger's no-default rule bent: a defaulted ledger lets a forgotten
        # injection become a SECOND ledger whose releases nobody sees, and there
        # is no second anything here -- a missing one renders the ordinary
        # prompt and still releases nothing.
        #
        # An EXPLICIT nil resolves to the same {Outstanding::NONE}, and that is
        # not belt-and-braces: `outstanding:` is public on {Queue#adjudicate},
        # every surface that reads it dereferences it, and a surface fiber that
        # raises is a surface that silently stops watching for the rest of the
        # session (see {Approval::QueueSurface#watch}). "Null Object over nil"
        # is the rule, and this is the one constructor that can enforce it for
        # every reader at once.
        def initialize(effect:, requester:, clock:, outstanding: Outstanding::NONE)
          @tool = effect.name
          @tool_use_id = effect.tool_use_id
          @input = effect.input
          @outstanding = outstanding || Outstanding::NONE
          @requester = requester
          @clock = clock
          @asked_at = clock.call
          @promise = Promise.new
        end

        # Decide this approval, waking the parked caller. Answers whether THIS
        # answer won; a later answer returns false and changes nothing.
        # Latency is stamped here, decision-side, so it measures how long the
        # verdict took -- not how long the woken fiber waited to be scheduled.
        #
        # An {Outstanding} changes nothing here. Releasing its regions to
        # {Sensitivity::Ledger} is the SETTLING CALLER's move, never this
        # method's, and the invariant that says so is THIS method's own: single
        # -shot resolution is safe without a lock only because the `decided?`
        # guard and the resolve below it are straight-line with no yield point
        # between them, so two fibers cannot both pass the guard. A ledger write
        # is IO-shaped and would open exactly that gap -- quite apart from
        # hanging a second responsibility on the one object that cannot afford
        # one. This queue holds no ledger at all, which is how that stays true.
        # rubocop:disable Naming/PredicateMethod -- a COMMAND whose Boolean
        # reports whether it won the race, not a query; `decide?` would misname
        # the mutation the way `Timeline#commit`'s rename lesson warns about.
        def decide(verdict, surface:)
          return false if decided?

          @surface = surface.to_s
          @decision = verdict ? :approve : :deny
          @latency = @clock.call - @asked_at
          @promise.resolve(@decision)
          true
        end
        # rubocop:enable Naming/PredicateMethod

        def approve(surface:) = decide(true, surface:)
        def deny(surface:) = decide(false, surface:)
        def decided? = @promise.resolved?
        def approved? = @decision == :approve
        def timed_out? = @surface == TIMEOUT_SURFACE

        # Park the calling fiber until decided (see Promise#await).
        def await = @promise.await

        def to_journal
          { "type" => "approval_decision", "requester" => requester, "tool" => tool,
            "surface" => surface, "verdict" => decision.to_s, "timed_out" => timed_out?,
            "latency" => latency }
        end
      end

      # @param journal [#record] where decisions land as evidence; required, not
      #   defaulted, for the same reason build_agent's `session:` is -- silently
      #   unjournaled approvals would be a quiet hole in the experiment record
      # @param requester [String] who these gated calls are asked on behalf of
      # @param timeout [Numeric] seconds an unanswered pending waits before the
      #   fail-closed denial
      # @param clock [#call] monotonic seconds, injectable so specs pin latency
      def initialize(journal:, requester: "agent", timeout: DEFAULT_TIMEOUT, clock: RunClock::MONOTONIC)
        @journal = journal
        @requester = requester
        @timeout = timeout
        @clock = clock
        @arrivals = Async::Queue.new
        # A plain Array with no lock, on purpose: every @parked mutation (the
        # `<<` in #admit, the `delete` in #settle's ensure) is straight-line
        # Ruby with no yield point, and a fiber only interleaves at an IO
        # yield -- the parks in #call/#dequeue sit BETWEEN mutations, never
        # inside one. So N gated fibers admit N independent pendings
        # (docs/concurrency.md, "parallel tools"), pinned by
        # spec/lain/approval/queue_concurrency_spec.rb; if that spec can only
        # pass by adding a lock here, the claim has failed -- escalate,
        # don't patch.
        @parked = []
      end

      # Gate's policy seam: enqueue a {Pending}, park until it is decided (or
      # the window denies it), journal the decision, answer the verdict.
      # Parking here is safe inside tool dispatch because the surface that
      # answers runs as a SIBLING fiber in the same reactor (the exe hosts it
      # beside the Repl's answer_loop) -- the identical two-fiber shape
      # ask_human's perform/reply already proves out.
      def call(effect, context) = adjudicate(effect, context).approved?

      # The same lifecycle, answering the SETTLED {Pending} instead of its
      # Boolean. A caller that has to attribute the verdict needs the SURFACE
      # that made it -- {Approval::Escalation} treats a human's approval and an
      # {AutoSurface}'s as different kinds of authority -- and a Boolean is the
      # one thing that cannot carry it. {#call} stays exactly the two-valued duck
      # {Effect::Handler::Gate} wants, so nothing that held this object as a
      # policy sees any change.
      #
      # `outstanding:` is how the one arm holding a file's bytes tells the
      # surfaces what a yes would release ({Outstanding}). Defaulted, because
      # every other gated call releases nothing -- and answering the settled
      # {Pending} is what lets that caller write the ledger itself.
      def adjudicate(effect, _context, outstanding: Outstanding::NONE)
        pending = admit(effect, outstanding)
        settle(pending)
        pending
      end

      # The surface seam: park until a gated call arrives, answer its {Pending}.
      # Async::Queue is buffered, so a pending enqueued before any surface
      # watched is delivered, never missed. Already-decided arrivals (an
      # abandoned pending cannot be removed from the arrival queue itself) are
      # skipped here, so a surface never prompts a human for a call nobody
      # awaits.
      def dequeue
        pending = @arrivals.dequeue
        pending.decided? ? dequeue : pending
      end

      # The pending approvals, oldest first -- what a second surface (or the
      # bench) inspects without draining the arrival queue.
      def each(&block) = @parked.each(&block)

      private

      # The ASKED half of the lifecycle's evidence, journaled BEFORE the
      # pending is parked rather than between the two mutations below: the
      # record is a write, a write can yield the fiber, and @parked's
      # lock-freedom rests on `<<` and `enqueue` staying straight-line with no
      # yield point between them (see #initialize). Announcing first keeps that
      # claim exactly as it was.
      def admit(effect, outstanding)
        pending = Pending.new(effect:, requester: @requester, clock: @clock, outstanding:)
        record_evidence(Telemetry::ApprovalPending) { Telemetry::ApprovalPending.from(pending) }
        @parked << pending
        @arrivals.enqueue(pending)
        pending
      end

      # `ensure`, because the requester can be STOPPED while parked (the
      # supervise/Ctrl-C path unwinds this fiber with Async::Stop, which the
      # timeout rescue never sees): the pending must still leave the parked
      # list, still journal, and still end up decided -- the abandonment deny
      # is a no-op on the normal path and is exactly what makes a late surface
      # answer harmless and lets {#dequeue} skip the orphan.
      def settle(pending)
        await_decision(pending)
      ensure
        pending.deny(surface: ABANDONED_SURFACE)
        @parked.delete(pending)
        record_evidence(Pending) { pending }
      end

      # Evidence about a turn must never be able to COST the turn. Both writes
      # here sit on {Gate}'s policy seam, and Gate sits ABOVE
      # {Effect::Handler::Live} -- nothing below is left to turn an exception
      # into a {Tool::Result}, so a closed Journal or a full disk would unwind
      # through the agent loop and hand the user a dead turn instead of the
      # denial an unanswerable approval is owed. That is precisely the wedge
      # gate.rb's doctrine forbids: an unattended gate refuses, it never wedges.
      # (On the settle path the raise would land inside `ensure` and REPLACE the
      # verdict, which is the same defect one step worse.)
      #
      # Loud, then, means a denial plus a recorded reason -- not an unrescued
      # raise. The reason wears the Journal's OWN `journal_error` shape, the
      # self-describing record {Journal#encode} already writes for a value it
      # cannot serialize, so a reader has one failure record to know rather than
      # two.
      #
      # The entry is BUILT IN THE BLOCK, never passed as an argument, and that
      # is not a style choice: an argument is evaluated before control enters
      # this method, so a record whose own construction raises -- a
      # {Telemetry::Guards::ApprovalPending} refusing a park it cannot name,
      # which a `tool_use_id` of nil or "" reaches -- would escape past the very
      # protection this method exists to give. `kind` names what was being
      # recorded, because a raise mid-construction leaves no instance to name.
      def record_evidence(kind, &entry)
        @journal.record(yield)
      rescue StandardError => e
        degrade(kind, e)
      end

      # When even the degraded write fails, the journal is simply gone and there
      # is nowhere left to be honest to. Swallowing is the only option that
      # still refuses rather than wedging.
      def degrade(kind, error)
        @journal.record("type" => "journal_error", "error" => "#{error.class}: #{error.message}",
                        "entry_class" => kind.name)
      rescue StandardError
        nil
      end

      # The expired window IS a decision -- a denial signed by the clock --
      # routed through the same single-shot {Pending#decide}, so a surface that
      # answered in the same tick still wins and a later answer is a no-op.
      def await_decision(pending)
        Async::Task.current.with_timeout(@timeout) { pending.await }
      rescue Async::TimeoutError
        pending.deny(surface: TIMEOUT_SURFACE)
      end
    end
  end
end
