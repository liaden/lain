# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module Lain
  module Approval
    # What a human's answer, a silence default or a gate decision can be:
    # approve, hold or deny, each with an optional note. A closed sum, so a
    # stray `true` or symbol fails loudly instead of answering in silence.
    #
    # `network` is the human's choice to let an approved call that reads secrets
    # reach the network, so it runs unconfined; only an approval can carry it.
    # `secrets` is the human's choice to let it read the project's masked files,
    # still contained; the 2 never combine, since secrets are read only where
    # the network is closed.
    module Verdict
      Base = Data.define(:note, :network, :secrets) do
        def initialize(note: nil, network: false, secrets: false)
          raise ArgumentError, "only an approval can choose network" if network == true && !approved?
          raise ArgumentError, "only an approval can choose secrets" if secrets == true && !approved?
          if network == true && secrets == true
            raise ArgumentError,
                  "an approval cannot choose both secrets and network"
          end

          super(note: clean(note), network: network == true, secrets: secrets == true)
        end

        def approved? = false
        def held? = false
        def denied? = false
        def network? = network
        def secrets? = secrets

        private

        def clean(note)
          unless note.nil? || note.is_a?(String)
            raise ArgumentError,
                  "note must be a String or nil, got #{note.inspect}"
          end

          note.presence&.dup&.freeze
        end
      end
      private_constant :Base

      Approve = Class.new(Base) { def approved? = true }
      Hold = Class.new(Base) { def held? = true }
      Deny = Class.new(Base) { def denied? = true }

      VARIANTS = [Approve, Hold, Deny].freeze

      # @param value [Approve, Hold, Deny]
      # @return [Approve, Hold, Deny] the same value
      # @raise [ArgumentError] for anything that is not one of the 3 variants
      def self.coerce(value)
        return value if VARIANTS.any? { value.is_a?(_1) }

        raise ArgumentError, "not a verdict: #{value.inspect}; expected Approve, Hold or Deny"
      end
    end
  end
end
