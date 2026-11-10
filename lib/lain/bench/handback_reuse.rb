# frozen_string_literal: true

module Lain
  module Bench
    # How many of an epic's handbacks left the standing HEAD alone, so a fast
    # path that skips the second HEAD read can be priced by how often it applies.
    # The judgement is {Isolation::Worktree::Handback::Retirement.reused_head?},
    # the one the retirement itself makes, never a copy of its whitelists.
    HandbackReuse = Data.define(:reused, :total) do
      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
      # @return [HandbackReuse]
      def self.fold(entries)
        lines = Journal.records(entries, type: "handback").to_a
        new(reused: lines.count { |line| Isolation::Worktree::Handback::Retirement.reused_head?(line) },
            total: lines.size)
      end

      # @return [Float, nil] nil when no handback was journaled
      def rate = (reused.fdiv(total) unless total.zero?)
    end
  end
end
