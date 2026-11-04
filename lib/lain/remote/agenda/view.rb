# frozen_string_literal: true

module Lain
  module Remote
    class Agenda
      # What a phone is shown of an agenda item. The phone is a device off this
      # box, so every text field is masked, for the values the board knows and
      # for any region the detector finds. A call whose yes would release a
      # file's sensitive regions stays at the desk, where the release prompt
      # names the file without showing its bytes.
      module View
        KEPT = %i[id asked_at releases].freeze
        # Anything else is shown as its text, masked, so a shape not listed here fails closed.
        PLAIN = [Integer, Float, TrueClass, FalseClass, NilClass, Time].freeze

        # @param item [ParkedCall, GateQuestion, Question]
        # @param secrets [#to_a] the board's known secret values, as {Sensitivity::Secrets::Source} lists them
        # @return [ParkedCall, GateQuestion, Question, nil] the same kind of item, masked and frozen;
        #   nil for a call that stays at the desk
        # @raise [StandardError] whatever the secrets source raises reading its values; a caller must
        #   not rescue it and publish the raw item, which would send the phone every value unmasked
        def self.of(item, secrets:)
          return if item.releases.positive?

          mask = Sensitivity::TextMask.new(secrets: secrets.to_a)
          Ractor.make_shareable(item.with(**item.to_h.except(*KEPT).transform_values { masked(_1, mask) }))
        end

        def self.masked(value, mask)
          case value
          when String then mask.call(value).text
          when Hash then value.to_h { |key, inner| [masked(key, mask), masked(inner, mask)] }
          when Array then value.map { masked(_1, mask) }
          when *PLAIN then value
          else mask.call(value.to_s).text
          end
        end
        private_class_method :masked
      end
    end
  end
end
