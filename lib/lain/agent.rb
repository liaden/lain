# frozen_string_literal: true

require_relative "agent/budget"
require_relative "agent/tool_runner"
require_relative "context"
require_relative "effect"
require_relative "error"
require_relative "handler"
require_relative "middleware"
require_relative "response"
require_relative "store"
require_relative "timeline"
require_relative "toolset"
require_relative "usage"
require_relative "workspace"

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
    STATES = %i[awaiting_user awaiting_model awaiting_tools awaiting_approval done failed].freeze

    # Kept for callers that rescue the harness's own halt. See Agent::Budget.
    BudgetExceeded = Budget::Exceeded

    attr_reader :state, :timeline, :toolset, :context, :workspace, :provider,
                :usage, :iterations, :failure_reason, :budget

    def initialize(provider:, toolset:, context:,
                   handler: nil,
                   timeline: nil,
                   workspace: Workspace.empty,
                   budget: Budget.new,
                   model_middleware: Middleware::Stack.new,
                   tool_middleware: Middleware::Stack.new)
      @provider = provider
      @toolset = toolset
      @context = context
      @timeline = timeline || Timeline.empty(store: Store.new)
      @workspace = workspace
      @budget = budget
      @model_middleware = model_middleware
      @tool_runner = build_tool_runner(handler, toolset, tool_middleware)
      reset_run_state
    end

    # Append a user turn and run until the loop settles.
    # @return [Lain::Response] the final assistant response
    def ask(text)
      @timeline = @timeline.commit(role: :user, content: [{ "type" => "text", "text" => text }])
      run
    end

    # Drive the machine from its current Timeline. Separated from {#ask} so a
    # rewound or forked Timeline can be resumed without inventing a user turn.
    def run
      @failure_reason = nil

      loop do
        response = step
        return response if transition(response) == :settled
      end
    end

    def done?
      state == :done
    end

    def failed?
      state == :failed
    end

    # Time travel: the loop can be resumed from any earlier turn, which is what
    # makes speculative branching possible once a grader exists.
    def rewind(count = 1)
      @timeline = @timeline.rewind(count)
      @state = :awaiting_user
      self
    end

    private

    def build_tool_runner(handler, toolset, middleware)
      ToolRunner.new(handler: handler || Handler::Live.new(toolset: toolset), middleware: middleware)
    end

    def reset_run_state
      @state = :awaiting_user
      @usage = Usage.zero
      @iterations = 0
      @failure_reason = nil
    end

    # One turn: bound, count, ask the model, account, record. Extracted from #run
    # so the loop reads as what it is -- iterate until the machine settles.
    def step
      @budget.check_iterations!(@iterations)
      @iterations += 1
      response = call_model
      @usage += response.usage
      @budget.check_tokens!(@usage)
      # Correctness gate 1: commit the FULL content -- text, thinking, AND
      # tool_use blocks. Extracting only the text corrupts the very next turn.
      @timeline = @timeline.commit(role: :assistant, content: response.content)
      response
    end

    # Every stop_reason the wire can carry gets a named destination here, and the
    # `else` catches whatever the enum grows next.
    #
    # @return [Symbol] :settled when the loop is finished, :continue otherwise
    def transition(response)
      case response.stop_reason
      when StopReason::TOOL_USE then perform_tools(response)
      when StopReason::END_TURN, StopReason::STOP_SEQUENCE then finish(:done)
      when StopReason::PAUSE_TURN then resume_paused
      when StopReason::MAX_TOKENS then fail_with("model hit max_tokens before finishing")
      when StopReason::REFUSAL then fail_with("model refused to continue")
      when StopReason::UNKNOWN then fail_with("unrecognized stop_reason from provider")
      else fail_with("unhandled stop_reason #{response.stop_reason.inspect}")
      end
    end

    def finish(state)
      @state = state
      :settled
    end

    def fail_with(reason)
      @failure_reason = reason
      finish(:failed)
    end

    # A paused turn means a server-side tool is mid-flight; the correct response is
    # to send the conversation back unchanged and let the server continue. It
    # counts against max_iterations, so a provider that pauses forever still stops.
    def resume_paused
      @state = :awaiting_model
      :continue
    end

    def call_model
      @state = :awaiting_model
      request = @context.render(timeline: @timeline, toolset: @toolset, workspace: @workspace)
      env = @model_middleware.call({ request: request }) do |inner|
        inner.merge(response: @provider.complete(inner.fetch(:request)))
      end
      env.fetch(:response)
    end

    # Correctness gate 2: every tool_result for one assistant turn goes back in
    # ONE user message. Splitting them across messages silently teaches Claude to
    # stop making parallel tool calls -- a regression with no error attached.
    def perform_tools(response)
      @state = :awaiting_tools
      @timeline = @timeline.commit(role: :user, content: @tool_runner.run(response, context: self))
      :continue
    end
  end
end
