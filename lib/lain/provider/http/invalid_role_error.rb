# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # A message built with a role no wire format has. Not an HTTP failure: it is
      # refused before a request exists.
      class InvalidRoleError < StandardError; end
    end
  end
end
