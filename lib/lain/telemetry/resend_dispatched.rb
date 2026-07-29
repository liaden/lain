# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # A dispatch marker must name the resent request it dispatched.
      class ResendDispatched < Guard
        attribute :digest
        validates :digest, presence: { message: "must name the resent request it dispatched, got nil" }
      end
    end

    # A hand-edited resend was handed to the loop for dispatch: T18's
    # provenance stamp, in the record TYPE like {RequestResent}'s own (never in
    # `extra`, which rides onto the wire on any rebuild-and-dispatch). Written
    # by {CLI::ResendBridge}, never by the frontend (the projection half of a
    # resend already journals as {RequestResent}; this marker is what says the
    # OTHER half happened), BETWEEN staging the {Agent::RequestOverride} slot
    # and {Agent#run} -- attempt-first, the same record-before-dispatch posture
    # {Middleware::JournalRequests} takes -- so a dispatch whose wire call then
    # raised still reads as attempted. `digest` is the edited request's content
    # address, the join key onto BOTH the {RequestResent} projection it
    # promotes and the ordinary {RequestSent} the wire path journals when the
    # loop actually sends it; a marker with no request_sent after it reads as
    # a dispatch that died before the wire, exactly the way a request_sent
    # with no turn_usage reads as a wire call that died before payment.
    ResendDispatched = Data.define(:digest) do
      include Journalable

      def initialize(digest:)
        Guards::ResendDispatched.check!(digest:)

        super(digest: digest.dup.freeze)
      end
    end
  end
end
