# frozen_string_literal: true

require "async"

module Lain
  module Gherkin
    # GG-1: the fail-closed approval gate a {Criteria} must pass before anything
    # generates tests from it or records a closure against its digest. {#call}
    # renders the scenarios into a question, asks through the injected
    # `ask_human`-shaped duck ({#ask} returns a {Lain::Promise} without awaiting,
    # `tools/ask_human.rb:87`), and BLOCKS on that promise with a timeout. An
    # unanswered gate is a denial signed by the clock ({TIMEOUT_SURFACE}) -- the
    # same fail-closed posture {Approval::Queue} inherits, and for the same
    # reason: an unattended gate must refuse, never wedge, and never default open.
    #
    # Every verdict lands in the Journal as a {Telemetry::GherkinApproval},
    # attributed to the SURFACE that answered -- the human, the opt-in
    # `"auto_approver"` meta-agent, or the clock -- because on a study bench "who
    # approved this criteria, and how long they took" is evidence.
    #
    # == The registry, and content-addressed refusal
    #
    # An approval is remembered by the criteria's {Criteria#digest}, so
    # {#approved?}/{#ensure_approved!} are the small guard a downstream calls
    # before consuming a digest (G3's generation, P2's closure records). Because
    # the digest addresses the criteria's CONTENT, one edited clause is a
    # different digest -- an approval of the old text does not carry to the new,
    # and {#ensure_approved!} refuses loudly, naming the un-approved digest. The
    # registry lives here (mutable coordination state, like {Approval::Queue}'s
    # parked set), not on the frozen values it tracks.
    #
    # The registry is deliberately MONOTONIC and add-only: a later denial of a
    # digest already approved does NOT revoke the standing approval -- the two
    # verdicts BOTH land in the Journal (the audit record of who decided what,
    # when), and the registry is only the process-local convenience that answers
    # "may this digest be generated from". Once a surface says yes, yes stands;
    # the audit trail, not the registry, is where a reader reconstructs a
    # contested history. It is also process-local: recorded verdicts are not
    # read back at startup, so a later session sees NONE of this session's prior
    # approvals (rebuilding the registry from journalled `gherkin_approval`
    # records is deliberate future work, not this card's).
    #
    # == The asker duck, and where attribution lives
    #
    # The gate depends only on `#ask(question) -> Promise`. It never reaches into
    # ask_human's `:message` Store events for attribution -- who answered rides
    # the promise's resolved value ({Answer}), process-local coordination the way
    # ask_human's own promise carries the human's reply, so no new meta key is
    # added to those replayable events. The surface that answers (the human via
    # the frontend, the `auto_approver` meta-agent opt-in at the call site)
    # resolves the promise with an {Answer}; the gate stays blind to which.
    class Approval
      include Enumerable

      # The surface a denial wears when the window expired and the clock decided
      # -- the same name {Approval::Queue::TIMEOUT_SURFACE} uses, a name rather
      # than a nil so a journal reader never guards.
      TIMEOUT_SURFACE = "timeout"

      # Generous because the answerer is a human at a terminal: a bound, not a
      # hurry, matching {Approval::Queue::DEFAULT_TIMEOUT}.
      DEFAULT_TIMEOUT = 300

      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # A generation (or closure record) that would consume an un-approved
      # criteria, refused. Names the digest so a caller traces exactly which
      # criteria was never approved -- the edited-clause case reads as a
      # different, un-approved address, not a mysterious miss.
      class NotApproved < Error; end

      # The asker's answer: a verdict plus the surface that gave it. The human
      # surface and the `auto_approver` meta-agent each build one; the gate
      # reads `#approved?` and `#surface` off it and stays blind to which
      # answered. Deeply frozen (a boolean and an interned String), so it is
      # Ractor-shareable like every other value that crosses a fiber boundary.
      Answer = Data.define(:approved, :surface) do
        def self.approve(surface) = new(approved: true, surface:)
        def self.deny(surface) = new(approved: false, surface:)

        def initialize(approved:, surface:)
          super(approved:, surface: -surface.to_s)
        end

        def approved? = approved
      end

      # @param journal [#record] where verdicts land as evidence; required, not
      #   defaulted, for the same reason {Approval::Queue}'s is -- a silently
      #   unjournaled approval would be a hole in the experiment record
      # @param timeout [Numeric] seconds an unanswered gate waits before the
      #   fail-closed denial
      # @param clock [#call] monotonic seconds, injectable so specs pin latency
      def initialize(journal:, timeout: DEFAULT_TIMEOUT, clock: MONOTONIC)
        @journal = journal
        @timeout = timeout
        @clock = clock
        @approved = Set.new
      end

      # Render the criteria, ask, and block on the answer with a timeout ->
      # deny. Records the verdict, remembers an approved digest, and answers
      # whether the criteria may be generated from.
      #
      # Parking on the promise is safe inside a reactor because the surface that
      # answers runs as a SIBLING fiber (the frontend's reply-path, or the
      # `auto_approver` surface) -- the two-fiber shape ask_human's perform/reply
      # already proves out. PRECONDITION: this must run under an Async reactor
      # (a `Sync`/`Async` block); the timeout rides `Async::Task.current`, so a
      # call outside one raises a bare RuntimeError from `async` -- the same
      # reactor precondition every parking seam in this codebase carries.
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

      # Whether this criteria digest carries a standing approval -- the small
      # query a downstream checks before consuming the digest.
      def approved?(digest) = @approved.include?(digest)

      # The guard a generator calls first: return the approved digest, or refuse
      # loudly naming the un-approved one. An edited criteria hashes to a
      # different digest, so a prior approval of the old text never satisfies it.
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

      # Await the answer, or -- on an expired window -- a denial signed by the
      # clock, routed through the same {Answer} the surfaces build so the
      # journal and the return value read identically on either path.
      def await(promise)
        Async::Task.current.with_timeout(@timeout) { promise.await }
      rescue Async::TimeoutError
        Answer.deny(TIMEOUT_SURFACE)
      end

      def question_for(criteria)
        <<~QUESTION
          Approve these acceptance criteria for test generation? Reply approve or deny.

          #{criteria.map { |scenario| render_scenario(scenario) }.join("\n\n")}
        QUESTION
      end

      def render_scenario(scenario)
        clauses = scenario.clauses.map { |clause| "  #{clause.keyword} #{clause.text}" }
        (["Scenario: #{scenario.name}"] + clauses).join("\n")
      end
    end
  end
end
