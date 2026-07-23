# frozen_string_literal: true

module Lain
  class Context
    # The delegating model slot `/model` writes and {Context#render} reads at
    # render time -- the same delegating-value pattern as
    # {Approval::PolicySwitch}, because the seam reality is the same: Agent's
    # @context is construction-fixed and call_model always renders from it, so
    # a live model change has to be a slot INSIDE the Context, never a setter
    # on Agent. Deliberately MUTABLE coordination state, unlike the frozen
    # value objects: it exists to be switched.
    #
    # This is a deliberate, journaled impurity in an otherwise pure #render --
    # with an obvious cache consequence the operator already chose: a model
    # change breaks the cached prefix anyway. A String-modeled Context is
    # untouched, and render stays a pure function of (inputs, slot state).
    #
    # The id is stored VERBATIM: an unknown model must fail loudly at dispatch
    # (the provider's own refusal), never fall back to a default in silence.
    # A Context holding this slot is no longer Ractor-shareable -- the
    # deliberate price of the one mutable reference, paid only by the main
    # session context that opts in. Like Queue's @parked there is no lock: a
    # switch is straight-line Ruby with no yield point, so the command's write
    # and a render's read can never tear.
    class ModelSwitch
      attr_reader :current

      # @param initial [#to_s] the model in force until the first switch
      # @param journal [#record] where each change lands as evidence
      def initialize(initial, journal:)
        @current = -initial.to_s
        @journal = journal
      end

      def to_s = current

      # Swap the model the NEXT render reads, journaling the change attributed
      # to the surface that made it. Answers the model now in force.
      def switch(model, surface:)
        from = @current
        @current = -model.to_s
        @journal.record(Telemetry::ModelSwitch.new(from:, to: @current, surface:))
        @current
      end
    end
  end
end
