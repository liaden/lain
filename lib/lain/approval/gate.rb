# frozen_string_literal: true

require "async"

module Lain
  module Approval
    # Construction contracts for the records below: a {Declarative::Carrier}
    # checked BEFORE the auto-frozen Data value exists, so the record never
    # touches ActiveModel and stays `Ractor.shareable?`.
    module Contracts
      # {Gate::Answer} is what decides whether a digest is registered, so a
      # non-boolean here is worse than the same value in {GateDecision}: `"yes"`
      # is truthy, so `#approved?` would open the gate and only the record's own
      # guard would object, after the fact. The DECIDING value guards itself, at
      # the same standard as the recorded one.
      class Answer < Declarative::Carrier
        attribute :approved
        attribute :surface
        validates :approved, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :surface, presence: { message: "must name the surface that answered, got nil" }
      end

      # `approved` is guarded by inclusion rather than `presence:`, which
      # cannot reject `false` -- the very verdict this record most often
      # carries.
      class GateDecision < Declarative::Carrier
        attribute :artifact_digest
        attribute :epic_slug
        attribute :stage
        attribute :approved
        attribute :answered_by
        attribute :policy
        attribute :latency
        validates :artifact_digest, presence: { message: "must name the artifact it judged, got nil" }
        validates :epic_slug, presence: { message: "must name the epic it belongs to, got nil" }
        validates :stage, presence: { message: "must name the stage it gated, got nil" }
        validates :approved, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :answered_by, presence: { message: "must name who answered, got nil" }
        validates :policy, presence: { message: "must name the policy that reached the verdict, got nil" }
        attribute :issue_id
        validates :issue_id, presence: { message: "must name the issue when it names one at all, got a blank id" },
                             allow_nil: true
        # Guarded rather than coerced: `to_f` turns nil and "quick" alike into
        # 0.0, writing "answered instantly" -- a measurement nobody made -- into
        # the experiment record.
        validates :latency, numericality: { greater_than_or_equal_to: 0,
                                            message: "must be seconds >= 0, got %<value>s" }
      end

      # Narrower than {GateDecision} on purpose: the fold reads only these two
      # fields, so guarding the rest would check bytes it never looks at.
      #
      # `approved` is a TRUNCATION CANARY. {Contracts::GateDecision} makes it
      # mandatory at every WRITE, so no record this process produced can be
      # missing it or spell it as the STRING `"false"` -- the only way either
      # reaches here is a line damaged by truncation or a hand-made record, and
      # a truncation that took `approved` could equally have taken
      # `artifact_digest`. Refusing the whole rebuild is the fail-closed answer:
      # silently skipping would let a fold-past denial masquerade as "nothing to
      # see here" as quietly as folding a truncated `true` in.
      class RegistryEntry < Declarative::Carrier
        attribute :artifact_digest
        attribute :approved
        validates :artifact_digest, presence: { message: "must name the artifact it judged, got nil" }
        validates :approved, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
      end
    end

    # One verdict over one artifact, journaled as `gate_decision`.
    # `artifact_digest` is the JOIN KEY and addresses CONTENT, so an edited plan
    # is a different, un-approved address rather than a stale match. `epic_slug`
    # and `stage` are the PARTITION key a sign-off queue folds on, which is why
    # both are required and neither is derivable from the digest.
    #
    # `answered_by` (which surface) and `policy` (how it was reached) are
    # INDEPENDENT: a `"deferred"` policy still journals a real surface, and
    # reading either off the other would be a guess.
    #
    # `evidence_digest` and `reason` are nullable, and nullable is a value here
    # ("nothing was gathered", "no rationale was given"), not a missing field.
    #
    # `issue_id` is the partition's third member: nil for the epic-wide
    # stages, the issue's id for `issue_plan` and `implementation`, whose gates
    # are one issue's. `criteria_digest` is the {Gherkin::Criteria#digest} an
    # issue plan was approved WITH -- the same join key a grade record carries,
    # so a later grade can be matched to the criteria somebody signed off.
    # Both joined the shape after records were already on disk; a record
    # written before reads them as nil, which is exactly what it was.
    GateDecision = Data.define(:artifact_digest, :epic_slug, :stage, :approved, :answered_by, :policy,
                               :latency, :evidence_digest, :reason, :issue_id, :criteria_digest) do
      include Telemetry::Journalable

      def initialize(artifact_digest:, epic_slug:, stage:, approved:, answered_by:, policy:, latency:,
                     evidence_digest: nil, reason: nil, issue_id: nil, criteria_digest: nil)
        # Stringified BEFORE the guard, so `presence:` judges the bytes that
        # actually get journaled: a stage object whose `#to_s` is blank passes a
        # presence check on the raw object and then writes an empty partition
        # key -- the one value a queue folding on (epic_slug, stage) can never
        # match back.
        epic_slug = interned(epic_slug)
        stage = interned(stage)
        answered_by = interned(answered_by)
        policy = interned(policy)
        issue_id = SignoffQueue::IssueId.read(issue_id)
        Contracts::GateDecision.check!(artifact_digest:, epic_slug:, stage:, approved:, answered_by:, policy:,
                                       latency:, issue_id:)

        super(artifact_digest: artifact_digest.dup.freeze, epic_slug:, stage:, approved:, answered_by:, policy:,
              latency: latency.to_f, evidence_digest: frozen(evidence_digest), reason: frozen(reason),
              issue_id:, criteria_digest: frozen(criteria_digest))
      end

      private

      # Interned where the digests are dup'd-and-frozen: a stage or a surface
      # repeats across every record in a run, a digest does not.
      def interned(value) = -value.to_s

      # nil stays nil: "nothing was carried" is a value on this record.
      def frozen(value) = value&.dup&.freeze
    end

    # The ARTIFACT gate: the fail-closed approval any artifact answering
    # `#digest` and `#gate_question` must pass before an irreversible action
    # consumes that digest. It renders nothing itself -- the artifact owns its
    # human-facing question -- asks through the injected `ask_human`-shaped
    # duck, and BLOCKS on that promise with a timeout. Silence is a denial
    # signed by the clock: an unattended gate must refuse, never wedge, and
    # never default open.
    #
    # == Two things in this codebase are called a gate
    #
    # * {Approval::Gate} (here) gates an ARTIFACT by its content address, across
    #   a whole stage of work. An issue's acceptance criteria are gated HERE
    #   too, composed into that issue's plan, rather than by a gate of their
    #   own that could approve criteria no plan was written to.
    # * {Middleware::Gate} gates one TOOL CALL at interpretation time,
    #   through a `#call(effect, context) -> Boolean` policy seam. It knows
    #   nothing about artifacts or digests.
    #
    # == The registry, and content-addressed refusal
    #
    # An approval is remembered by the artifact's digest. Because that addresses
    # CONTENT, one edited sentence is a different digest and the prior approval
    # does not carry -- {#ensure_approved!} refuses loudly, naming the
    # un-approved address.
    #
    # The registry is MONOTONIC and add-only: a later denial of an
    # already-approved digest does NOT revoke the standing approval. Both
    # verdicts land in the Journal, which is the audit record; the registry is
    # only the in-memory convenience that answers without re-reading it, and it
    # starts empty regardless of what an earlier session journaled.
    # {.from_journal} is the opt-in for the other direction.
    #
    # == The stage boundary is NOT this class's guarantee
    #
    # {Epic::Stage}'s rule -- a stage's gates may only open once every earlier
    # stage of the same epic has its sign-off partition drained -- is enforced
    # on the POLICY seam ({Gate::Policy#decide}), not here. {#call} is public and
    # skips it entirely, so calling this directly can approve an
    # implementation-stage artifact while that epic's research sign-offs are
    # still parked. Deliberate: the check needs {Epic}'s vocabulary, and this
    # class stays blind to what it gates -- the bench wires it under artifacts
    # that are not epic stages at all. Go through a Policy for the boundary.
    #
    # == The asker duck, and where attribution lives
    #
    # The gate depends only on `#ask(question) -> Promise`. Who answered rides
    # the promise's resolved value, process-local coordination -- so no new meta
    # key is added to any replayable event, and the gate stays blind to which
    # surface spoke. What the promise resolves with is an {Answer}: turning a
    # human's words into one is the job of whoever put the question in those
    # words, never this class's.
    class Gate
      include Enumerable

      # A name rather than a nil, so a journal reader never guards.
      TIMEOUT_SURFACE = "timeout"

      # The other name a journal reader never guards against: a wait that
      # ended because something outside this fiber cancelled it, Ctrl-C
      # included, rather than because the window closed or a human spoke.
      INTERRUPTED_SURFACE = "interrupted"

      # Generous because the answerer is a human reading a plan: a bound, not
      # a hurry.
      DEFAULT_TIMEOUT = 300

      # HOW a wait ends when nothing answers it. {#await} needs a strategy
      # rather than a bare number, because the one shape that must never
      # happen is handing the reactor's own `with_timeout` something it turns
      # into a window that is wrong in either direction: `nil` computes
      # `now + nil.to_f`, which is `now` -- a window that closes the instant
      # it opens, denying before anyone could ever answer. `Float::INFINITY`
      # computes a C `time_t` from an infinite double, undefined behaviour in
      # io-event's own timer conversion -- silently fine on this box's
      # io_uring selector, and a hard crash (`Errno::EINVAL`) the moment
      # io_uring is unavailable and io-event falls back to epoll, which is
      # exactly what a container's default seccomp profile forces.
      #
      # {Bounded} and {Unbounded} both answer `#around`, so {#await} never
      # branches on which it holds.
      module Window
        # @param seconds [Numeric]
        # @return [Bounded]
        def self.bounded(seconds) = Bounded.new(seconds)

        # Arms exactly one reactor timer, for the duration of the block.
        class Bounded
          # @return [Numeric] the window this arms, for {#await}'s
          #   fired-through-the-window report
          attr_reader :seconds

          def initialize(seconds)
            @seconds = seconds
          end

          def around(task, &block)
            task.with_timeout(@seconds, &block)
          end
        end

        # Arms NO reactor timer at all, so nothing is ever handed to
        # `with_timeout` for an unbounded wait to go wrong over. Only an
        # {Async::Cancel} -- Ctrl-C included -- ever ends the wait this wraps.
        module Unbounded
          def self.seconds = nil

          def self.around(_task)
            yield
          end
        end
      end

      # Journaled, never branched on here: {#call} IS the asker-delegating
      # path, and other policies WRAP this call rather than switching inside it.
      DEFAULT_POLICY = "interactive"

      # Names the digest, so the edited-artifact case reads as a different,
      # un-approved address rather than a mysterious miss.
      class NotApproved < Error
        include RefusedBeforeActing
      end

      # Raised in place of `async`'s bare `RuntimeError: No async task
      # available!`, which names neither the caller that broke the precondition
      # nor the one-word fix.
      class NoReactor < Error; end

      MISSING_REACTOR = "Approval::Gate#call parks on the asker's promise -- run it inside Sync { } or " \
                        "Async { } (there is no reactor on this fiber)"
      private_constant :MISSING_REACTOR

      # A verdict plus the surface that gave it. Deeply frozen, so it is
      # Ractor-shareable like every value that crosses a fiber boundary.
      #
      # `reason` is what the ANSWERING side knows about its own verdict -- a
      # reply it could not classify, say -- and it is journaled over whatever
      # reason the caller forwarded, because it is the more specific account.
      Answer = Data.define(:approved, :surface, :reason) do
        def self.approve(surface) = new(approved: true, surface:)
        def self.deny(surface) = new(approved: false, surface:)

        def initialize(approved:, surface:, reason: nil)
          surface = -surface.to_s
          Contracts::Answer.check!(approved:, surface:)

          super(approved:, surface:, reason: reason&.dup&.freeze)
        end

        def approved? = approved
      end

      # @param journal [#record] where verdicts land as evidence; required, not
      #   defaulted, because a silently unjournaled approval would be a hole in
      #   the experiment record
      # @param timeout [Numeric, Window::Unbounded] seconds an unanswered gate
      #   waits before the fail-closed denial -- wrapped in {Window::Bounded}
      #   -- or {Window::Unbounded} itself for a wait that only a cancellation
      #   ends. The window is enforced by the REACTOR's clock, never by
      #   `clock:` below.
      # @param clock [#call] monotonic seconds, measuring LATENCY ONLY. A
      #   scripted clock makes a journaled latency deterministic; it does NOT
      #   make the timeout fire sooner, so a spec exercising the timeout still
      #   waits real seconds. Where the two clocks would contradict each other
      #   is settled in {#await}.
      def initialize(journal:, timeout: DEFAULT_TIMEOUT, clock: RunClock::MONOTONIC)
        @journal = journal
        @window = timeout.is_a?(Numeric) ? Window.bounded(timeout) : timeout
        @clock = clock
        @approved = Set.new
      end

      # Ask the artifact's own question, block on the answer with a timeout ->
      # deny, journal the verdict, and remember an approved digest.
      #
      # Parking on the promise is safe inside a reactor because the answering
      # surface runs as a SIBLING fiber. PRECONDITION: this must run under an
      # Async reactor; a call outside one raises {NoReactor}.
      #
      # @param artifact [#digest, #gate_question] the thing being gated
      # @param asker [#ask] the `ask_human`-shaped duck; `#ask` returns a
      #   {Lain::Promise} the answering surface resolves with an {Answer}. A
      #   promise that answers `#digest` names a question in the record, which
      #   the gate retires once it settles.
      # @param stage [#to_s] the stage this gate sits on
      # @param epic_slug [#to_s] the epic it belongs to; with `stage`, the
      #   partition key a sign-off queue folds decisions on
      # @param policy [String] how the verdict was reached, journaled verbatim
      # @param evidence_digest [String, nil] the content address of the evidence
      #   this verdict was reached ON, for a caller that gathered any
      #   ({Adjudicator}); nil means none was gathered, which is the honest
      #   answer on every asker-delegating path
      # @param reason [String, nil] the prose beside the verdict -- the note a
      #   deferred gate parks with, or why a denial denied
      # @param issue_id [String, nil] the issue an issue-scoped gate is about
      # @param criteria_digest [String, nil] the criteria the artifact carries
      # @return [Boolean] whether the artifact was approved
      def call(artifact, asker:, stage:, epic_slug:, policy: DEFAULT_POLICY, evidence_digest: nil, reason: nil,
               issue_id: nil, criteria_digest: nil)
        digest = artifact.digest
        started = @clock.call
        asked = asker.ask(artifact.gate_question)
        answer, latency = awaited(asked, started, digest, epic_slug:, stage:, policy:, evidence_digest:, reason:,
                                                          issue_id:, criteria_digest:)

        # Journal FIRST, register second, never the other way round: a journal
        # that raises -- a full disk, or a contract refusing a nil digest --
        # must leave NO standing approval behind, or `ensure_approved!` would
        # open for a digest with no record of anyone approving it. Fail-closed
        # is about this ordering as much as about the timeout.
        #
        # `task.defer_stop` around BOTH: a real `Journal#record` yields before
        # its bytes are down (an io_uring submit, a Monitor wait), and a
        # cancellation landing in that gap -- an answer already in hand, no
        # record of it yet -- must not leave an answered question with NO
        # decision at all, which is worse than the duplicate {#awaited}'s own
        # rescue already guards against. Deferral holds the cancellation off
        # until this block runs to completion, THEN raises it; it does not
        # swallow it.
        task.defer_stop do
          record(answer, artifact_digest: digest, epic_slug:, stage:, policy:, latency:, evidence_digest:, reason:,
                         issue_id:, criteria_digest:)
          @approved << digest if answer.approved?
        end
        answer.approved?
      ensure
        withdrawn(asker, asked)
        retired(asked)
      end

      def approved?(digest) = @approved.include?(digest)

      # An edited artifact hashes to a different digest, so a prior approval of
      # the old text never satisfies this.
      #
      # @param artifact [#digest]
      # @return [String] the approved digest
      # @raise [NotApproved] naming the digest when it was never approved
      def ensure_approved!(artifact)
        digest = artifact.digest
        raise NotApproved, "artifact #{digest} was not approved -- the gate refuses to open" unless approved?(digest)

        digest
      end

      # The standing approvals, for the bench to inspect without draining.
      def each(&block) = @approved.each(&block)

      # Rebuild a Gate's registry from a journal, so {#approved?} answers for
      # approvals a PRIOR process journaled. Denials fold to nothing, and fold
      # ORDER cannot matter for the same reason: add-only never revokes.
      #
      # Ignores the `(epic_slug, stage)` partition entirely -- the returned
      # registry answers for every approved digest in `entries`, across every
      # epic and stage. A caller wanting the partitioned view goes through
      # {Epic::Stage}/{SignoffQueue}.
      #
      # Replayed entries are NOT re-journaled; the returned Gate's own FUTURE
      # verdicts land in `journal:` like any other Gate's.
      #
      # `**options` rather than restating the defaults: a second copy of
      # {#initialize}'s went stale here once -- a deleted `Gate::MONOTONIC` left
      # a dangling `clock: MONOTONIC` raising `NameError` on every call that did
      # not pass `clock:`. Forwarding makes that drift unrepresentable.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records;
      #   foreign record types are skipped, the same contract {Journal.records}
      #   gives every reader here
      # @param options [Hash] forwarded verbatim to {#initialize}, which is what
      #   keeps the defaults in one place
      # @option options [Journal] :journal required, as for a plain `.new`
      # @option options [Numeric] :timeout defaults to `DEFAULT_TIMEOUT`
      # @option options [#call] :clock defaults to `RunClock::MONOTONIC`
      # @return [Gate]
      def self.from_journal(entries, **options)
        new(**options).tap { |gate| gate.send(:absorb, entries) }
      end

      private

      # An approval registers its digest, a denial does not -- {#call}'s live
      # rule replayed against records already on disk.
      #
      # PRIVATE, unlike {SignoffQueue#apply}, which is public because a LIVE
      # session folds its own decisions through it one at a time. Nothing here
      # has that caller, so a public one-record `#apply` would only be a new way
      # to break {#call}'s "journal first, register second" ordering: a live
      # Gate handed one hand-built Hash could register a standing approval with
      # no journal record behind it at all.
      #
      # Guarded per record even though {Journal.records}' type filter already
      # ran: {Contracts::RegistryEntry} is the TRUNCATION CANARY, and skipping a
      # damaged record would be exactly as silent a failure as folding a
      # truncated one in.
      #
      # @param entries [Enumerable<Hash, String>] see {.from_journal}
      # @return [self]
      #
      # Refused as {SignoffQueue::UnreadableRecord}, the queue's own refusal
      # over the same record type: the canary's ArgumentError is right for a
      # caller that built a value wrong, and a backtrace for a human whose
      # journal holds a damaged line.
      def absorb(entries)
        Journal.records(entries, type: SignoffQueue::JOURNAL_TYPE).each do |decision|
          register(decision)
        rescue ArgumentError => e
          raise SignoffQueue::UnreadableRecord.for(decision, e)
        end
        self
      end

      def register(decision)
        Contracts::RegistryEntry.check!(artifact_digest: decision["artifact_digest"], approved: decision["approved"])
        @approved << decision["artifact_digest"] if decision["approved"]
      end

      # `evidence_digest`/`reason` are FORWARDED, never derived: this class
      # gathers nothing and judges nothing, so the only honest value is the one
      # its caller handed down. A later path adds a VALUE here, never a column.
      def record(answer, reason:, **decided)
        @journal.record(GateDecision.new(approved: answer.approved?, answered_by: answer.surface,
                                         reason: answer.reason || reason, **decided))
      end

      # SCOPED TO THE WAIT ALONE, never the whole of {#call}. A cancellation
      # arriving before this runs -- inside `asker.ask`, which {#call} calls
      # before `awaited` -- has no verdict to journal and must propagate
      # untouched, not compute `@clock.call - started` against a `started`
      # this method was never handed. And one arriving AFTER `await` has
      # already returned a real answer is already journaled by {#call}'s own
      # `record`; catching it here too would write a second, contradictory
      # decision -- a human's "y" quietly withdrawn by an "interrupted" that
      # followed it -- for one question.
      def awaited(asked, started, digest, **decided)
        await(asked, started)
      rescue Async::Cancel
        interrupted(digest, started, **decided)
        raise
      end

      # A CANCELLED WAIT IS A DECIDED ONE. Async turns a real Ctrl-C into
      # exactly this exception while a fiber is parked in `await`, ahead of
      # the plain Interrupt the human actually sent -- that one only
      # re-emerges once every task has unwound, at the CALLER's reactor
      # boundary, which is where a name for it belongs. {#awaited}'s rescue
      # re-raises right after this returns: swallowing the cancellation
      # instead would leave the reactor's shutdown sweep waiting on a task
      # that never finishes.
      def interrupted(digest, started, **decided)
        record(Answer.deny(INTERRUPTED_SURFACE), artifact_digest: digest, latency: @clock.call - started, **decided)
      end

      # A WAIT THAT ENDED STOPS BEING OUTSTANDING, HOWEVER IT ENDED. The window
      # closing is lain's decision rather than the human's, so the asker is
      # still holding the set -- and an asker admits ONE outstanding set, so the
      # next gate on it would be refused for the rest of the run while a stale
      # inbox line offered a question that now decides nothing.
      #
      # It runs from an ENSURE, which is the whole of why it is correct: the
      # wait ends three ways, and only one of them returns here. A timeout
      # denies, an answer arrives -- and a caller polling its own interrupt
      # STOPS this fiber from outside, unwinding it at the await, so a
      # withdrawal written after the answer would never run on the one path
      # that most needs it. An approved set is already resolved, so withdrawing
      # it is a no-op and needs no branch.
      #
      # OPTIONAL and TOTAL. An asker that answers synchronously (the CLI's own
      # prompt) has nothing to withdraw and need not offer the message; a
      # withdrawal that fails must not overturn a verdict already journaled;
      # and `asked` is nil when the ask itself raised, which abandons nothing.
      def withdrawn(asker, asked)
        asker.withdraw(asked) if asker.respond_to?(:withdraw)
      rescue StandardError
        nil
      end

      # A WITHDRAWAL FREES THE ASKER; IT RETIRES NOTHING. The question stays in
      # the record, and every inbox reader folding the record lists it until
      # something names it consumed. For a tool call that is the committed turn
      # delivering the answer, and a gate has no turn: so the gate names the
      # question itself, on the journal its verdict went to, however the wait
      # ended -- answered, expired, or stopped from outside.
      #
      # That journal has to be one the live views ride. A gate handed a
      # journal no inbox reader folds retires the question in the file and
      # leaves it listed on every screen.
      #
      # Only a promise naming a question has one to retire: a synchronous
      # prompt and a standing answer write nothing a reader could list. TOTAL
      # for {#withdrawn}'s reason, and from the same ensure -- a retirement that
      # fails must not overturn a verdict already journaled, nor replace the
      # error a failed verdict is already raising.
      def retired(asked)
        return unless asked.respond_to?(:digest)

        @journal.record(Telemetry::QuestionsConsumed.new(turn: nil, digests: [asked.digest]))
      rescue StandardError
        nil
      end

      # An expired window denies through the same {Answer} the surfaces build,
      # so the journal and the return value read identically on either path.
      #
      # Answers the verdict AND its seconds together, because TWO clocks are in
      # play and only this method knows which applied. An answered gate is
      # measured by the injected `clock:`; an EXPIRED one reports the WINDOW
      # that fired, because the reactor's clock is what decided and reporting
      # the injected clock's delta would let a record claim 1000 seconds for a
      # 0.3-second window.
      #
      # `started` comes from the CALLER rather than being read here again: a
      # cancelled wait unwinds through {#awaited}'s own rescue, which needs
      # the same reference to report the same elapsed time this method would
      # have.
      def await(promise, started)
        [@window.around(task) { promise.await }, @clock.call - started]
      rescue Async::TimeoutError
        [Answer.deny(TIMEOUT_SURFACE), @window.seconds]
      end

      # `current?` rather than `current`, so the precondition is a CHECK rather
      # than an exception we translate: nothing else can raise here to be
      # mistaken for it.
      def task
        Async::Task.current? || raise(NoReactor, MISSING_REACTOR)
      end
    end
  end
end
require_relative "gate/policy"
require_relative "gate/adjudicator"
require_relative "gate/policies"
