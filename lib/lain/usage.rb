# frozen_string_literal: true

module Lain
  # Token accounting for one model call, provider-neutral.
  #
  # A commutative monoid under +#++ with {.zero} as the identity, and not as
  # decoration: aggregating a branched Timeline sums over a set of turns in no
  # particular order, and the laws are what make the result independent of the
  # walk order. Correct aggregation also needs *unique* turn digests -- a
  # branched timeline shares its prefix, so adding up every reachable turn
  # double-counts it.
  #
  # Cache fields are nullable on the wire and normalized to 0 here, so the monoid
  # is total and callers never guard against nil.
  Usage = Data.define(
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens
  ) do
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

  class Usage
    # A constant, not a memoized class ivar, so there is no first-call race --
    # and defined by REOPENING the class, because a constant set inside the
    # `Data.define` block above would scope to `Lain`, not `Usage` (CLAUDE.md).
    ZERO = new.freeze

    def self.zero = ZERO

    # The Anthropic wire's `usage` object, decoded in ONE place. Three callers
    # spelled these four string keys out by hand -- {Provider::Anthropic},
    # and {SessionRecord::Salvage}, which decodes bytes
    # replayed from the response WAL. A key that drifted in the third would
    # under-report spend on exactly the turn nobody was watching, since a
    # salvaged turn is by definition one a crash interrupted. It sits in this
    # reopened body beside `ZERO`; a `def self.` inside `Data.define` would have
    # worked, as CLAUDE.md's trap covers constants and nested classes only.
    #
    # Absent usage is zero, not an error: an assembled stream carrying no usage
    # event hands over `{}`, and the sync path's `body["usage"]` can be nil
    # outright. Both are the absence of billing information, and #initialize
    # normalizes each nullable field to 0. Accepting `nil` is the one widening
    # over the three inline copies, which raised NoMethodError on it.
    #
    # @param wire [Hash, nil] parsed JSON -- STRING keys, as it comes off the
    #   wire. A symbol-keyed Hash yields an all-zero Usage rather than raising,
    #   exactly as the three inline copies did; this feeds bench cost
    #   accounting, so pass it what the parser produced.
    def self.from_anthropic_wire(wire)
      wire ||= {}
      new(input_tokens: wire["input_tokens"], output_tokens: wire["output_tokens"],
          cache_creation_input_tokens: wire["cache_creation_input_tokens"],
          cache_read_input_tokens: wire["cache_read_input_tokens"])
    end
  end
end
