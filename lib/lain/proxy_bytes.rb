# frozen_string_literal: true

module Lain
  ProxyBytes = Data.define(:count) do
    include Declarative

    # Non-negative, and not defensive noise: `Integer#/` FLOORS rather than
    # truncating, so a negative count would round AWAY from zero and overstate
    # the magnitude {#to_tokens} promises to understate. Both producers clamp at
    # zero today, so this closes the gap between the docstring's claim and the
    # arithmetic rather than a live defect.
    #
    # The coercion stays `Integer(count)` and does NOT become
    # `:lain_strict_integer`, which is stricter in two ways this constructor has
    # never been -- it refuses a fractional Float where `Integer(3.7)` truncates,
    # and reads `"010"` as ten where `Integer("010")` reads eight -- and refuses
    # with {Declarative::Types::CoercionError} rather than the ArgumentError
    # every caller already rescues. Worse, on a `check!` class carrying a
    # `validates` rule the cast fires inside `valid?` and PRE-EMPTS the declared
    # refusal, so the malformed input it exists to catch is the one it breaks.
    declare do
      attribute :count
      validates :count, numericality: { greater_than_or_equal_to: 0,
                                        message: "cannot be negative, got %<value>s" }
    end

    def initialize(count:)
      count = Integer(count)
      self.class.check!(count:)

      super
    end
  end

  # A count of CANONICAL BYTES, as a value, so it cannot be spent as a token
  # count by accident.
  #
  # Compaction measures history with a byte proxy in place of a real tokenizer --
  # `Canonical.dump(messages).bytesize`, deterministic, the only property the
  # threshold and the boundary need. Every {Lain::Usage} field and every
  # {Lain::PriceBook} rate is per TOKEN. Both were spelled "tokens" and both were
  # bare Integers, so pricing the proxy at a per-token rate looked exactly like
  # pricing real usage and overstated every compaction's dollars by the whole
  # bytes-per-token ratio. Wrapping the count makes that a raise: `Usage`'s
  # `Integer()` refuses this object, so {#to_tokens} is the ONE crossing.
  #
  # Top-level, beside {Usage}, because TWO pricing sites consume the proxy --
  # {Compaction::Scheduler} and {Plan::SeamDecision} -- and neither owns it. A
  # second constant of the same value in the other subsystem would be a drift
  # surface: two copies promising to agree do not.
  class ProxyBytes
    # How many canonical bytes this bench ESTIMATES to one model token -- an
    # estimate, not a measurement, since nothing in this process tokenizes, which
    # is why the proxy exists at all. ~4 characters per token is the figure the
    # major BPE tokenizers are quoted at for English prose, and canonical bytes
    # are ASCII-dominated JSON of exactly that prose plus punctuation. A real
    # tokenizer, or a fit of journaled `used_tokens` against a record's
    # `bytes_before`, replaces this constant and nothing else.
    BYTES_PER_TOKEN = 4

    # Truncating, not rounding: this figure ends up in a dollar claim, and an
    # estimate that understates is the honest direction for one. `Integer#/`
    # actually FLOORS, which is the same thing only because the constructor
    # refuses a negative.
    #
    # @return [Integer] the estimated token count these bytes stand for
    def to_tokens = count / BYTES_PER_TOKEN
  end
end
