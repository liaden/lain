# frozen_string_literal: true

module Lain
  class Arm
    # research -> epic_plan -> issue_plan -> implementation -> land, closed and
    # frozen: {Epic::STAGES} plus the one rung that is not a gated stage at
    # all, `land`, which every arm eventually reaches whether or not an epic
    # gated its way there.
    #
    # A frozen Array, not a term algebra -- nothing that walks it needs one.
    # Gate policy is deliberately absent from this class: WHICH answers a
    # rung's gate gives is a {Approval::Gate::Policy} concern, decided by
    # `[epics.gates]` or a bench's own policy map, and folding it into the
    # ladder would make two arms differing only in policy also differ in the
    # stages they visit -- exactly the confound a bench comparing them must
    # not introduce. Two arms under an all-approve stub visit the SAME rungs
    # in the SAME order regardless of which policy map built them; only a
    # denial makes their traces diverge, and measuring that divergence is what
    # a round-trip count is for.
    class Ladder
      RUNGS = (Epic::STAGES + %w[land]).freeze

      # An entry rung named that is not on the ladder at all.
      class UnknownRung < Error; end

      # An arm's rungs are the SUFFIX of the ladder starting at its entry rung
      # -- one-shot enters at `implementation` and never sees a gate, plan-only
      # enters at `issue_plan` and runs no epic, and both epic arms enter at
      # `research` and walk the whole thing.
      #
      # @param entry [#to_s] the rung an arm starts at
      # @return [Array<String>] the suffix from `entry` to `land`, in order
      # @raise [UnknownRung] naming `entry` when it is not a rung on the ladder
      def self.from(entry)
        entry = entry.to_s
        index = RUNGS.index(entry)
        raise UnknownRung, "#{entry.inspect} is not a rung on the ladder (#{RUNGS.join(" -> ")})" if index.nil?

        RUNGS[index..].freeze
      end
    end
  end
end
