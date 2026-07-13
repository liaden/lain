# frozen_string_literal: true

module Lain
  # Token accounting for one model call, provider-neutral.
  #
  # Usage is a commutative monoid under +#++ with {.zero} as the identity. That
  # is not decoration: aggregating a branched Timeline means summing over a set
  # of turns in no particular order, and the laws are what make the result
  # independent of the order you happen to walk them in. The specs assert them.
  #
  # Correct aggregation also requires summing over *unique* turn digests. A
  # branched timeline shares its prefix, so naively adding up every reachable
  # turn double-counts it.
  #
  # Cache fields are nullable on the wire; they are normalized to 0 here so the
  # monoid is total and callers never guard against nil.
  Usage = Data.define(
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens
  ) do
    def self.zero
      @zero ||= new(input_tokens: 0, output_tokens: 0,
                    cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
    end

    def initialize(input_tokens: 0, output_tokens: 0,
                   cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      super(
        input_tokens: Integer(input_tokens || 0),
        output_tokens: Integer(output_tokens || 0),
        cache_creation_input_tokens: Integer(cache_creation_input_tokens || 0),
        cache_read_input_tokens: Integer(cache_read_input_tokens || 0)
      )
    end

    def +(other)
      raise TypeError, "cannot add #{other.class} to Usage" unless other.is_a?(Usage)

      # Every field is a token count, so the fold is uniform; naming them one by
      # one would only invite a copy-paste error on the fifth.
      self.class.new(**to_h.merge(other.to_h) { |_field, mine, theirs| mine + theirs })
    end

    def zero?
      self == self.class.zero
    end

    # Everything the request was billed for on the way in, cached or not.
    def total_input_tokens
      input_tokens + cache_creation_input_tokens + cache_read_input_tokens
    end

    def total_tokens
      total_input_tokens + output_tokens
    end

    # The first-class bench metric. A silent prompt-cache invalidator shows up
    # here as a ratio that quietly falls to zero while nothing errors.
    #
    # @return [Float] 0.0..1.0, or 0.0 when nothing was read on the way in
    def cache_hit_ratio
      return 0.0 if total_input_tokens.zero?

      cache_read_input_tokens.fdiv(total_input_tokens)
    end
  end
end
