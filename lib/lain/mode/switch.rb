# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  class Mode
    # The delegating slot `/mode` writes and every mode-aware surface reads --
    # the same shape as {Approval::PolicySwitch} and {Context::ModelSwitch},
    # because the seam reality is the same: a {Mode} is a frozen value and the
    # objects that consult one are construction-fixed, so a live mode change has
    # to be a slot the holder ALREADY has, never a setter on the holder.
    #
    # Not a stand-in for a Mode and not on its way to becoming one: a Mode is a
    # `Data`, so its message set is open and a switch that chased it would end
    # up a clone that can also be mutated. `#switch` replaces the reference and
    # the Mode that was there stays the frozen value it was, which is what lets
    # a journal reader, a HUD and a prompt hold copies without racing.
    #
    # Every flip lands in the Journal attributed to the surface that made it,
    # including a flip to the mode already in force: a transcript that silently
    # drops a redundant `/mode plan` cannot show that it was asked for. The
    # INITIAL mode is the wiring's choice and already visible in the session's
    # flags -- construction journals nothing.
    #
    # Like {Approval::PolicySwitch}, there is deliberately no lock: a flip is
    # straight-line Ruby with no yield point, and a fiber only interleaves at an
    # IO yield, so the command's write and a render's read cannot tear.
    class Switch
      attr_reader :current

      # @param initial [Mode] the mode in force until the first switch
      # @param journal [#record] where each flip lands as evidence
      def initialize(initial, journal:)
        @current = initial
        @journal = journal
      end

      # The mode's own questions, answered by whichever Mode is in force --
      # the same set {CLI::Switchboard::Layers} delegates through this object.
      delegate :posture, :layers, :describe, to: :@current

      # The record is BUILT before the slot moves, and that order is the whole
      # contract: {Telemetry::Guards::ModeSwitch} refuses a flip it cannot
      # attribute, and assigning first would leave the harness in a mode the
      # Journal never recorded. It is also what makes a non-Mode argument die on
      # `.posture` while the old mode is still in force. Answering `@current`
      # and not `mode` for the same reason: a dropped assignment must not still
      # confirm the new mode to its caller.
      #
      # The `toolset:` keyword names the capability set THIS flip resolves to,
      # so the record can say what the model is shown -- required, with no
      # empty-Toolset default: a default here is exactly how a future caller
      # that forgot to resolve one would go on journaling a false "nothing
      # declared" set instead of failing at the call site. {CLI::Switchboard::
      # BoundSwitch} is the only production caller, and it always hands in the
      # resolution it just computed; a caller driving this object directly as
      # a stand-in for the `mode_switch:` duck (Command::Mode's and
      # StatusFeed's specs both do) has to pass one too, real or a bare
      # `Lain::Toolset.new` named at the call site where a reader can see it
      # was a deliberate choice, not a silent fallback.
      def switch(mode, surface:, toolset:)
        record = flip(@current, mode, surface, toolset)
        @current = mode
        @journal.record(record)
        @current
      end

      private

      # The naming lives here rather than on the record, which is the dumb
      # carrier its two siblings are: this object is the one that knows a Mode.
      def flip(from, to, surface, toolset)
        Telemetry::ModeSwitch.new(from: from.posture.name, to: to.posture.name,
                                  from_layers: from.layers.names, to_layers: to.layers.names,
                                  surface:, toolset_digest: toolset.digest, tool_names: toolset.names)
      end
    end
  end
end
