# frozen_string_literal: true

module Lain
  module Telemetry
    # A transport-level retry, made visible. A silent retry hides real spend --
    # on a bench whose headline metric is token cost, a retried request can bill
    # more than the reported Usage ever shows. `attempt` is 1 for the first
    # retry; `will_retry_in` is the backoff seconds, nil once retries are
    # exhausted; `reason` names what triggered it (an exception class name);
    # `path` is the request path the retry was for, nil on a line journaled
    # before it was recorded.
    ProviderRetry = Data.define(:attempt, :will_retry_in, :status, :reason, :path) do
      include Journalable

      def initialize(attempt:, will_retry_in: nil, status: nil, reason: nil, path: nil)
        super(attempt:, will_retry_in:, status:, reason: reason&.dup&.freeze, path: path&.dup&.freeze)
      end
    end
  end
end
