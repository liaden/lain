# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Every field but `attempt` is nil on a line journaled before it was recorded.
      class ProviderRetry < Declarative::Carrier
        attribute :attempt
        attribute :will_retry_in
        attribute :status
        attribute :reason
        attribute :path
      end
    end

    # A transport-level retry, made visible. A silent retry hides real spend --
    # on a bench whose headline metric is token cost, a retried request can bill
    # more than the reported Usage ever shows. `attempt` is 1 for the first
    # retry; `will_retry_in` is the backoff seconds, nil once retries are
    # exhausted; `reason` names what triggered it (an exception class name);
    # `path` is where the retry happened: the request path for a provider's
    # transport retry, or a layer name such as "agent" for a retry above the
    # transport; nil on a line journaled before it was recorded.
    ProviderRetry = Data.define(:attempt, :will_retry_in, :status, :reason, :path) do
      include Journalable

      def initialize(attempt:, will_retry_in: nil, status: nil, reason: nil, path: nil)
        super(**Carriers::ProviderRetry.settle!(attempt:, will_retry_in:, status:, reason:, path:))
      end
    end
  end
end
