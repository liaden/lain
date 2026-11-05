# frozen_string_literal: true

require "async"

module Lain
  module Epic
    module Contracts
      # Only the surface: {Gate::Answer} coerces its verdict through
      # {Approval::Verdict.coerce} after this check, so `"yes"` still never
      # reaches a gate as a truthy approval.
      class Answer < Declarative::Carrier
        attribute :surface
        validates :surface, presence: { message: "must name the surface that answered, got nil" }
      end

      # The verdict is not an attribute here: {Epic::GateDecision} coerces it
      # through {Approval::Verdict.coerce} before this check runs.
      class GateDecision < Declarative::Carrier
        attribute :artifact_digest
        attribute :epic_slug
        attribute :stage
        attribute :answered_by
        attribute :policy
        attribute :latency
        validates :artifact_digest, presence: { message: "must name the artifact it judged, got nil" }
        validates :epic_slug, presence: { message: "must name the epic it belongs to, got nil" }
        validates :stage, presence: { message: "must name the stage it gated, got nil" }
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
    end

    # The ARTIFACT gate: the fail-closed approval any artifact answering
    # `#digest` and `#gate_question` must pass before an irreversible action
    # consumes that digest. It renders nothing itself -- the artifact owns its
    # human-facing question -- asks through the injected `ask_human`-shaped
    # duck, and BLOCKS on that promise with a timeout. Silence is settled by
    # the injected {Approval::Silence} rule and signed by the clock: an
    # unattended gate holds or refuses, never wedges, and never defaults open.
    #
    # == Two things in this codebase are called a gate
    #
    # * {Epic::Gate} (here) gates an ARTIFACT by its content address, across
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
    # The registry is each partition's standing as {Epic::Signoff} folds it, so
    # a later denial revokes an approval, and so does approving a newer draft of
    # the same partition. A digest is approved while any partition it was
    # decided in stands approved at it. The registry starts empty regardless of
    # what an earlier session journaled; {.from_journal} is the opt-in for that.
    #
    # == The stage boundary is NOT this class's guarantee
    #
    # {Epic::Stage}'s rule -- a stage's gates may only open once every earlier
    # stage of the same epic has its sign-off partition drained -- is enforced
    # on the POLICY seam ({Gate::Policy#decide}), not here. {#call} is public and
    # skips it entirely, so calling this directly can approve an
    # implementation-stage artifact while that epic's research sign-offs are
    # still parked. Deliberate: the boundary needs the sign-off queue, which
    # this class is not handed. Go through a Policy for the boundary. The stage
    # must still be a pipeline stage, because {Signoff} keys the registry by it.
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
      # a hurry. A chat's interactive gate takes the project's `approval timeout:`
      # instead; this is what the non-interactive policies and a bare Gate keep.
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

        # Arms one reactor timer per wait, for what is left of the window.
        class Bounded
          # @return [Numeric] the window this arms, for {#await}'s
          #   fired-through-the-window report
          attr_reader :seconds

          def initialize(seconds)
            @seconds = seconds
          end

          # A question asked again waits only for what is left, so replies
          # that decide nothing cannot hold the window open.
          #
          # @return [Opened] this window, its clock started now
          def open = Opened.new(seconds:, opened: RunClock::MONOTONIC.call)

          # A window whose clock is running.
          Opened = Data.define(:seconds, :opened) do
            def around(task, &)
              task.with_timeout([seconds - (RunClock::MONOTONIC.call - opened), 0].max, &)
            end
          end
        end

        # Arms NO reactor timer at all, so nothing is ever handed to
        # `with_timeout` for an unbounded wait to go wrong over. Only an
        # {Async::Cancel} -- Ctrl-C included -- ever ends the wait this wraps.
        module Unbounded
          def self.seconds = nil

          def self.open = self

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

      MISSING_REACTOR = "Epic::Gate#call parks on the asker's promise -- run it inside Sync { } or " \
                        "Async { } (there is no reactor on this fiber)"
      private_constant :MISSING_REACTOR

      # A verdict plus the surface that gave it. Deeply frozen, so it is
      # Ractor-shareable like every value that crosses a fiber boundary.
      #
      # The verdict's note is what the ANSWERING side knows about its own
      # verdict, and it is journaled over whatever reason the caller
      # forwarded, because it is the more specific account.
      Answer = Data.define(:verdict, :surface) do
        def self.approve(surface) = new(verdict: Approval::Verdict::Approve.new, surface:)
        def self.deny(surface) = new(verdict: Approval::Verdict::Deny.new, surface:)

        # @param verdict [Approval::Verdict::Approve, Approval::Verdict::Hold, Approval::Verdict::Deny]
        # @param surface [#to_s] who gave it
        def initialize(verdict:, surface:)
          surface = -surface.to_s
          Contracts::Answer.check!(surface:)

          super(verdict: Approval::Verdict.coerce(verdict), surface:)
        end

        def approved? = verdict.approved?

        # @return [String, nil] the verdict's note
        def reason = verdict.note
      end

      # What a human wrote, as a surface hands it over: the gate reads it,
      # because only the artifact knows whether a wave's clauses apply.
      # `words` is nil when the input ended with nothing written.
      Said = Data.define(:words, :surface) do
        def initialize(words:, surface:) = super(words: words&.dup&.freeze, surface: -surface.to_s)
      end

      # A reply that decided nothing, and why when more is known than that
      # the grammar could not read it. The gate asks again.
      Unheard = Data.define(:words, :why) do
        def initialize(words:, why: nil) = super(words: words&.dup&.freeze, why: why&.dup&.freeze)
      end

      # What a wave's one answer decided, issue by issue, and who gave it.
      Outcome = Data.define(:verdicts, :surface) do
        def initialize(verdicts:, surface:)
          super(verdicts: verdicts.to_h { |id, verdict| [-id.to_s, Approval::Verdict.coerce(verdict)] }.freeze,
                surface: -surface.to_s)
        end

        # @return [Array<String>] the ids approved
        def approved = verdicts.select { _2.approved? }.keys

        # @return [Hash{String => String, nil}] each id denied, to its reason
        def denied = notes(&:denied?)

        # @return [Hash{String => String, nil}] each id held, to its note
        def held = notes(&:held?)

        # @param issue_id [String] one issue of the wave
        # @return [Answer] the verdict journaled for that one issue
        def answer(issue_id) = Answer.new(verdict: verdicts.fetch(issue_id), surface:)

        private

        def notes(&) = verdicts.select { |_, verdict| yield(verdict) }.transform_values(&:note)
      end

      # @param journal [#record] where verdicts land as evidence; required, not
      #   defaulted, because a silently unjournaled approval would be a hole in
      #   the experiment record
      # @param timeout [Numeric, Window::Unbounded] seconds an unanswered gate
      #   waits before the silence rule settles it -- wrapped in {Window::Bounded}
      #   -- or {Window::Unbounded} itself for a wait that only a cancellation
      #   ends. The window is enforced by the REACTOR's clock, never by
      #   `clock:` below.
      # @param clock [#call] monotonic seconds, measuring LATENCY ONLY. A
      #   scripted clock makes a journaled latency deterministic; it does NOT
      #   make the timeout fire sooner, so a spec exercising the timeout still
      #   waits real seconds. Where the two clocks would contradict each other
      #   is settled in {#await}.
      # @param wall [#call] the time of day, as a Time, for naming when a wait is settled
      # @param silence [Approval::Silence::Hold, Approval::Silence::Deny] what a
      #   closed window settles as; bare, it denies, and a project's config
      #   picks it through {Approval::Silence.from}
      def initialize(journal:, timeout: DEFAULT_TIMEOUT, clock: RunClock::MONOTONIC, wall: -> { Time.now },
                     silence: Approval::Silence::DENY)
        @journal = journal
        @silence = silence
        @window = timeout.is_a?(Numeric) ? Window.bounded(timeout) : timeout
        @clock = clock
        @wall = wall
        @signoff = Signoff.unit
        @decided = {}
      end

      # Ask the artifact's own question, block on the answer with a timeout the
      # silence rule settles, journal the verdict, and remember an approved digest.
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
      # @return [Boolean, Outcome] whether the artifact was approved, or for a
      #   wave (an artifact answering `#submissions`) which of its issues were
      # @raise [UnknownStage] when `stage` is not a pipeline stage, before anyone is asked
      def call(artifact, asker:, stage:, epic_slug:, policy: DEFAULT_POLICY, evidence_digest: nil, reason: nil,
               issue_id: nil, criteria_digest: nil)
        Stage.new(stage)
        decided = { epic_slug:, stage:, policy:, evidence_digest:, reason:, issue_id:, criteria_digest: }
        started = @clock.call
        asked = asker.ask(artifact.gate_question)
        answer, latency = awaited(asked, asker, started, artifact, **decided) do |unheard|
          withdrawn(asker, asked)
          retired(asked)
          asked = asker.ask(GateReply.again(unheard, artifact.gate_question))
        end

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
        task.defer_stop { settle(artifact, answer, latency:, **decided) }
      ensure
        withdrawn(asker, asked)
        retired(asked)
      end

      # @param digest [String] an artifact's address
      # @return [Boolean] whether a partition that decided it stands approved at it
      def approved?(digest) = @decided.fetch(digest, []).any? { |partition| @signoff.approved?(partition, digest) }

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
      def each(&block) = @decided.keys.select { |digest| approved?(digest) }.each(&block)

      # Rebuild a Gate's registry from a journal, so {#approved?} answers for
      # approvals a PRIOR process journaled, and not for one a later decision revoked.
      #
      # Asked by digest alone, because an irreversible caller holds the
      # artifact and not its partition; revoked per partition, because a deny
      # or a newer draft only speaks for the partition it was made in.
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

      # Journaled once the question is out rather than before it, so an asker
      # that refuses to ask leaves no wait that no decision will ever close.
      # A wave journals 1 wait per issue, because each issue's decision closes
      # its own, under 1 question key, because the human is asked once.
      # A standing answer is no human's, so nothing is waited on. TOTAL, for
      # {#retired}'s reason: the record of a wait must not replace the verdict,
      # or the refusal of one, that the decision record is about to give.
      def waiting(artifact, asker, epic_slug:, stage:, issue_id:, **)
        return if asker.respond_to?(:standing?) && asker.standing?

        deadline = Telemetry::AwaitingHuman.deadline(@window.seconds, from: @wall.call)
        items = asked_items(artifact, issue_id)
        question_key = Canonical.digest(items.map { |item, _id| item.digest }) if items.size > 1
        items.each do |item, id|
          @journal.record(Telemetry::AwaitingHuman.new(kind: "gate", ref: item.digest, deadline:, epic_slug:, stage:,
                                                       summary: Telemetry::AwaitingHuman.lead(item.gate_question),
                                                       issue_id: id, question_key:,
                                                       sha: (item.changeset if item.respond_to?(:changeset))))
        end
      rescue StandardError
        nil
      end

      def asked_items(artifact, issue_id)
        return [[artifact, issue_id]] unless artifact.respond_to?(:submissions)

        artifact.submissions.map { |submission| [submission, submission.issue_id] }
      end

      # {#call}'s live rule replayed against records already on disk.
      #
      # PRIVATE, unlike {SignoffQueue#apply}, which is public because a LIVE
      # session folds its own decisions through it one at a time. Nothing here
      # has that caller, so a public one-record `#apply` would only be a new way
      # to break {#call}'s "journal first, register second" ordering: a live
      # Gate handed one hand-built Hash could register a standing approval with
      # no journal record behind it at all.
      #
      # A damaged record is refused by {Signoff} as {SignoffQueue::UnreadableRecord},
      # never skipped: skipping a denial would leave the approval it revoked standing.
      #
      # @param entries [Enumerable<Hash, String>] see {.from_journal}
      # @return [self]
      def absorb(entries)
        Journal.records(entries, type: SignoffQueue::JOURNAL_TYPE).each do |decision|
          register(Journal.payload_of(decision))
        end
        self
      end

      # One record per decision, each journaled before its digest registers. A
      # wave is one question and one decision per issue, under that issue's own
      # digest, so `ensure_approved!` and the per-issue sign-off partitions
      # never learn that a wave asked it.
      def settle(artifact, answer, **decided)
        result, ballots = ballot(artifact, answer)
        ballots.each do |digest, verdict, scope|
          register(record(verdict, artifact_digest: digest, **decided, **scope).to_journal)
        end
        result
      end

      def ballot(artifact, answer)
        return [answer.approved?, [[artifact.digest, answer, {}]]] unless artifact.respond_to?(:submissions)

        outcome = answer.is_a?(Outcome) ? answer : artifact.outcome(answer)
        [outcome, artifact.submissions.map do |submission|
          [submission.digest, outcome.answer(submission.issue_id),
           { issue_id: submission.issue_id, criteria_digest: submission.criteria_digest }]
        end]
      end

      # @param fields [Hash{String=>Object}] one decision as journaled
      def register(fields)
        @signoff = @signoff.step(Telemetry::Untyped.new(fields:))
        digest = fields["artifact_digest"].to_s
        @decided[digest] = [*@decided[digest], partition_of(fields)].uniq
      end

      def partition_of(fields)
        SignoffQueue::Partition.new(epic_slug: fields["epic_slug"], stage: fields["stage"],
                                    issue_id: fields["issue_id"])
      end

      # `evidence_digest`/`reason` are FORWARDED, never derived: this class
      # gathers nothing and judges nothing, so the only honest value is the one
      # its caller handed down. A later path adds a VALUE here, never a column.
      # @return [GateDecision] the decision journaled
      def record(answer, reason:, **decided)
        GateDecision.new(verdict: answer.verdict, answered_by: answer.surface, reason:, **decided)
                    .tap { |decision| @journal.record(decision) }
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
      #
      # The wait is journaled inside the same scope, so a cancellation landing
      # while that record is written still closes it with a decision.
      #
      # A reply that decided nothing is handed to the block, which asks again
      # and answers the new promise; the new wait gets only what is left of
      # the window opened for the first.
      def awaited(asked, asker, started, artifact, **decided)
        waiting(artifact, asker, **decided)
        window = @window.open
        heard = await(asked, started, artifact, window)
        heard = await(yield(heard.first), started, artifact, window) while heard.first.is_a?(Unheard)
        heard
      rescue Async::Cancel
        interrupted(artifact, started, **decided)
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
      def interrupted(artifact, started, **decided)
        settle(artifact, Answer.new(verdict: Approval::Verdict::Deny.new(note: INTERRUPTED_SURFACE),
                                    surface: INTERRUPTED_SURFACE),
               latency: @clock.call - started, **decided)
      end

      # A WAIT THAT ENDED STOPS BEING OUTSTANDING, HOWEVER IT ENDED. The window
      # closing is lain's decision rather than the human's, so the asker is
      # still holding the set -- and an asker admits ONE outstanding set, so the
      # next gate on it would be refused for the rest of the run while a stale
      # inbox line offered a question that now decides nothing.
      #
      # It runs from an ENSURE, which is the whole of why it is correct: the
      # wait ends three ways, and only one of them returns here. A timeout
      # settles, an answer arrives -- and a caller polling its own interrupt
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

      # An expired window settles through the same {Answer} the surfaces build,
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
      def await(promise, started, artifact, window)
        [read(window.around(task) { promise.await }, artifact), @clock.call - started]
      rescue Async::TimeoutError
        [Answer.new(verdict: @silence.verdict(@window.seconds), surface: TIMEOUT_SURFACE), @window.seconds]
      end

      def read(resolved, artifact)
        return resolved unless resolved.is_a?(Said)
        return artifact.heard(resolved) if artifact.respond_to?(:heard)

        GateReply.answer(resolved.words, surface: resolved.surface)
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
