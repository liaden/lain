# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A cancellation record must name the assistant turn whose calls were
      # cancelled and at least one cancelled call. The second is not pedantry:
      # a turn torn AFTER every tool returned commits its real results and is
      # not a cancellation at all, so a record with an empty `cancelled` would
      # be the one shape that reads as a cancellation while describing none.
      # The two optional lists are declared with their defaults so `settle!`
      # can hand the record a fresh, deeply frozen Array per construction --
      # a bare `default: []` would share ONE Array across every record that
      # omitted it, which is the classic Ruby default-argument hazard the
      # lambda closes.
      class ToolCancelled < Declarative::Carrier
        attribute :head
        attribute :cancelled
        attribute :running, default: -> { [] }
        attribute :completed, default: -> { [] }
        validates :head, presence: { message: "must name the assistant turn whose calls were cancelled, got nil" }
        validates :cancelled, presence: { message: "must name at least one cancelled call" }
      end
    end

    # A tool-calling turn the run was interrupted in the middle of, written by
    # {Agent#perform_tools} at the tear -- inside the same `defer_stop` region
    # as the Timeline commit it describes, so a record can never survive a
    # commit that did not happen, or vice versa.
    #
    # `head` is the ASSISTANT turn that made the calls, read before the
    # cancellation turn is committed: it is the join key onto the `tool_use`
    # blocks a reader wants to look at, and onto the {RunInterrupted} record
    # the closer writes moments later for the same tear.
    #
    # The three id lists partition the turn's calls, and the partition IS the
    # record's content: `completed` kept the tool's own output, `running` were
    # dispatched and had not returned, `cancelled` is every call with no output
    # (`running` is its subset). The split matters because it is the one thing
    # a load-side repair can never reconstruct -- from a journal alone, "the
    # tool never ran" and "the tool ran and its effects are on disk" are
    # indistinguishable, and only the process that was present at the tear
    # knows which.
    #
    # A turn whose tools all returned emits NOTHING, the same doctrine
    # {ProviderWait} keeps: the presence of a record is itself the signal, and
    # an uninterrupted session journals none of these at all.
    ToolCancelled = Data.define(:head, :cancelled, :running, :completed) do
      include Journalable

      # The defaults and the deep freeze both live on the carrier now: `settle!`
      # rebuilds each id list as a frozen Array of frozen Strings, which is what
      # the private `freeze_ids` did and what keeps the record `Ractor.shareable?`
      # -- an Array of Strings is only as immutable as its elements.
      #
      # `head`/`cancelled` are named so they stay REQUIRED; the two optional
      # lists ride in `**optional` so that omitting them reaches the carrier's
      # `default: -> { [] }` rather than being re-defaulted here. Naming them
      # with `running: []` would put the default back in two places at once.
      def initialize(head:, cancelled:, **optional)
        super(**Carriers::ToolCancelled.settle!(head:, cancelled:, **optional))
      end
    end
  end
end
