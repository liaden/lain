# frozen_string_literal: true

require "json"

module Lain
  # Deterministic serialization, serving two invariants with one function.
  #
  # 1. Event identity. An Event's hash is the BLAKE3 of its canonical form, so two
  #    events that mean the same thing on the wire must serialize to the same bytes.
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
    DIGEST_ALGORITHM = "blake3"

    class UnsupportedType < Error; end
    class NonFiniteFloat < Error; end
    class AmbiguousKey < Error; end

    class << self
      # The wire form of +value+: JSON-native types only, String keys, objects
      # sorted, everything deeply frozen. Callers that need to *store* content
      # (see Lain::Event) keep this rather than the original, so what is hashed
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

      # Content address of +value+, e.g. "blake3:af1349...". The prefix keeps the
      # algorithm explicit so a future migration is not a silent reinterpretation.
      # The hash itself lives in ext/lain (Rust) rather than a second, separately
      # vendored Ruby implementation -- one blake3, one place it can drift.
      #
      # Returned frozen and deduplicated. Digests are used as Hash keys all over
      # (the Store, cache-break walks), and an unfrozen ivar anywhere in a Turn is
      # enough to make the whole object non-Ractor-shareable.
      def digest(value)
        -"#{DIGEST_ALGORITHM}:#{Lain::Ext.blake3_hex(dump(value))}"
      end

      private

      # The house style is `each_with_object` over a hand-mutated accumulator,
      # and this method is the documented exception -- it is the hottest
      # allocation site in lib/, and BOTH deviations below are measured, not
      # assumed. Everything else in this file follows the house style.
      #
      # `each_with_object` over a Hash yields the entry as a [key, value] Array
      # so the block can destructure it, allocating one Array PER ENTRY that is
      # discarded immediately. `Hash#each` with a two-parameter block does not.
      # Measured on a 40-key Hash: 2 objects / 2.08kB against 42 / 3.68kB.
      def normalize_hash(hash)
        normalized = {}
        hash.each do |key, value|
          string_key = normalize_key(key)
          raise AmbiguousKey, "#{string_key.inspect} is both a String and a Symbol key" if normalized.key?(string_key)

          normalized[string_key] = normalize(value)
        end
        # Hashes preserve insertion order, so inserting by SORTED KEY yields the
        # same Hash `sort_by { |key, _| key }.to_h` did -- without allocating a
        # [key, value] Array per entry, an Array to hold them, and a second Hash
        # to pour them back into. `sort!` orders the one key Array in place.
        # On a turn-shaped payload that swap alone is 382 objects -> 251 and
        # 25.0kB -> 19.7kB, output byte-identical.
        #
        # Style/ReduceToHash wants `to_h { |key| [key, normalized[key]] }` here.
        # That is the one rewrite this line exists to avoid: `to_h`'s block must
        # RETURN a [key, value] Array, so it reintroduces exactly the per-entry
        # Array that `sort_by` was allocating. Measured on a 40-key Hash --
        # each_with_object 3 objects / 2.34kB, to_h 42 objects / 3.60kB.
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
