# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # HTTP 529, Anthropic's own: the model is up and full. Retriable.
      class OverloadedError < Error; end
    end
  end
end
