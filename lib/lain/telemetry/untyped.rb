# frozen_string_literal: true

module Lain
  module Telemetry
    # A journal line no record claims, carried whole: the session's own grammars (`turn`,
    # `session`, `rewound`, ...) and anything torn or foreign read back as this, never dropped.
    #
    # The member is `fields`, not `hash`: a member named `hash` replaces `Object#hash`, and the
    # value then raises TypeError as a Hash key or under `uniq`.
    #
    # @!attribute [r] fields
    #   @return [Hash{String=>Object}] the line without the Journal's envelope, deeply frozen
    Untyped = Data.define(:fields) do
      def initialize(fields:) = super(fields: Declarative::Carrier::Copy.new("fields").of(fields))

      # @return [String]
      # @raise [KeyError] for a line that names no type
      def type = fields.fetch("type")

      # @param key [String]
      # @return [Object, nil]
      def [](key) = fields[key]
    end
  end
end
