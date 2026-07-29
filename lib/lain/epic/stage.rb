# frozen_string_literal: true

module Lain
  module Epic
    # The stages an epic walks, in order. A CLOSED set, like
    # {Epic::STORED_STATUSES}: the order is the pipeline, so membership and
    # position are the same fact and neither may be spelled twice.
    STAGES = %w[research epic_plan issue_plan implementation].freeze

    # A stage name outside the closed set. Loud at construction, because a stage
    # is a partition key -- a typo that constructs would fold onto a partition
    # nothing else ever writes to, and read as permanently drained.
    class UnknownStage < Error; end

    # Asked what follows the last stage. Terminal is terminal, and answering nil
    # would push the same question one call further on, into a NoMethodError
    # naming nothing.
    class NoSuccessor < Error; end

    # An epic's gates could not open here, because an earlier stage of the SAME
    # epic still has sign-offs parked.
    class StageBlocked < Error; end

    # One stage of one epic's pipeline, and the STAGE-BOUNDARY rule.
    #
    # The rule (the interview ruling): a stage's gates may only open when every
    # EARLIER stage's sign-off partition is drained. Deferring is allowed to
    # accumulate within a stage -- that is what deferring is for -- but it may
    # never cross a boundary, or an epic would reach implementation on a plan
    # nobody ever signed off.
    #
    # Partitions are keyed `(epic_slug, stage)`, so the check is scoped to ONE
    # epic. That is the whole reason the pair is the key: a global drain would
    # let one epic's unreviewed research block every other epic's planning, and
    # concurrent epics are the normal case, not the exotic one.
    #
    # The queue arrives as an argument answering `#drained?(epic_slug, stage)`,
    # not as a stored collaborator: a Stage is a frozen value, and which queue it
    # is asked about is the caller's fact, not the value's.
    Stage = Data.define(:name) do
      include Comparable

      # Every stage, in pipeline order.
      def self.all = STAGES.map { |name| new(name) }

      def initialize(name:)
        name = -name.to_s
        unless STAGES.include?(name)
          raise UnknownStage, "unknown epic stage #{name.inspect} (the pipeline is #{STAGES.join(" -> ")})"
        end

        super
      end

      # Position in the pipeline, which is also the ordering {Comparable} uses --
      # `epic_plan` follows `research` because the pipeline says so, not because
      # of where the letters fall.
      def index = STAGES.index(name)

      # `nil` for anything that is not a Stage -- the {Comparable} protocol,
      # which then raises "comparison of Lain::Epic::Stage with String failed"
      # and names both sides. Asked blind, this sent `#index` to the other
      # operand, and String answers that with something else entirely: the error
      # came out of `String#index` naming neither Stage nor the comparison. The
      # one place in this file where a type test beats a duck test, because the
      # duck is exactly what lies here.
      def <=>(other) = other.is_a?(self.class) ? index <=> other.index : nil

      def last? = name == STAGES.last

      # @raise [NoSuccessor] at the terminal stage
      def next
        raise NoSuccessor, "#{name} is the last epic stage -- nothing follows it" if last?

        self.class.new(STAGES.fetch(index + 1))
      end

      # The stages before this one, earliest first: exactly the partitions the
      # boundary rule must find drained.
      def preceding = STAGES.take(index).map { |earlier| self.class.new(earlier) }

      # The boundary check a gate runs before it opens at this stage.
      #
      # @param queue [#drained?] the sign-off queue, asked per earlier partition
      # @param epic_slug [#to_s] the epic being walked; nothing outside it is consulted
      # @return [Stage] self, so the check reads as a precondition in a chain
      # @raise [StageBlocked] naming the epic and every earlier stage still holding
      def ensure_open!(queue, epic_slug:)
        blocked = preceding.reject { |earlier| queue.drained?(epic_slug, earlier.name) }
        raise StageBlocked, blocked_message(blocked, epic_slug) unless blocked.empty?

        self
      end

      def to_s = name

      private

      def blocked_message(blocked, epic_slug)
        "epic #{epic_slug.to_s.inspect} cannot open its #{name} stage -- " \
          "#{blocked.map(&:name).join(", ")} still holds sign-offs parked " \
          "(approve or deny them before the boundary opens)"
      end
    end
  end
end
