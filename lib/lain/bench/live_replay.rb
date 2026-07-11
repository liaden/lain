# frozen_string_literal: true

require_relative "../agent"
require_relative "../channel"
require_relative "../price_book"
require_relative "../store"
require_relative "../timeline"
require_relative "../usage"
require_relative "../workspace"

module Lain
  module Bench
    # Re-run a recorded task against a real provider and record the fresh
    # Usage/Journal. Where {DryReplay} re-renders offline and byte-diffs, this
    # actually spends tokens -- it is how you measure whether a strategy that
    # LOOKS better on the recorded bytes is actually cheaper or better once the
    # model responds to it.
    #
    # SEQUENTIAL by construction: prompts are replayed one after another. A
    # concurrent `n:` sweep is deliberately deferred to the M5 concurrency
    # decision (fibers vs. threads) rather than guessed at here.
    #
    # Provider-agnostic: it drives whatever {Provider} it is handed, so the same
    # object runs against the real API under `:live` and against
    # {Provider::Mock} in an offline spec. Only the injected provider decides
    # whether the network is touched.
    class LiveReplay
      # The outcome of a fresh run: the new Timeline, the accumulated fresh
      # Usage, and the ordered final Responses (one per prompt).
      Result = Data.define(:timeline, :usage, :responses)

      # The human asks in a recorded Timeline, in order. A `tool_result` user
      # turn carries no `text` block, so it is naturally skipped -- what remains
      # is exactly the sequence a person typed, which is the task to re-run.
      #
      # @param timeline [Lain::Timeline]
      # @return [Array<String>]
      def self.prompts_from(timeline)
        timeline.to_a.select { |turn| turn.role == "user" }.filter_map { |turn| ask_text(turn) }
      end

      def self.ask_text(turn)
        block = turn.content.find { |content_block| content_block["type"] == "text" }
        block && block["text"]
      end

      # @param provider [Lain::Provider] real under :live, a Mock offline
      # @param journal [#<<] where fresh usage records are written; a Null
      #   channel by default, so no caller guards `if journal`
      # @param price_book [Lain::PriceBook] prices the fresh total usage
      def initialize(provider:, toolset:, context:, journal: Channel::Null.instance,
                     workspace: Workspace.empty, price_book: PriceBook.default)
        @provider = provider
        @toolset = toolset
        @context = context
        @journal = journal
        @workspace = workspace
        @price_book = price_book
      end

      # Re-run each prompt sequentially against a FRESH Agent, journaling one
      # turn record per prompt and a priced summary at the end.
      #
      # @param prompts [Array<String>] the recorded asks (see {.prompts_from})
      # @return [Result]
      def replay(prompts)
        agent = build_agent
        responses = Array(prompts).map { |prompt| ask_and_record(agent, prompt) }
        record_summary(agent.usage, Array(prompts).size)
        Result.new(timeline: agent.timeline, usage: agent.usage, responses: responses)
      end

      private

      # The Agent shares this replay's journal, so its per-model-call turn_usage
      # records interleave with the live_replay_turn records -- one stream, one
      # session record (B2 depends on exactly this wiring).
      def build_agent
        Agent.new(provider: @provider, toolset: @toolset, context: @context,
                  timeline: Timeline.empty(store: Store.new), workspace: @workspace,
                  journal: @journal)
      end

      def ask_and_record(agent, prompt)
        response = agent.ask(prompt)
        @journal << {
          "type" => "live_replay_turn",
          "prompt" => prompt,
          "model" => response.model,
          "stop_reason" => response.stop_reason.to_s,
          "usage" => response.usage.to_h
        }
        response
      end

      def record_summary(usage, prompt_count)
        @journal << {
          "type" => "live_replay",
          "model" => @context.model,
          "prompts" => prompt_count,
          "usage" => usage.to_h,
          "cost" => @price_book.cost(@context.model, usage).to_s("F")
        }
      end
    end
  end
end
