# frozen_string_literal: true

require "digest"
require "json"

require_relative "error"

module Lain
  # Deterministic serialization, serving two invariants with one function.
  #
  # 1. Turn identity. A Turn's hash is the SHA-256 of its canonical form, so two
  #    turns that mean the same thing on the wire must serialize to the same bytes.
  # 2. Prompt-cache stability. Anthropic's cache is a prefix match over the encoded
  #    request; a Hash that iterates in insertion order across two Toolset
  #    constructions would silently invalidate the cache with no error anywhere.
  #
  # Both requirements are the same requirement: byte-identical output for
  # semantically identical input. Keys are sorted; array order is preserved,
  # because array order is meaning.
  #
  # The canonical form names the *wire* representation. Symbols and Strings
  # therefore collapse together, since both become JSON strings: `{a: 1}` and
  # `{"a" => 1}` hash identically. That is correct rather than lossy — they are
  # the same message. A Hash containing *both* `:a` and `"a"` is genuinely
  # ambiguous and raises instead of silently dropping one.
  module Canonical
    DIGEST_ALGORITHM = "sha256"

    class UnsupportedType < Error; end
    class NonFiniteFloat < Error; end
    class AmbiguousKey < Error; end

    class << self
      # The wire form of +value+: JSON-native types only, String keys, objects
      # sorted, everything deeply frozen. Callers that need to *store* content
      # (see Lain::Turn) keep this rather than the original, so what is hashed
      # and what is retained cannot drift apart.
      def normalize(value)
        case value
        when nil, true, false, Integer then value
        when Float then finite(value)
        when String, Symbol then -utf8(value.to_s)
        when Array then value.map { |element| normalize(element) }.freeze
        when Hash then normalize_hash(value)
        else raise UnsupportedType, "cannot canonicalize #{value.class}"
        end
      end

      # Compact JSON with recursively sorted object keys.
      def dump(value)
        JSON.generate(normalize(value))
      end

      # Content address of +value+, e.g. "sha256:9f86d0...". The prefix keeps the
      # algorithm explicit so a future migration is not a silent reinterpretation.
      def digest(value)
        "#{DIGEST_ALGORITHM}:#{Digest::SHA256.hexdigest(dump(value))}"
      end

      private

      def normalize_hash(hash)
        normalized = hash.each_with_object({}) do |(key, value), acc|
          string_key = normalize_key(key)
          raise AmbiguousKey, "#{string_key.inspect} is both a String and a Symbol key" if acc.key?(string_key)

          acc[string_key] = normalize(value)
        end
        normalized.sort_by { |key, _| key }.to_h.freeze
      end

      def normalize_key(key)
        case key
        when String, Symbol then -utf8(key.to_s)
        else raise UnsupportedType, "hash keys must be String or Symbol, got #{key.class}"
        end
      end

      # JSON has no representation for NaN or Infinity, and a hash computed over
      # one would not round-trip.
      def finite(float)
        raise NonFiniteFloat, "cannot canonicalize #{float}" unless float.finite?

        float
      end

      # Encoding must be pinned or the same characters could hash to different
      # bytes. Note that encoding to UTF-8 from UTF-8 is a no-op and does *not*
      # validate, so invalid bytes are caught by the explicit check rather than
      # by #encode raising.
      def utf8(string)
        encoded = string.encoding == Encoding::UTF_8 ? string : string.encode(Encoding::UTF_8)
        raise UnsupportedType, "string is not valid UTF-8" unless encoded.valid_encoding?

        encoded
      rescue EncodingError => e
        raise UnsupportedType, "string is not convertible to UTF-8: #{e.message}"
      end
    end
  end
end
