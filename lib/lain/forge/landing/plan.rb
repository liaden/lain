# frozen_string_literal: true

module Lain
  module Forge
    class Landing
      # The serial protocol, in order, as the objects that run it.
      #
      # `Enumerable` because a landing IS the fold over these four and nothing
      # else -- "a method that yields is a method that composes". {Landing#call}
      # and {Landing#resume_from} both `inject` over one Plan and differ only in
      # the {Evidence} they fold against, so the sequence exists once and cannot
      # drift between the fresh path and the resumed one.
      class Plan
        include Enumerable

        def initialize(promotion:, journaled:, scribe:, sha:, base:, head:, issue_id:, title:, body:)
          @steps = [Promote.new(promotion:, sha:),
                    Open.new(journaled:, base:, head:, title:, body:),
                    Merge.new(journaled:),
                    Transition.new(scribe:, issue_id:)].freeze
          freeze
        end

        def each(&block)
          return to_enum(:each) unless block

          @steps.each(&block)
          self
        end
      end
    end
  end
end
