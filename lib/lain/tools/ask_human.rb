# frozen_string_literal: true

module Lain
  module Tools
    # Puts a question to the human and returns their answer -- the human as a
    # capability-gated, high-latency agent whose replies are just events in the
    # log (OM-4). The exchange is two :message events in the shared Store: an
    # outbound **Q** to the human's inbox (`to: "human"`) and, when the human
    # answers, an inbound **A** back to the asker. Both are replayable and
    # neither renders into any prompt chain (`render_parent` nil, the Lineage
    # idiom); the model receives the answer through this tool's ordinary
    # `tool_result` (gate 2), so the human's reply reaches the loop the same way
    # any tool's does.
    #
    # == A promise, not a blocking read
    #
    # {#ask} emits Q and hands back a pending {Lain::Promise} WITHOUT awaiting --
    # emitting does not block. Awaiting the promise parks the fiber, not the
    # reactor, so concurrent work proceeds while the answer is outstanding. The
    # tool-dispatch path {#perform} is the SYNC GATE: it emits then awaits, so a
    # single mechanism yields both modes -- await immediately and it is an
    # ordinary synchronous question-answer; await later (a future speculative
    # branch) and the agent continues meanwhile. There is no separate sync API.
    #
    # == The reply seam
    #
    # {#reply} is what the frontend's reply-path calls with the human's typed
    # answer: it writes A to the Store AND resolves the pending promise. Pushing
    # the message is the whole of what the frontend does -- the promise, the
    # process-local coordination that carries the value to the parked fiber, is
    # this tool's own business, never something the frontend reaches into.
    #
    # == Injection, and the single-question invariant
    #
    # `parent:` is the live parent-Timeline handle (a Timeline or a `-> Timeline`
    # thunk, since the toolset is built before the Agent) -- the shared Store
    # rides on it (`parent.store`), and the asker's identity is the parent
    # chain's correlation, exactly as Subagent's Lineage derives it. The tool
    # holds the one outstanding promise on an ivar: an instance belongs to one
    # agent's toolset, and a synchronous tool dispatch has no interleaving
    # writer, so there is at most one question awaiting a reply at a time (the
    # OM-2-only statefulness Subagent documents). An actor mode that asks
    # concurrently must carry its promises on events, not on this ivar.
    class AskHuman < Tool
      HUMAN = "human"

      class NoPendingQuestion < Error; end

      # The model-facing input: just the question. The human, the addressing,
      # and the promise are the mechanism, not something the model negotiates.
      class Input < Tool::Input
        field :question, :string, required: true,
                                  description: "A question to put to the human operator; " \
                                               "their answer comes back as this tool's result."
      end

      input_model Input

      # The most recent exchange, exposed for observability (the study bench reads
      # the orchestration events): the last Q and A :message events. `nil` until
      # the corresponding half happens.
      attr_reader :name, :last_question, :last_answer

      def initialize(parent:, name: "ask_human")
        super()
        @parent = parent
        @name = name
        @chain_writer = Event::ChainWriter.new
      end

      def description
        "Asks the human operator `question` and returns their answer as the " \
          "result. Use it when a decision needs a human -- a missing detail, a " \
          "judgement call, an approval -- rather than guessing. The call waits " \
          "for the reply."
      end

      # The async-continue seam: emit Q to the human's inbox and return a pending
      # promise. Does not await -- the caller decides when (or whether) to block
      # on the answer.
      #
      # @return [Lain::Promise] resolved by {#reply} with the human's answer
      def ask(question)
        parent = parent_timeline
        @last_question = write_message(parent, from: identity(parent), to: HUMAN,
                                               body: { "question" => question },
                                               causal_parents: [parent.head_digest].compact)
        @pending = Promise.new
      end

      # Deliver the human's answer: write A back to the asker AND resolve the
      # pending promise. The frontend reply-path calls this with nothing but the
      # answer string.
      #
      # Both guards run BEFORE the Store write: the Store is the append-only
      # record, so a reply this method is about to refuse must leave no A event
      # behind -- the refusal happens or the event lands, never both.
      #
      # @return [Lain::Event] the A :message event
      def reply(answer)
        raise NoPendingQuestion, "no question is awaiting a reply" if @pending.nil?
        raise Promise::AlreadyResolved, "the pending question was already answered" if @pending.resolved?

        parent = parent_timeline
        @last_answer = write_message(parent, from: HUMAN, to: identity(parent),
                                             body: { "answer" => answer },
                                             causal_parents: [@last_question.digest])
        @pending.resolve(answer)
        @last_answer
      end

      # Whether a question is emitted and still unanswered -- what a frontend
      # polls to decide it must prompt the human.
      def pending?
        !@pending.nil? && !@pending.resolved?
      end

      protected

      # The sync gate: emit the question, then await the answer and return it as
      # the tool_result. Awaiting parks this fiber until {#reply} resolves the
      # promise; a reply already in hand returns at once.
      def perform(input, _invocation)
        promise = ask(input.question)
        Tool::Result.ok(promise.await)
      end

      private

      # A :message event in the shared Store, delegated to the shared
      # {Event::ChainWriter}: a :message Payload out of line, an envelope
      # carrying the attribution and the causal edges, correlated to the
      # asker's chain. Causal-only -- no `render_parent` -- so it never
      # enters a render chain.
      def write_message(parent, from:, to:, body:, causal_parents:)
        @chain_writer.put(parent, kind: :message, from:, to:, causal_parents:, body:)
      end

      # A chain is named by its root event digest (the pinned correlation
      # convention), so the asker is addressable without new id machinery --
      # the same derivation Subagent's Lineage uses.
      def identity(timeline) = Event::ChainWriter.correlation_of(timeline)

      # The parent Timeline, live: a Timeline passes through, a thunk is called
      # (the toolset is built before the Agent, so the exe hands a
      # `-> { agent.timeline }` that reads the head at the instant of the call).
      def parent_timeline
        @parent.respond_to?(:call) ? @parent.call : @parent
      end
    end
  end
end

# Subclasses reopen AskHuman, so they load after the class body -- this file
# is the ask_human subtree's index (see CLAUDE.md, Requires).
require_relative "ask_human/notifying"
