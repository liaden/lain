# frozen_string_literal: true

require "state_machines"
require "active_support/core_ext/module/delegation"

require_relative "agent/accounting"
require_relative "agent/budget"
require_relative "agent/loop_machine"
require_relative "agent/model_caller"
require_relative "agent/tool_runner"
require_relative "agent/transition_listener"

module Lain
  # The loop, written as an explicit state machine rather than a while-loop with
  # a stack of conditionals.
  #
  # The difference is not stylistic. Every `stop_reason` the wire can carry must
  # have somewhere to go, and a `case` with no `else` is how a new enum value --
  # or a forgotten old one like `:stop_sequence` -- becomes a turn that silently
  # does nothing. Here each reason is a named transition and {StopReason::UNKNOWN}
  # is a real destination, so an unrecognized value fails loudly instead of
  # falling through.
  #
  # The Agent owns the loop. Both SDKs offered to own it (`tool_runner`,
  # `Chat#complete`) and both were declined, because the loop is what this project
  # exists to study.
  class Agent
    # The state machine -- states, legal transitions, and the journaling seam --
    # is declared in {LoopMachine} and mixed in here. It also defines {STATES}.
    include LoopMachine

    # Kept for callers that rescue the harness's own halt. See Agent::Budget.
    BudgetExceeded = Budget::Exceeded

    # The diagnostic each failing stop_reason records. A lookup table, not control
    # flow: every StopReason whose event transitions to :failed has an entry.
    FAILURE_REASONS = {
      StopReason::MAX_TOKENS => "model hit max_tokens before finishing",
      StopReason::REFUSAL => "model refused to continue",
      StopReason::UNKNOWN => "unrecognized stop_reason from provider"
    }.freeze
    private_constant :FAILURE_REASONS

    attr_reader :timeline, :toolset, :context, :workspace, :session,
                :iterations, :failure_reason, :budget

    # {Accounting} owns the run's token roll-up; the Agent just exposes it.
    delegate :usage, to: :@accounting

    # The argument list is long because the Agent is the wiring point of the whole
    # harness, and the honest split is three-way, not one big bag: values that are
    # ALREADY their own collaborators ({Budget}, {Accounting} via `journal`); the
    # injected *collaborators* it drives (provider, toolset, context, handler, the
    # three middleware stacks); and the mutable *run state* it seeds ({#seed_run_state}).
    # A `Wiring` value object grouping the collaborators was considered and
    # rejected: it would not remove `seed_run_state` (run state is orthogonal to
    # collaborators) and it would move the public keyword surface -- which the
    # `provider_parity` shared group and the state-machine specs construct against
    # by name -- for no reduction in moving parts. So the seam stays here, named.
    #
    # `handler:` defaults to a live {Effect::Handler::Live} rather than `nil`: a
    # named default resolved once, at the signature, keeps the Null-Object posture
    # (no `handler || ...` nil-tolerance downstream).
    #
    # @param journal [#<<] where per-turn usage records land; the Null channel
    #   by default. Today ONLY {Telemetry::TurnUsage} is written here -- it is not
    #   yet the full run record.
    def initialize(provider:, toolset:, context:,
                   handler: Effect::Handler::Live.new(toolset:),
                   timeline: nil,
                   workspace: Workspace.empty,
                   session: Session.new,
                   budget: Budget.new,
                   journal: Channel::Null.instance,
                   transition_listener: TransitionListener::Null,
                   model_middleware: Middleware::Stack.new,
                   tool_middleware: Middleware::Stack.new,
                   turn_middleware: Middleware::Stack.new)
      super() # state_machines sets the initial state through the super chain.
      @model_caller = ModelCaller.new(provider:, middleware: model_middleware)
      @toolset = toolset
      @context = context
      @timeline = timeline || Timeline.empty(store: Store.new)
      @workspace = workspace
      @budget = budget
      @turn_middleware = turn_middleware
      @tool_runner = ToolRunner.new(handler:, middleware: tool_middleware)
      seed_run_state(transition_listener, journal, session)
    end

    # Append a user turn and run until the loop settles.
    #
    # A new user turn reopens a settled loop, so asking again after `:done` (or
    # `:failed`) continues the conversation rather than raising on `dispatch!`
    # from a terminal state. The guard keeps the very first `ask` transition-free.
    #
    # @return [Lain::Response] the final assistant response
    def ask(text)
      reopen! unless awaiting_user?
      @timeline = @timeline.commit(role: :user, content: [{ "type" => "text", "text" => text }])
      run
    end

    # Drive the machine from its current Timeline. Separated from {#ask} so a
    # rewound or forked Timeline can be resumed without inventing a user turn.
    # The turn phase's env is deliberately minimal: `iteration` is the count of
    # turns already committed (0 for the very first), and `timeline` is the
    # Timeline as of the START of this turn -- the node a future speculative-
    # fork middleware would fork from, before this turn's own commit lands. The
    # block adds `:response`/`:settled` on the way back out, the same in/out
    # shape #call_model uses for `:request`/`:response`. This is the seam for
    # the future budget/iteration-ceiling/interrupt-hook/speculative-fork point
    # -- placing it, not building those features yet.
    def run
      @failure_reason = nil

      loop do
        env = @turn_middleware.call({ iteration: @iterations, timeline: @timeline }) do |inner|
          response = step
          inner.merge(response:, settled: transition(response) == :settled)
        end
        return env.fetch(:response) if env.fetch(:settled)
      end
    end

    # `#done?` and `#failed?` are generated by the state machine, one predicate
    # per state, so they cannot disagree with the declared state set.

    # Time travel: the loop can be resumed from any earlier turn, which is what
    # makes speculative branching possible once a grader exists.
    def rewind(count = 1)
      @timeline = @timeline.rewind(count)
      reopen!
      self
    end

    private

    # The mutable run context, kept apart from #initialize on purpose: the
    # collaborators above are the immutable wiring, and these four are the state
    # a run mutates as it goes -- a fresh Accounting rolling up over the injected
    # journal, the observer the machine announces transitions to, the run's single
    # mutable Session (read-set + reminders, which -- unlike everything the model
    # sees -- never enters the Timeline), and the iteration count. Naming that
    # seam is the point; the machine owns the state ITSELF (initial:
    # :awaiting_user), so it is not seeded here.
    def seed_run_state(transition_listener, journal, session)
      @transition_listener = transition_listener
      @accounting = Accounting.new(journal:)
      @session = session
      @iterations = 0
    end

    # One turn: bound, count, ask the model, account, record. Extracted from #run
    # so the loop reads as what it is -- iterate until the machine settles.
    def step
      @budget.check_iterations!(@iterations)
      @iterations += 1
      response = call_model
      # Correctness gate 1: commit the FULL content -- text, thinking, AND
      # tool_use blocks. Extracting only the text corrupts the very next turn.
      @timeline = @timeline.commit(role: :assistant, content: response.content)
      # Commit BEFORE the token check: a turn that busts the ceiling was still
      # paid for, so it stays in the record -- Timeline and Journal both --
      # rather than vanishing with the raise.
      @budget.check_tokens!(@accounting.observe(response, digest: @timeline.head_digest))
      response
    end

    # Fire the machine event named for the (already-normalized) stop_reason and
    # let the machine, not a `case`, decide the resulting state. `StopReason.normalize`
    # (see response.rb) has closed the wire's open enum to StopReason::ALL before
    # we get here, and {LoopMachine} declares one event per member, so the send
    # always names a real event -- a genuinely unrecognized wire value is already
    # :unknown, which fails to :failed. The only loud arm left is structural:
    # firing a reason's event from an illegal state raises
    # StateMachines::InvalidTransition (gate 6). Coupling the event names to
    # StopReason's vocabulary is deliberate; the totality spec pins it.
    #
    # @return [Symbol] :settled when the loop is finished, :continue otherwise
    def transition(response)
      __send__(:"#{response.stop_reason}!")
      settle(response)
    end

    # Run-context side effects keyed off the state the machine just reached -- the
    # machine owns the state, the Agent owns the mutable run context. A paused turn
    # needs nothing: it stays in :awaiting_model and re-dispatches, counting against
    # max_iterations so a provider that pauses forever still stops.
    def settle(response)
      perform_tools(response) if awaiting_tools?
      @failure_reason = FAILURE_REASONS[response.stop_reason] if failed?
      settled? ? :settled : :continue
    end

    def settled? = done? || failed?

    def call_model
      dispatch!
      # Compose the sent-not-stored Workspace with the session's live reminders per
      # render: same-args-same-bytes still holds, but the args now vary with session
      # state. Session stays ignorant of Workspace; Workspace stays frozen.
      request = @context.render(timeline: @timeline, toolset: @toolset, workspace: @workspace.with(*@session.reminders))
      @model_caller.call(request)
    end

    # Correctness gate 2: every tool_result for one assistant turn goes back in
    # ONE user message. Splitting them across messages silently teaches Claude to
    # stop making parallel tool calls -- a regression with no error attached. The
    # `tool_use` event has already fired (in #transition); this only commits.
    def perform_tools(response)
      @timeline = @timeline.commit(role: :user, content: @tool_runner.run(response, context: @session))
    end
  end
end
