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
    # Every flip that MOVES something lands in the Journal attributed to the
    # surface that made it. A flip to the mode already in force writes nothing:
    # the session did not change, and a record of it would read as a change to
    # every reader that folds these. The INITIAL mode is the wiring's choice and
    # already visible in the session's flags -- construction journals nothing.
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

      # The mode's own questions, answered by whichever Mode is in force.
      delegate :scope, :approval, :layers, :describe, to: :@current

      # The durable record COMMITS the flip, and that is the whole contract. A
      # journal that refuses the record -- a carrier that cannot attribute it,
      # a closed file -- leaves the old mode in force, so the harness is never
      # in a mode the session file does not name. A live view that fails after
      # the record landed ({CLI::JournalTee::Recorded}) cannot undo it: the
      # slot moves and the failure is raised afterwards, so a retry is a no-op
      # and the file's flips still chain.
      def switch(mode, surface:)
        return @current if mode == @current

        failure = ::Lain::CLI::JournalTee.landed { @journal.record(flip(@current, mode, surface)) }
        @current = mode
        raise failure if failure

        @current
      end

      private

      # The naming lives here rather than on the record, which is the dumb
      # carrier its two siblings are: this object is the one that knows a Mode.
      def flip(from, to, surface)
        Telemetry::ModeSwitch.new(from_scope: from.scope.name, to_scope: to.scope.name,
                                  from_approval: from.approval.name, to_approval: to.approval.name,
                                  from_layers: from.layers.names, to_layers: to.layers.names, surface:)
      end
    end
  end
end
