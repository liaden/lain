# frozen_string_literal: true

module Lain
  module Telemetry
    # Something declared it `requires` a capability the Provider does not have,
    # and the run's policy chose to DEGRADE rather than raise: the tactic
    # silently became a no-op. "Silently" is the whole danger -- a
    # cross-provider A/B where half the context tactics no-oped on one arm is a
    # lie -- so the degradation is made LOUD here, and `Compare` refuses to
    # compare two runs whose degraded sets differ.
    #
    # `requirer` and `provider` are NAMES rather than the objects, so the record
    # serializes to one self-describing NDJSON line.
    #
    # `requirer` names whatever was handed to {Capability::Policy#resolve},
    # which in a real chat is the run's whole {Context} -- so a live record
    # reads `"Lain::Context"`, never the combinator that wanted the capability.
    # That is the best value available: `Context#requires` is a UNION over its
    # pipeline while `#resolve` folds over one requirer, so the combinator is
    # not recoverable where the record is built. A reader wanting to know WHICH
    # stage no-oped reads the pipeline the session header pins.
    CapabilityDegraded = Data.define(:capability, :requirer, :provider) do
      include Journalable

      def initialize(capability:, requirer:, provider:)
        super(capability:, requirer: requirer.dup.freeze, provider: provider.dup.freeze)
      end
    end
  end
end
