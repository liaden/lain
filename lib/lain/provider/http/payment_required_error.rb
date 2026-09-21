# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # HTTP 402: the account is out of credit.
      class PaymentRequiredError < Error; end
    end
  end
end
