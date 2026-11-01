# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # HTTP 429 whose body says the account's usage, quota or credits ran out.
      # A sibling of {RateLimitError}, not a subclass, so the retry middleware
      # never matches it: waiting a few seconds does not refill a quota.
      class QuotaError < Error; end
    end
  end
end
