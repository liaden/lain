# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # HTTP 403: the credentials are good and do not reach this resource.
      class ForbiddenError < Error; end
    end
  end
end
