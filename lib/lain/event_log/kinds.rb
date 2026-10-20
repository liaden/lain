# frozen_string_literal: true

module Lain
  module EventLog
    # The closed vocabularies an event envelope and its payload both carry, and
    # the coercions that make a typo fail identically wherever one is named.
    module Kinds
      KINDS = %i[turn spawn message snapshot].freeze
      ROLES = %w[user assistant].freeze

      # @return [Symbol]
      # @raise [Lain::Error] when `kind` names none of {KINDS}
      def self.normalize_kind(kind)
        symbol = kind.to_s.to_sym
        raise Error, "kind must be one of #{KINDS.join(", ")}, got #{kind.inspect}" unless KINDS.include?(symbol)

        symbol
      end

      # Frozen and deduplicated: `Symbol#to_s` hands back a fresh mutable String,
      # and one unfrozen String is enough to break Ractor shareability downstream.
      #
      # @return [String]
      # @raise [Lain::Error] when `role` names none of {ROLES}
      def self.normalize_role(role)
        string = -role.to_s
        raise Error, "role must be one of #{ROLES.join(", ")}, got #{string.inspect}" unless ROLES.include?(string)

        string
      end
    end
  end
end
