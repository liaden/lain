# frozen_string_literal: true

module Lain
  module Telemetry
    # A hosted endpoint's admission width lowered to the limit its server named
    # on a concurrency 429. The server sends its rate-limit headers only on a
    # refusal, so this record is the one place a session's real plan limit is
    # written down. The header values are carried as sent, nil where absent, so
    # a reader can tell a full server queue from a busy plan.
    #
    # Written to the journal by {Provider::Ollama::RetryTap}, once per refusal
    # that moved the width; a refusal reporting a limit at or above the width
    # writes nothing.
    AdmissionNarrowed = Data.define(:endpoint, :from_width, :to_width, :max_concurrent, :active, :queue_limit,
                                    :queued) do
      include Journalable

      def initialize(endpoint:, from_width:, to_width:, max_concurrent:, active:, queue_limit:, queued:)
        super(endpoint: endpoint.to_s.dup.freeze, from_width:, to_width:, max_concurrent:, active:, queue_limit:,
              queued:)
      end
    end
  end
end
