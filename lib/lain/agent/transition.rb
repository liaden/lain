# frozen_string_literal: true

module Lain
  class Agent
    # One reply's move through the loop: the machine event its stop reason
    # names, the tool round a `tool_use` asks for, and whether the run settles.
    #
    # The event is fired by name rather than chosen by a `case`. {Response} has
    # closed the wire's open enum to `StopReason::ALL` before this runs and
    # {LoopMachine} declares one event per member, so the send always names a
    # real event, and an unrecognized wire value arrives as `:unknown`, which
    # fails. The only loud arm left is structural: firing from an illegal state
    # raises `StateMachines::InvalidTransition`. A totality spec pins the
    # coupling of event names to the machine vocabulary.
    #
    # A paused turn needs nothing: it stays in `:awaiting_model` and
    # re-dispatches, counting against the iteration ceiling, so a provider that
    # pauses forever still stops.
    class Transition
      # @param machine [Agent] the loop whose events are fired
      # @param deliveries [ToolDelivery] where a tool round's results land
      def initialize(machine:, deliveries:)
        @machine = machine
        @deliveries = deliveries
      end

      # @param response [Response] the reply just committed
      # @param timeline [Ext::Timeline] the timeline as of that commit
      # @param session [Session] the tools' context
      # @yieldparam committed [Ext::Timeline] the commit a tool round produced
      # @return [Response, nil] what the run settles with, or nil to go on
      def call(response, timeline:, session:, &commit)
        @machine.public_send(:"#{response.stop_reason}!")
        held = @deliveries.perform(response, timeline:, session:, &commit) if @machine.awaiting_tools?
        return settled_held(response, held) if held

        response if @machine.done? || @machine.failed?
      end

      private

      # The held text rides after the model's own, so whoever reads the
      # answer's text -- a print-mode run, a parent reading a child -- is told
      # what the tool said. It is its own last block, which {Response#held_text}
      # reads back.
      def settled_held(response, held)
        @machine.held!
        gap = response.text.empty? ? [] : [{ "type" => "text", "text" => "\n\n" }]
        content = [*response.content, *gap, { "type" => "text", "text" => held }]
        response.with(stop_reason: ::Lain::StopReason::HELD, content:)
      end
    end
  end
end
