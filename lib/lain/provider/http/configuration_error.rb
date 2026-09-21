# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # A provider asked to work without something it cannot work without -- an API
      # key, a base URL. Not an HTTP failure: nothing was sent.
      class ConfigurationError < StandardError; end
    end
  end
end
