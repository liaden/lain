# frozen_string_literal: true

module Lain
  module Isolation
    module Verifier
      # No suite configured: the verification says so rather than claiming a pass.
      module Skipped
        DETAIL = "no verification is configured"

        # @param candidate [Candidate]
        # @return [LandingQueue::Verification] skipped, with the candidate's commit as its tip
        def self.call(candidate) = LandingQueue::Verification.new(outcome: :skipped, tip: candidate.sha, detail: DETAIL)
      end
    end
  end
end
