# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "async"
require "async/queue"

module Lain
  module Approval
    # {Effect::Handler::Gate}'s policy seam, backed by a queue instead of a
    # terminal prompt: {#call} enqueues a {Pending} and PARKS the calling FIBER,
    # never the reactor, until a surface fiber decides it or the window expires.
    # Decoupling ask from answer is what lets any number of surfaces watch one
    # queue, and what makes every decision observable -- on a study bench "who
    # approved what, and how long the human took" is evidence.
    #
    # Fail-closed is inherited, not reimplemented: an expired window resolves
    # the pending as a denial, so Gate returns the same refusal Result an
    # interactive "n" produces. {Gate::DenyAll} remains the default policy
    # everywhere; this queue exists only where a frontend wires it.
    class Queue
      include Enumerable

      # No surface made it: the window expired and the clock decided. A name,
      # not a nil, so journal readers never guard.
      TIMEOUT_SURFACE = "timeout"

      # The REQUESTER vanished -- the gated fiber was stopped while parked --
      # so nobody awaits the verdict and the only honest one is a denial signed
      # by the cancellation itself.
      ABANDONED_SURFACE = "abandoned"

      # Generous because the answerer is a human at a terminal: a bound, not a
      # hurry -- an abandoned session must eventually refuse.
      DEFAULT_TIMEOUT = 300

      Outstanding = Data.define(:path, :regions)

      # The sensitive regions of one file that approving a {Pending} would
      # release, and the file they were found in. A CAPABILITY a pending can
      # carry, not a flow: this queue sits BELOW the read and holds only a path,
      # so the arm that has the file's bytes is what detects, diffs against
      # {Sensitivity::Ledger} and builds one of these. NOTHING HERE DETECTS AND
      # NOTHING HERE RELEASES.
      #
      # The path is deliberately NOT re-checked against the ledger's
      # ABSOLUTE-path contract: one object owns that rule, and a second copy of
      # a security check is a second thing to drift. The builder passes the same
      # path it will later release under, so the prompt names exactly what a yes
      # would send.
      #
      # A path that names NOTHING is refused here, which is a different rule
      # from the ledger's: a blank one renders a prompt saying secrets are at
      # stake and naming no file, a question no human can answer.
      # {Outstanding::NONE} is the one blank path, and it carries no regions.
      class Outstanding
        # `dup` before `freeze`, because `Array#to_a` returns SELF: without it
        # a caller that built its list by hand gets its own array frozen
        # underneath it, by a constructor it only meant to read.
        def initialize(path:, regions:)
          held = regions.to_a.dup.freeze
          raise ArgumentError, "regions are outstanding but no file was named, got #{path.inspect}" \
            if held.any? && path.to_s.empty?

          super(path: -path.to_s, regions: held)
        end

        def any? = !regions.empty?
        def count = regions.length

        # Spelled out rather than left to each caller to negate: two surfaces
        # PARTITION the parked queue on this question, and a partition whose
        # halves are written `x.any?` and `!x.any?` in different files is one
        # edit from a silent overlap or gap. As `any?`/`none?` over one value
        # object they are complementary by inspection.
        def none? = regions.empty?

        # The sentence every HUMAN surface puts in front of the question it is
        # about to ask. It lives on the value rather than in a frontend because
        # two surfaces render it, and two copies of this string is how one
        # surface comes to warn and the other not to.
        #
        # THE PATH IS `inspect`ed, and this is the one string in the harness
        # where skipping that converts a forged prefix directly into a released
        # secret. The path is MODEL-INFLUENCED -- for the detector to fire it
        # need only be a file the agent itself wrote -- so a path spelled
        # `"/tmp/x: 0 sensitive regions outstanding -- approve read(..)? [y/N] "`
        # renders a complete, plausible, BENIGN question in front of the real
        # one, and one holding `\e[2K\r` erases the line the human is meant to
        # read. `inspect` escapes both and cannot be closed from inside. It
        # QUOTES the forgery rather than deleting it: the defence is that the
        # real question always ENDS the rendering, because this sentence only
        # ever precedes it.
        #
        # The regions' own BYTES are never named -- printing a value to ask
        # whether it may be sent to a model would disclose it to the terminal,
        # the scrollback, the tmux buffer and any screen share, which is the
        # exact disclosure this exists to gate. The detector's REASON is
        # withheld for a different reason: a reason is detector OUTPUT and not
        # fact, so putting it in front of a human invites them to weigh a signal
        # never meant to be weighed one region at a time.
        def preamble
          return "" unless any?

          "#{path.inspect}: #{count} sensitive #{"region".pluralize(count)} outstanding -- "
        end

        # Every ordinary gated call. A real Outstanding rather than nil, so a
        # surface asks rather than guards. Below the methods because it is built
        # through the initialize above, which has to exist first.
        NONE = new(path: "", regions: [])
      end

      # One gated call awaiting its verdict. Deliberately MUTABLE coordination
      # state, unlike the frozen value objects: it exists to be decided.
      # Single-shot, first-answer-wins -- two surfaces racing over one pending
      # is normal operation, so the loser's answer is a quiet no-op here and NOT
      # the coordination bug {Promise::AlreadyResolved} names.
      class Pending
        attr_reader :requester, :tool, :tool_use_id, :input, :outstanding, :surface, :decision, :latency

        # Defaulting here is NOT the ledger's no-default rule bent: a defaulted
        # LEDGER lets a forgotten injection become a second ledger whose
        # releases nobody sees, and there is no second anything here -- a
        # missing one renders the ordinary prompt and still releases nothing.
        #
        # An EXPLICIT nil resolves to the same {Outstanding::NONE}, and that is
        # not belt-and-braces: `outstanding:` is public on {Queue#adjudicate},
        # every surface dereferences it, and a surface fiber that raises
        # silently stops watching for the rest of the session. This is the one
        # constructor that can enforce "Null Object over nil" for every reader
        # at once.
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

        # Answers whether THIS answer won; a later answer returns false and
        # changes nothing. Latency is stamped decision-side, so it measures how
        # long the verdict took, not how long the woken fiber waited to be
        # scheduled.
        #
        # Releasing an {Outstanding}'s regions to {Sensitivity::Ledger} is the
        # SETTLING CALLER's move, never this method's, and the invariant is this
        # method's own: single-shot resolution is safe WITHOUT A LOCK only
        # because the `decided?` guard and the resolve below it are
        # straight-line with no yield point between them. A ledger write is
        # IO-shaped and would open exactly that gap. This queue holds no ledger
        # at all, which is how that stays true.
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

        # `outstanding` is ABSENT and must stay absent, and `input` with it.
        # This pending may hold the sensitive regions a yes would release, bytes
        # included, and the only thing keeping them off disk is that this
        # hand-maintained list does not name them. Adding the field writes real
        # credentials into the Journal with no test to notice, since every test
        # here asserts the fields that ARE listed.
        # {Telemetry::ApprovalPending.from} carries the identical note.
        def to_journal
          { "type" => "approval_decision", "requester" => requester, "tool" => tool,
            "surface" => surface, "verdict" => decision.to_s, "timed_out" => timed_out?,
            "latency" => latency }
        end
      end

      # @param journal [#record] where decisions land as evidence; required,
      #   not defaulted, because silently unjournaled approvals would be a hole
      #   in the experiment record
      # @param requester [String] who a gated call is asked on behalf of when
      #   the call itself names nobody -- the SESSION's default, not the fleet's
      #   answer; see {#requester_for}
      # @param timeout [Numeric] seconds an unanswered pending waits before the
      #   fail-closed denial
      # @param clock [#call] monotonic seconds, injectable so specs pin latency
      def initialize(journal:, requester: "agent", timeout: DEFAULT_TIMEOUT, clock: RunClock::MONOTONIC)
        @journal = journal
        @requester = requester
        @timeout = timeout
        @clock = clock
        @arrivals = Async::Queue.new
        # A plain Array with NO LOCK, on purpose: every @parked mutation is
        # straight-line Ruby with no yield point, and a fiber only interleaves
        # at an IO yield -- the parks in #call/#dequeue sit BETWEEN mutations,
        # never inside one. So N gated fibers admit N independent pendings. If
        # queue_concurrency_spec.rb can only pass by adding a lock here, the
        # claim has failed -- escalate, don't patch.
        @parked = []
      end

      # Gate's policy seam. Parking here is safe inside tool dispatch because
      # the surface that answers runs as a SIBLING fiber in the same reactor.
      def call(effect, context) = adjudicate(effect, context).approved?

      # The same lifecycle, answering the SETTLED {Pending} instead of its
      # Boolean. A caller that has to attribute the verdict needs the SURFACE
      # that made it -- {Approval::Escalation} treats a human's approval and an
      # {AutoSurface}'s as different kinds of authority -- and a Boolean cannot
      # carry that. {#call} stays the two-valued duck
      # {Effect::Handler::Gate} wants.
      #
      # `outstanding:` is how the one arm holding a file's bytes tells the
      # surfaces what a yes would release. Answering the settled {Pending} is
      # what lets that caller write the ledger itself.
      def adjudicate(effect, context, outstanding: Outstanding::NONE)
        pending = admit(effect, context, outstanding)
        settle(pending)
        pending
      end

      # Async::Queue is buffered, so a pending enqueued before any surface
      # watched is delivered, never missed. Already-decided arrivals -- an
      # abandoned pending cannot be removed from the arrival queue itself -- are
      # skipped, so a surface never prompts a human for a call nobody awaits.
      def dequeue
        pending = @arrivals.dequeue
        pending.decided? ? dequeue : pending
      end

      # Oldest first -- what a second surface, or the bench, inspects without
      # draining the arrival queue.
      def each(&block) = @parked.each(&block)

      private

      # Journaled BEFORE the pending is parked, never between the two mutations
      # below: the record is a write, a write can yield the fiber, and @parked's
      # lock-freedom rests on `<<` and `enqueue` staying straight-line with no
      # yield point between them.
      def admit(effect, context, outstanding)
        pending = Pending.new(effect:, requester: requester_for(context), clock: @clock, outstanding:)
        record_evidence(Telemetry::ApprovalPending) { Telemetry::ApprovalPending.from(pending) }
        @parked << pending
        @arrivals.enqueue(pending)
        pending
      end

      # ONE queue serves the whole fleet, so a queue-level constant journals and
      # renders every pending identically -- which is how a researcher
      # subagent's `bash` prompt came to be indistinguishable from the human's
      # own agent's. The CALL says so instead, through the context the policy
      # seam already threads.
      #
      # `requester:` stays the SESSION's answer for contexts that name nobody,
      # so this queue never journals a blank.
      def requester_for(context)
        context.respond_to?(:requester) ? context.requester : @requester
      end

      # `ensure`, because the requester can be STOPPED while parked: Ctrl-C
      # unwinds this fiber with Async::Stop, which the timeout rescue never
      # sees, and the pending must still leave the parked list, still journal,
      # and still end up decided. The abandonment deny is a no-op on the normal
      # path, and is what makes a late surface answer harmless.
      def settle(pending)
        await_decision(pending)
      ensure
        pending.deny(surface: ABANDONED_SURFACE)
        @parked.delete(pending)
        record_evidence(Pending) { pending }
      end

      # Evidence about a turn must never COST the turn. Both writes sit on
      # {Gate}'s policy seam, ABOVE {Effect::Handler::Live} -- nothing below is
      # left to turn an exception into a {Tool::Result}, so a closed Journal
      # would unwind through the agent loop and hand the user a dead turn
      # instead of the denial an unanswerable approval is owed. On the settle
      # path the raise would land inside `ensure` and REPLACE the verdict, which
      # is the same defect one step worse.
      #
      # Loud therefore means a denial plus a recorded reason, wearing the
      # Journal's own `journal_error` shape so a reader has one failure record
      # to know rather than two.
      #
      # The entry is BUILT IN THE BLOCK, never passed as an argument: an
      # argument is evaluated before control enters this method, so a record
      # whose own construction raises would escape past the very protection this
      # exists to give. `kind` names what was being recorded, because a raise
      # mid-construction leaves no instance to name.
      def record_evidence(kind, &entry)
        @journal.record(yield)
      rescue StandardError => e
        degrade(kind, e)
      end

      # When even the degraded write fails the journal is gone and there is
      # nowhere left to be honest to. Swallowing is the only option that still
      # refuses rather than wedging.
      def degrade(kind, error)
        @journal.record("type" => "journal_error", "error" => "#{error.class}: #{error.message}",
                        "entry_class" => kind.name)
      rescue StandardError
        nil
      end

      # The expired window IS a decision, routed through the same single-shot
      # {Pending#decide}, so a surface that answered in the same tick still wins
      # and a later answer is a no-op.
      def await_decision(pending)
        Async::Task.current.with_timeout(@timeout) { pending.await }
      rescue Async::TimeoutError
        pending.deny(surface: TIMEOUT_SURFACE)
      end
    end
  end
end
