# frozen_string_literal: true

module Lain
  class Mode
    # The delegating slot `/mode` writes and every mode-aware surface reads --
    # the same shape as {Approval::PolicySwitch} and {Context::ModelSwitch},
    # because the seam reality is the same: a {Mode} is a frozen value and the
    # objects that consult one are construction-fixed, so a live mode change has
    # to be a slot the holder ALREADY has, never a setter on the holder.
    # Deliberately MUTABLE coordination state, unlike the value it holds: it
    # exists to be switched.
    #
    # It answers the three reading messages `/mode` and the HUD need; anything
    # else goes through {#current}. Not a stand-in for a Mode and not on its way
    # to becoming one -- a Mode is a `Data`, so its message set is open
    # (`to_h`, `with`, `deconstruct`, `==`), and a switch that chased it would
    # end up a clone that can also be mutated. What this deliberately does NOT
    # do is mutate: `#switch` replaces the reference, and the Mode that was
    # there is the same frozen value it always was -- which is what lets a
    # journal reader, a HUD and a prompt hold their own copies without racing.
    #
    # Every flip lands in the Journal attributed to the surface that made it,
    # including a flip to the mode already in force: a transcript that silently
    # drops a redundant `/mode plan` cannot show that it was asked for. The
    # INITIAL mode is the wiring's choice and already visible in the session's
    # flags -- construction journals nothing.
    #
    # Like {Approval::PolicySwitch}, there is deliberately no lock: a flip is
    # straight-line Ruby with no yield point, and a fiber only interleaves at an
    # IO yield, so the command's write and a render's read can never tear.
    class Switch
      attr_reader :current

      # @param initial [Mode] the mode in force until the first switch
      # @param journal [#record] where each flip lands as evidence
      def initialize(initial, journal:)
        @current = initial
        @journal = journal
      end

      def posture = @current.posture

      def layers = @current.layers

      def describe = @current.describe

      # Swap the live mode, journaling the flip attributed to the surface that
      # made it. Answers the mode now in force, so a caller's confirmation text
      # can name what it got.
      #
      # The record is BUILT before the slot moves, and that order is the whole
      # contract: {Telemetry::Guards::ModeSwitch} refuses a flip it cannot
      # attribute, and assigning first would leave the harness in a mode the
      # Journal never recorded -- the exact failure this switch exists to
      # prevent, reachable only because the guard exists. It is also what makes
      # a non-Mode argument die on `.posture` while the old mode is still in
      # force. Answering `@current` and not `mode` for the same reason: a
      # dropped assignment must not still confirm the new mode to its caller.
      def switch(mode, surface:)
        record = flip(@current, mode, surface)
        @current = mode
        @journal.record(record)
        @current
      end

      private

      # The naming lives here rather than on the record, which is the dumb
      # carrier its two siblings are: this object is the one that knows a Mode.
      def flip(from, to, surface)
        Telemetry::ModeSwitch.new(from: from.posture.name, to: to.posture.name,
                                  from_layers: from.layers.names, to_layers: to.layers.names,
                                  surface:)
      end
    end
  end
end
