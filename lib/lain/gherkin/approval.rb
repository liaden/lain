# frozen_string_literal: true

require "async"

module Lain
  module Gherkin
    # The fail-closed approval gate a {Criteria} must pass before anything
    # generates tests from it or records a closure against its digest. An
    # unanswered gate is a denial signed by the clock ({TIMEOUT_SURFACE}) -- the
    # same posture {Approval::Queue} takes, for the same reason: an unattended
    # gate must refuse, never wedge, and never default open.
    #
    # Every verdict lands in the Journal as a {Telemetry::GherkinApproval},
    # attributed to the SURFACE that answered, because on a study bench "who
    # approved this criteria, and how long they took" is evidence.
    #
    # An approval is remembered by the criteria's {Criteria#digest}. Because the
    # digest addresses CONTENT, one edited clause is a different digest -- an
    # approval of the old text does not carry to the new, and
    # {#ensure_approved!} refuses loudly, naming the un-approved digest. The
    # registry lives here (mutable coordination state, like {Approval::Queue}'s
    # parked set), not on the frozen values it tracks.
    #
    # It is deliberately MONOTONIC and add-only: a later denial of an approved
    # digest does NOT revoke the standing approval. Both verdicts land in the
    # Journal, and the audit trail -- not this process-local convenience -- is
    # where a reader reconstructs a contested history. Verdicts are never read
    # back at startup either, so a later session sees NONE of this session's.
    #
    # The gate depends only on `#ask(question) -> Promise`. It never reaches into
    # ask_human's `:message` Store events for attribution -- who answered rides
    # the promise's resolved value ({Answer}), process-local coordination the way
    # ask_human's own promise carries the human's reply, so no new meta key is
    # added to those replayable events.
    class Approval
      include Enumerable

      # A name rather than a nil, so a journal reader never guards. The same
      # one {Approval::Queue::TIMEOUT_SURFACE} uses.
      TIMEOUT_SURFACE = "timeout"

      # Generous because the answerer is a human at a terminal: a bound, not a
      # hurry, matching {Approval::Queue::DEFAULT_TIMEOUT}.
      DEFAULT_TIMEOUT = 300

      # Names the digest, so the edited-clause case reads as a different,
      # un-approved address rather than a mysterious miss.
      class NotApproved < Error; end

      # A verdict plus the surface that gave it. Deeply frozen (a boolean and an
      # interned String), so it is Ractor-shareable like every other value that
      # crosses a fiber boundary.
      Answer = Data.define(:approved, :surface) do
        def self.approve(surface) = new(approved: true, surface:)
        def self.deny(surface) = new(approved: false, surface:)

        def initialize(approved:, surface:)
          super(approved:, surface: -surface.to_s)
        end

        def approved? = approved
      end

      # @param journal [#record] where verdicts land as evidence; required, not
      #   defaulted -- a silently unjournaled approval would be a hole in the
      #   experiment record
      # @param timeout [Numeric] seconds an unanswered gate waits before the
      #   fail-closed denial
      # @param clock [#call] monotonic seconds, injectable so specs pin latency
      def initialize(journal:, timeout: DEFAULT_TIMEOUT, clock: RunClock::MONOTONIC)
        @journal = journal
        @timeout = timeout
        @clock = clock
        @approved = Set.new
      end

      # Render the criteria, ask, and block on the answer with a timeout ->
      # deny.
      #
      # Parking on the promise is safe inside a reactor because the surface that
      # answers runs as a SIBLING fiber. PRECONDITION: this must run under an
      # Async reactor; the timeout rides `Async::Task.current`, so a call
      # outside one raises a bare RuntimeError from `async`.
      #
      # @param criteria [Criteria]
      # @param asker [#ask] the `ask_human`-shaped duck; `#ask` returns a
      #   {Lain::Promise} the answering surface resolves with an {Answer}
      # @return [Boolean] whether the criteria was approved
      def call(criteria, asker:)
        digest = criteria.digest
        started = @clock.call
        answer = await(asker.ask(question_for(criteria)))
        latency = @clock.call - started

        @approved << digest if answer.approved?
        @journal.record(Telemetry::GherkinApproval.new(
                          criteria_digest: digest, approved: answer.approved?,
                          answered_by: answer.surface, latency:
                        ))
        answer.approved?
      end

      # The query a downstream checks before consuming a digest.
      def approved?(digest) = @approved.include?(digest)

      # The guard a generator calls first: return the approved digest, or refuse
      # loudly naming the un-approved one.
      #
      # @param criteria [Criteria]
      # @return [String] the approved criteria digest
      # @raise [NotApproved] naming the digest when it was never approved
      def ensure_approved!(criteria)
        digest = criteria.digest
        raise NotApproved, "criteria #{digest} was not approved -- generation refuses to run" unless approved?(digest)

        digest
      end

      # The standing approvals, for the bench to inspect without draining any
      # queue -- the same read-only observability {Approval::Queue#each} gives.
      def each(&block) = @approved.each(&block)

      private

      # A timeout denial is routed through the same {Answer} the surfaces build,
      # so the journal and the return value read identically on either path.
      def await(promise)
        Async::Task.current.with_timeout(@timeout) { promise.await }
      rescue Async::TimeoutError
        Answer.deny(TIMEOUT_SURFACE)
      end

      def question_for(criteria)
        <<~QUESTION
          Approve these acceptance criteria for test generation? Reply approve or deny.

          #{criteria.map(&:render).join("\n\n")}
        QUESTION
      end
    end
  end
end
