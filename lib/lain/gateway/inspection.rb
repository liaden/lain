# frozen_string_literal: true

require "json"

module Lain
  module Gateway
    # What the gateway checks in a request body before the human is shown it.
    # A refusal never names the value it found, because the reason is shown
    # and logged.
    class Inspection
      # @!attribute [r] refuse
      #   @return [Boolean] whether the body must not be forwarded
      # @!attribute [r] reason
      #   @return [String, nil] why, never quoting a secret
      # @!attribute [r] flagged
      #   @return [Array<String>] the detector's reasons for the shaped regions the
      #     body holds, shown to the human without refusing, because a body that
      #     asks about a credential file can quote its shape
      Verdict = Data.define(:refuse, :reason, :flagged)

      # A secret-oracle question is a few KB, and the region scan grows with the body.
      MAX_BYTES = 2 * 1024 * 1024
      TOO_LARGE = "the body is over #{MAX_BYTES} bytes".freeze
      NOT_JSON = "the body is not a JSON object"
      # Ollama streams when `stream` is absent, so only an explicit false passes.
      STREAMING = 'non-streaming only: the body must set "stream": false'
      KNOWN_SECRET = "the body carries a known secret (%<count>d value(s))"

      # @param literals [#to_a] the secret values of the gateway's own process
      def initialize(literals:)
        @literals = literals
      end

      # @param body [String] the request body as the client sent it
      # @return [Verdict]
      def call(body)
        return refused(TOO_LARGE) if body.bytesize > MAX_BYTES

        parsed = parse(body)
        return refused(NOT_JSON) unless parsed.is_a?(Hash)
        return refused(STREAMING) unless non_streaming?(parsed)

        text = strings(parsed).join("\0").b
        found = known_secrets(body.b, text)
        return refused(format(KNOWN_SECRET, count: found.size)) if found.any?

        Verdict.new(refuse: false, reason: nil, flagged: flagged(text))
      end

      private

      def parse(body)
        JSON.parse(body, allow_duplicate_key: false)
      rescue JSON::ParserError, EncodingError
        nil
      end

      def refused(reason) = Verdict.new(refuse: true, reason:, flagged: [].freeze)

      # Ollama decodes with Go, which matches a key case-insensitively and folds
      # `ſ` to `s`, so a `Stream` key beside `stream` would decide what it does.
      def non_streaming?(parsed)
        spellings = parsed.keys.select { _1.scrub.downcase(:fold) == "stream" }
        spellings == ["stream"] && parsed["stream"] == false
      end

      # The raw bytes hold a secret written as a number, which no decoded
      # string does; the decoded strings hold one JSON escaped as `\u` or `\"`.
      def known_secrets(raw, text)
        @literals.to_a.select { |value| spellings(value.b).any? { raw.include?(_1) || text.include?(_1) } }
      end

      def spellings(value)
        hex = value.unpack1("H*")
        [value, [value].pack("m0").sub(/=+\z/, ""), hex, hex.upcase]
      end

      def strings(value)
        case value
        when Hash then value.flat_map { |key, inner| [key, *strings(inner)] }
        when Array then value.flat_map { strings(_1) }
        when String then [value]
        else []
        end
      end

      def flagged(text) = Sensitivity::Regions.detect(text).map(&:reason).uniq.freeze
    end
  end
end
