# frozen_string_literal: true

module Lain
  module Isolation
    # What a verifier judges: a commit and a checkout standing on it.
    #
    # @!attribute [r] sha
    #   @return [String] the commit under judgement
    # @!attribute [r] path
    #   @return [String] a checkout standing on `sha`
    Candidate = Data.define(:sha, :path) do
      def initialize(sha:, path:)
        super(sha: -sha.to_s, path: -path.to_s)
      end
    end
  end
end
