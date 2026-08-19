# frozen_string_literal: true

module Lain
  ProxyBytes = Data.define(:count) do
    # Non-negative, and that is not defensive noise: `Integer#/` FLOORS rather
    # than truncating, so a negative count would round AWAY from zero and
    # overstate the magnitude {#to_tokens} promises to understate. Nothing can
    # reach it today -- both producers clamp at zero
    # ({Compaction::Scheduler::Rewrite#dropped} and {Plan::SeamDecision#call})
    # -- so this closes the gap between what the docstring claims and what the
    # arithmetic does, rather than a live defect.
    def initialize(count:)
      count = Integer(count)
      raise ArgumentError, "a byte count cannot be negative, got #{count}" if count.negative?

      super
    end
  end

  # A count of CANONICAL BYTES, as a value, so it cannot be spent as a token
  # count by accident.
  #
  # The compaction subsystem measures history with a byte proxy in place of a
  # real tokenizer -- `Canonical.dump(messages).bytesize`, deterministic, which
  # is the only property the threshold and the boundary need. Every field of
  # {Lain::Usage} and every {Lain::PriceBook} rate, meanwhile, is per TOKEN. The
  # two were both spelled "tokens" and both bare Integers, so pricing the proxy
  # at a per-token rate looked exactly like pricing real usage and overstated
  # every compaction's dollars by the whole bytes-per-token ratio (QA round 5,
  # UX5). Wrapping the count is what makes that a raise: `Usage`'s `Integer()`
  # refuses this object, so {#to_tokens} is the ONE crossing between the units.
  #
  # It lives at the top level, beside {Usage}, because TWO pricing sites consume
  # the proxy -- {Compaction::Scheduler#cost_saved}/`#cost_spent` and
  # {Plan::SeamDecision}'s `rewrite_cost`/`payback` -- and neither owns it. A
  # second constant of the same value in the other subsystem would be a drift
  # surface: two copies promising to agree do not.
  class ProxyBytes
    # How many canonical bytes this bench ESTIMATES to one model token.
    #
    # An estimate and not a measurement, stated here so there is exactly one
    # place to correct it: nothing in this process tokenizes, which is the
    # reason the proxy exists at all. What it estimates is the ratio of
    # `Canonical.dump(messages).bytesize` to the tokens a provider would bill
    # for those same messages -- ~4 characters per token is the figure the major
    # BPE tokenizers are quoted at for English prose, and canonical bytes are
    # ASCII-dominated JSON of exactly that prose plus structural punctuation.
    #
    # A real tokenizer, or a fit of journaled `used_tokens` against a record's
    # `bytes_before`, replaces this constant and nothing else.
    BYTES_PER_TOKEN = 4

    # Truncating, not rounding: this figure ends up in a dollar claim, and an
    # estimate that understates is the honest direction for one. A count below a
    # single token's worth of bytes is worth no tokens.
    #
    # `Integer#/` actually FLOORS, which is the same thing only because the
    # constructor refuses a negative -- see it for why that check is what makes
    # this sentence true rather than merely usually true.
    #
    # @return [Integer] the estimated token count these bytes stand for
    def to_tokens = count / BYTES_PER_TOKEN
  end
end
