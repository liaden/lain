# frozen_string_literal: true

require "async"

module Lain
  module Approval
    # Construction contract for {GateDecision}, the same validate-then-freeze
    # convention {Telemetry::Guards} carries -- a {Lain::Guard} carrier checked
    # BEFORE the auto-frozen Data value exists, so the record never touches
    # ActiveModel and stays `Ractor.shareable?`.
    module Guards
      # The verdict a surface hands back must BE a verdict. {Gate::Answer} is
      # what decides whether a digest is registered, so a non-boolean here is
      # worse than the same value in {GateDecision}: `"yes"` is truthy, so
      # `#approved?` would open the gate and only the record's own guard would
      # object -- after the fact, and (before the ordering fix) too late. The
      # deciding value guards itself, at the same standard as the recorded one.
      class Answer < Guard
        attribute :approved
        attribute :surface
        validates :approved, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :surface, presence: { message: "must name the surface that answered, got nil" }
      end

      # A gate verdict must name what it judged, WHERE it was judged (the
      # `(epic_slug, stage)` partition a sign-off queue folds on), who answered,
      # and under which policy. `approved` is guarded by inclusion rather than
      # `presence:`, which cannot reject `false` -- the very verdict this record
      # most often carries (the {Telemetry::Guards::RequestSent} idiom).
      class GateDecision < Guard
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
        # Guarded rather than coerced: `to_f` turns nil and "quick" alike into
        # 0.0, which writes "answered instantly" -- a measurement nobody made --
        # into the experiment record. A verdict cannot take negative time either.
        validates :latency, numericality: { greater_than_or_equal_to: 0,
                                            message: "must be seconds >= 0, got %<value>s" }
      end
    end

    # One verdict over one artifact, journaled as `gate_decision`.
    # `artifact_digest` is the JOIN KEY: it addresses the artifact's CONTENT, so
    # an edited plan is a different, un-approved address rather than a stale
    # match -- the same content-addressed refusal {Telemetry::GherkinApproval}
    # keeps for a Criteria. `epic_slug` and `stage` are the PARTITION key a
    # sign-off queue folds these records on, which is why both are required and
    # neither is derivable from the digest.
    #
    # `answered_by` names the surface that gave the verdict (the human, a
    # meta-agent, or {Gate::TIMEOUT_SURFACE} when the fail-closed clock denied an
    # unanswered gate) and `policy` names HOW it was reached (`"interactive"`
    # today; a later card's `"hands_off"`/`"deferred"`/`"signoff"` wrap the same
    # record). The two are independent: a `"deferred"` policy still journals a
    # real surface, and reading either off the other would be a guess.
    #
    # `latency` is SECONDS, and the two nullable fields are the shape's whole
    # future. `evidence_digest` addresses the spike/research evidence a verdict
    # was reached ON; `reason` is the prose rationale beside it -- the note a
    # deferred gate parks with when the evidence spawn failed, and the only place
    # a DENIAL can say why. Both are nil on every path shipped so far.
    #
    # They exist NOW because a durable wire shape is designed once: a reader
    # added later must be able to ask these fields of every record ever written,
    # and a field added later would split the journal into two shapes for one
    # record type -- a migration, not an addition. Nullable is a value here
    # ("nothing was gathered", "no rationale was given"), not a missing field.
    # Later cards POPULATE these two; nothing may widen the shape again.
    GateDecision = Data.define(:artifact_digest, :epic_slug, :stage, :approved, :answered_by, :policy,
                               :latency, :evidence_digest, :reason) do
      include Telemetry::Journalable

      def initialize(artifact_digest:, epic_slug:, stage:, approved:, answered_by:, policy:, latency:,
                     evidence_digest: nil, reason: nil)
        # Stringified BEFORE the guard, so `presence:` judges the bytes that
        # actually get journaled: a stage object whose `#to_s` is blank passes a
        # presence check on the raw object and then writes an empty partition
        # key, which is the one value a queue folding on (epic_slug, stage) can
        # never match back.
        epic_slug = interned(epic_slug)
        stage = interned(stage)
        answered_by = interned(answered_by)
        policy = interned(policy)
        Guards::GateDecision.check!(artifact_digest:, epic_slug:, stage:, approved:, answered_by:, policy:,
                                    latency:)

        super(artifact_digest: artifact_digest.dup.freeze, epic_slug:, stage:, approved:, answered_by:, policy:,
              latency: latency.to_f, evidence_digest: evidence_digest&.dup&.freeze, reason: reason&.dup&.freeze)
      end

      private

      # Interned (`-str`), where the two digests are dup'd-and-frozen: the
      # {Telemetry::Verdict} split, and for its reason -- a stage or a surface
      # repeats across every record in a run, a digest does not.
      def interned(value) = -value.to_s
    end

    # The ARTIFACT gate: the fail-closed approval any artifact answering
    # `#digest` and `#gate_question` must pass before an irreversible action
    # consumes that digest. It renders nothing itself -- the artifact owns its
    # human-facing question, which is the one part of {Gherkin::Approval} that
    # never generalized -- asks through the injected `ask_human`-shaped duck
    # (`#ask` returns a {Lain::Promise} without awaiting), and BLOCKS on that
    # promise with a timeout. Silence is a denial signed by the clock
    # ({TIMEOUT_SURFACE}): an unattended gate must refuse, never wedge, and never
    # default open.
    #
    # == Three things in this codebase are called a gate
    #
    # * {Approval::Gate} (here) gates an ARTIFACT -- an epic plan, an issue plan,
    #   a criteria doc -- by its content address, across a whole stage of work.
    # * {Effect::Handler::Gate} gates one TOOL CALL at interpretation time,
    #   through a `#call(effect, context) -> Boolean` policy seam, with
    #   {Approval::Queue} as its parked-item backing and {Gate::DenyAll} as its
    #   default. It knows nothing about artifacts or digests.
    # * {Gherkin::Approval} is this class's ancestor, specialized to a
    #   {Gherkin::Criteria}: same constructor, same monotonic registry, same
    #   fail-closed timeout, but it renders the scenarios itself and journals a
    #   `gherkin_approval`. It is deliberately UNTOUCHED by this class;
    #   converging the two is a named follow-up, not a silent refactor.
    #
    # == The registry, and content-addressed refusal
    #
    # An approval is remembered by the artifact's digest, so {#approved?} and
    # {#ensure_approved!} are the small guard a caller runs before an
    # irreversible step. Because the digest addresses CONTENT, one edited
    # sentence is a different digest and the prior approval does not carry:
    # {#ensure_approved!} refuses loudly, naming the un-approved address.
    #
    # The registry is MONOTONIC and add-only -- a later denial of an
    # already-approved digest does NOT revoke the standing approval. Both
    # verdicts land in the Journal, which is the audit record of who decided what
    # and when; the registry is only the process-local convenience answering "may
    # this digest be acted on". It is process-local in the other direction too:
    # nothing is read back at startup, so a later session sees none of this
    # session's approvals (rebuilding the registry from journaled
    # `gate_decision` records is a later card's job, not this one's).
    #
    # == The stage boundary is NOT this class's guarantee
    #
    # {Epic::Stage}'s rule -- a stage's gates may only open once every earlier
    # stage of the same epic has its sign-off partition drained -- is enforced on
    # the POLICY seam ({Gate::Policy#decide}), not here. {#call} is public and
    # skips it entirely, so calling this directly can approve an
    # implementation-stage artifact while that epic's research sign-offs are
    # still parked. That is deliberate: the check needs {Epic}, and pulling the
    # epic vocabulary into this class (and thus next to {Gherkin::Approval},
    # which gates a Criteria and knows nothing of epics) would cost more than the
    # hole does. Go through a Policy if you want the boundary.
    #
    # == The asker duck, and where attribution lives
    #
    # The gate depends only on `#ask(question) -> Promise`. Who answered rides
    # the promise's resolved value (an {Answer}), process-local coordination the
    # way ask_human's own promise carries the human's reply -- so no new meta key
    # is added to any replayable event, and the gate stays blind to which surface
    # spoke.
    class Gate
      include Enumerable

      # The surface a denial wears when the window expired and the clock decided
      # -- the name {Approval::Queue::TIMEOUT_SURFACE} and
      # {Gherkin::Approval::TIMEOUT_SURFACE} already use, a name rather than a nil
      # so a journal reader never guards.
      TIMEOUT_SURFACE = "timeout"

      # Generous because the answerer is a human reading a plan: a bound, not a
      # hurry, matching {Approval::Queue::DEFAULT_TIMEOUT}.
      DEFAULT_TIMEOUT = 300

      # The policy label this class's own path wears. It is journaled, never
      # branched on here: {#call} IS the asker-delegating path, and a later
      # card's policies wrap this call rather than switching inside it.
      DEFAULT_POLICY = "interactive"

      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # An irreversible step that would consume an un-approved artifact, refused.
      # Names the digest, so the edited-artifact case reads as a different,
      # un-approved address rather than a mysterious miss.
      class NotApproved < Error; end

      # {#call} parks a fiber, so it needs a reactor to park under. Raised in
      # place of `async`'s bare `RuntimeError: No async task available!`, which
      # names neither the caller that broke the precondition nor the one-word
      # fix.
      class NoReactor < Error; end

      MISSING_REACTOR = "Approval::Gate#call parks on the asker's promise -- run it inside Sync { } or " \
                        "Async { } (there is no reactor on this fiber)"
      private_constant :MISSING_REACTOR

      # The asker's answer: a verdict plus the surface that gave it. Every
      # surface -- the human frontend, a meta-agent, this gate's own timeout --
      # builds one; the gate reads `#approved?` and `#surface` off it and stays
      # blind to which. Deeply frozen (a boolean and an interned String), so it
      # is Ractor-shareable like every value that crosses a fiber boundary.
      #
      # Structurally identical to {Gherkin::Approval::Answer} and deliberately
      # not shared with it: this namespace loads BEFORE gherkin/, and the general
      # gate must not depend on the specialized one. Either satisfies the other's
      # duck, which is what makes the follow-up convergence cheap.
      Answer = Data.define(:approved, :surface) do
        def self.approve(surface) = new(approved: true, surface:)
        def self.deny(surface) = new(approved: false, surface:)

        def initialize(approved:, surface:)
          surface = -surface.to_s
          Guards::Answer.check!(approved:, surface:)

          super
        end

        def approved? = approved
      end

      # @param journal [#record] where verdicts land as evidence; required, not
      #   defaulted, for the same reason {Approval::Queue}'s is -- a silently
      #   unjournaled approval would be a hole in the experiment record
      # @param timeout [Numeric] seconds an unanswered gate waits before the
      #   fail-closed denial. The window is enforced by the REACTOR's clock
      #   (`Async::Task#with_timeout`), never by `clock:` below.
      # @param clock [#call] monotonic seconds. It measures LATENCY ONLY and
      #   does not bound the window: injecting a scripted clock makes a
      #   journaled latency deterministic, it does NOT make the timeout fire
      #   sooner, so a spec exercising the timeout still waits real seconds.
      #   The one place the two clocks would contradict each other -- the
      #   latency on an expired gate -- is settled in {#await}: an expired gate
      #   reports the window, not this clock's delta.
      def initialize(journal:, timeout: DEFAULT_TIMEOUT, clock: MONOTONIC)
        @journal = journal
        @timeout = timeout
        @clock = clock
        @approved = Set.new
      end

      # Ask the artifact's own question, block on the answer with a timeout ->
      # deny, journal the verdict, and remember an approved digest.
      #
      # Parking on the promise is safe inside a reactor because the answering
      # surface runs as a SIBLING fiber -- the two-fiber shape ask_human's
      # perform/reply already proves out. PRECONDITION: this must run under an
      # Async reactor (a `Sync`/`Async` block) -- the same precondition every
      # parking seam here carries -- and a call outside one raises {NoReactor}
      # rather than `async`'s bare RuntimeError.
      #
      # @param artifact [#digest, #gate_question] the thing being gated
      # @param asker [#ask] the `ask_human`-shaped duck; `#ask` returns a
      #   {Lain::Promise} the answering surface resolves with an {Answer}
      # @param stage [#to_s] the stage this gate sits on
      # @param epic_slug [#to_s] the epic it belongs to; with `stage`, the
      #   partition key a sign-off queue folds decisions on
      # @param policy [String] how the verdict was reached, journaled verbatim
      # @return [Boolean] whether the artifact was approved
      def call(artifact, asker:, stage:, epic_slug:, policy: DEFAULT_POLICY)
        digest = artifact.digest
        answer, latency = await(asker.ask(artifact.gate_question))

        # Journal FIRST, register second, and never the other way round: a
        # journal that raises -- a full disk, or {Guards::GateDecision} refusing
        # a nil digest or an unnamed stage -- must leave NO standing approval
        # behind, or `ensure_approved!` would open for a digest with no record of
        # anyone approving it. Fail-closed is not only about the timeout; it is
        # also about this ordering.
        record(answer, artifact_digest: digest, epic_slug:, stage:, policy:, latency:)
        @approved << digest if answer.approved?
        answer.approved?
      end

      # Whether this digest carries a standing approval -- the small query a
      # caller checks before an irreversible step.
      def approved?(digest) = @approved.include?(digest)

      # The guard an irreversible action calls first: return the approved digest,
      # or refuse loudly naming the un-approved one. An edited artifact hashes to
      # a different digest, so a prior approval of the old text never satisfies
      # it.
      #
      # @param artifact [#digest]
      # @return [String] the approved digest
      # @raise [NotApproved] naming the digest when it was never approved
      def ensure_approved!(artifact)
        digest = artifact.digest
        raise NotApproved, "artifact #{digest} was not approved -- the gate refuses to open" unless approved?(digest)

        digest
      end

      # The standing approvals, for the bench to inspect without draining
      # anything -- the same read-only observability {Approval::Queue#each} gives.
      def each(&block) = @approved.each(&block)

      private

      # `evidence_digest`/`reason` are left at their nil defaults, which is this
      # path's honest answer and not a placeholder: an interactive gate gathers
      # no evidence and the surface gives no prose. The fields exist so an
      # evidence-bearing path adds a VALUE rather than a column.
      def record(answer, artifact_digest:, epic_slug:, stage:, policy:, latency:)
        @journal.record(GateDecision.new(artifact_digest:, epic_slug:, stage:, approved: answer.approved?,
                                         answered_by: answer.surface, policy:, latency:))
      end

      # Await the answer, or -- on an expired window -- a denial signed by the
      # clock, routed through the same {Answer} the surfaces build so the journal
      # and the return value read identically on either path.
      #
      # Answers the verdict AND its seconds together, because TWO clocks are in
      # play and only this method knows which one applied. An answered gate is
      # measured by the injected `clock:`. An EXPIRED one reports the window that
      # fired (`@timeout`) instead: the reactor's clock is what decided, the
      # injected clock never bounded anything, and reporting its delta here would
      # let a record claim 1000 seconds for a 0.3-second window. The window is
      # the honest number, and it is exact rather than measured.
      def await(promise)
        started = @clock.call
        [task.with_timeout(@timeout) { promise.await }, @clock.call - started]
      rescue Async::TimeoutError
        [Answer.deny(TIMEOUT_SURFACE), @timeout]
      end

      # `current?` rather than `current`, so the precondition is a CHECK we
      # answer for ourselves rather than an exception we translate: nothing else
      # can raise here to be mistaken for it.
      def task
        Async::Task.current? || raise(NoReactor, MISSING_REACTOR)
      end
    end
  end
end
require_relative "gate/policy"
