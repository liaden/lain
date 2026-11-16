# frozen_string_literal: true

module Lain
  module Review
    class Queue
      # @!attribute request
      #   @return [Request] the review request the row stands for
      Row = Data.define(:id, :rank, :reason, :request, :head_sha)
    end
  end
end
