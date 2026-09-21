# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # HTTP 401: the credentials were read and refused.
      class UnauthorizedError < Error; end
    end
  end
end
