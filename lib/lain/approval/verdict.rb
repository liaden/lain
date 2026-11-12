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
    module Verdict
      Base = Data.define(:note, :network) do
        def initialize(note: nil, network: false)
          raise ArgumentError, "only an approval can choose network" if network == true && !approved?

          super(note: clean(note), network: network == true)
        end

        def approved? = false
        def held? = false
        def denied? = false
        def network? = network

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
