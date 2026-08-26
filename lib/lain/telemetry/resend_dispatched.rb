# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A dispatch marker must name the resent request it dispatched.
      class ResendDispatched < Declarative::Carrier
        attribute :digest
        validates :digest, presence: { message: "must name the resent request it dispatched, got nil" }
      end
    end

    # A hand-edited resend was handed to the loop for dispatch: the provenance
    # stamp in the record TYPE, like {RequestResent}'s own, never in `extra`,
    # which rides onto the wire on any rebuild-and-dispatch.
    #
    # Written BEFORE {Agent#run} -- attempt-first, the record-before-dispatch
    # posture {Middleware::JournalRequests} takes -- so a dispatch whose wire
    # call then raised still reads as attempted. `digest` joins onto both the
    # {RequestResent} projection it promotes and the ordinary {RequestSent} the
    # wire path journals, so a marker with no request_sent after it reads as a
    # dispatch that died before the wire.
    ResendDispatched = Data.define(:digest) do
      include Journalable

      # `settle!`, not `check!`: the carrier's frozen copy of `digest` is
      # exactly the `dup.freeze` this constructor spelled out by hand. The
      # keyword stays explicit -- see {StreamStarted} for what `**attrs` costs.
      def initialize(digest:) = super(**Carriers::ResendDispatched.settle!(digest:))
    end
  end
end
