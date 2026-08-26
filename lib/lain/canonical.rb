# frozen_string_literal: true

require "json"

module Lain
  # Deterministic serialization, serving two invariants with one function:
  # Event identity (an Event's hash is the BLAKE3 of its canonical form) and
  # prompt-cache stability (Anthropic's cache is a prefix match over the encoded
  # request, so a Hash iterating in insertion order across two Toolset
  # constructions would invalidate the cache with no error anywhere). Both are
  # the same requirement -- byte-identical output for semantically identical
  # input. Keys are sorted; array order is preserved, because array order is
  # meaning.
  #
  # The canonical form names the *wire* representation, so Symbols and Strings
  # collapse together: `{a: 1}` and `{"a" => 1}` are the same message and hash
  # identically. A Hash carrying *both* `:a` and `"a"` is genuinely ambiguous and
  # raises rather than silently dropping one.
  module Canonical
    DIGEST_ALGORITHM = "blake3"

    class UnsupportedType < Error; end
    class NonFiniteFloat < Error; end
    class AmbiguousKey < Error; end

    class << self
      # The wire form of +value+: JSON-native types only, String keys, objects
      # sorted, deeply frozen. Callers that *store* content (Lain::Event) keep
      # this and not the original, so what is hashed and what is retained cannot
      # drift apart.
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

      # Content address of +value+, e.g. "blake3:af1349...". The algorithm prefix
      # keeps a future migration from being a silent reinterpretation; the hash
      # itself lives in ext/lain rather than a second vendored Ruby copy, so there
      # is one blake3 and one place it can drift.
      #
      # Frozen and deduplicated: digests are Hash keys all over (the Store,
      # cache-break walks), and one unfrozen ivar anywhere in a Turn makes the
      # whole object non-Ractor-shareable.
      def digest(value)
        -"#{DIGEST_ALGORITHM}:#{Lain::Ext.blake3_hex(dump(value))}"
      end

      private

      # The house style is `each_with_object` over a hand-mutated accumulator;
      # this method is the documented exception, because it is the hottest
      # allocation site in lib/ and both deviations are measured, not assumed.
      #
      # `each_with_object` over a Hash yields each entry as a [key, value] Array
      # for the block to destructure, allocating one Array per entry that is
      # discarded immediately. `Hash#each` with a two-parameter block does not.
      # Measured on a 40-key Hash: 2 objects / 2.08kB against 42 / 3.68kB.
      def normalize_hash(hash)
        normalized = {}
        hash.each do |key, value|
          string_key = normalize_key(key)
          raise AmbiguousKey, "#{string_key.inspect} is both a String and a Symbol key" if normalized.key?(string_key)

          normalized[string_key] = normalize(value)
        end
        # Hashes preserve insertion order, so inserting by SORTED KEY yields what
        # `sort_by { |key, _| key }.to_h` did without allocating a [key, value]
        # Array per entry, an Array to hold them, and a second Hash to pour them
        # back into. On a turn-shaped payload: 382 objects -> 251, 25.0kB ->
        # 19.7kB, output byte-identical.
        #
        # Style/ReduceToHash wants `to_h { |key| [key, normalized[key]] }`, whose
        # block must RETURN a [key, value] Array -- reintroducing exactly the
        # per-entry Array this avoids. Measured on a 40-key Hash: each_with_object
        # 3 objects / 2.34kB, to_h 42 objects / 3.60kB.
        # rubocop:disable Style/ReduceToHash
        normalized.keys.sort!.each_with_object({}) { |key, acc| acc[key] = normalized[key] }.freeze
        # rubocop:enable Style/ReduceToHash
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
      # bytes. Encoding to UTF-8 *from* UTF-8 is a no-op and does not validate,
      # so invalid bytes are caught by the explicit check, never by #encode.
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
