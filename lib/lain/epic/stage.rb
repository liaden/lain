# frozen_string_literal: true

module Lain
  module Epic
    # The stages an epic walks, in order. A CLOSED set, like
    # {Epic::STORED_STATUSES}: the order is the pipeline, so membership and
    # position are the same fact and neither may be spelled twice.
    STAGES = %w[research epic_plan issue_plan implementation].freeze

    # The stages whose artifact is about ONE issue, so their gates are opened,
    # parked and approved per issue. research and epic_plan are the epic's own
    # documents and stay epic-wide.
    ISSUE_STAGES = %w[issue_plan implementation].freeze

    # Loud at construction, because a stage is a partition key: a typo that
    # constructs folds onto a partition nothing writes to, and reads as drained.
    class UnknownStage < Error; end

    # Asked what follows the last stage. Answering nil would push the same
    # question one call on, into a NoMethodError naming nothing.
    class NoSuccessor < Error; end

    # An epic's gates could not open here, because an earlier stage of the SAME
    # epic still has sign-offs parked.
    class StageBlocked < Error; end

    # One stage of one epic's pipeline, and the STAGE-BOUNDARY rule: a stage's
    # gates may only open when every EARLIER stage's sign-off partition is
    # drained. Deferring is allowed to accumulate within a stage -- that is what
    # deferring is for -- but it may never cross a boundary, or an epic would
    # reach implementation on a plan nobody ever signed off.
    #
    # Partitions are keyed `(epic_slug, stage)`, so the check is scoped to ONE
    # epic: a global drain would let one epic's unreviewed research block every
    # other epic's planning, and concurrent epics are the normal case. The same
    # argument scopes the issue-scoped stages to one issue: a sibling's parked
    # plan is not this issue's boundary. The queue arrives as an argument
    # answering `#drained?(epic_slug, stage, issue_id:)` rather than as a stored
    # collaborator -- a Stage is a frozen value, and which queue it is asked
    # about is the caller's fact, not the value's.
    Stage = Data.define(:name) do
      include Comparable
      include Declarative

      # The closed set, declared rather than written as a guard clause, and a
      # hand-written `validate` rather than `inclusion:` because the message is
      # what this refusal is for: a stage is a partition key, so the reader of
      # the failure needs the pipeline AND the offending name. It is also the one
      # refusal in this unit a HUMAN reads directly -- `CLI::EpicSubmit` turns
      # argv into a Stage before anything else. `Declarative` joins every refusal
      # as `"<attribute> <message>"`, which puts `name` in front of whatever is
      # written here, so the wording has to go on reading as a sentence after
      # that word; a spec pins it whole. `check!`, not `settle!`, because the
      # name is interned before it is judged and settling would hand back an
      # unshared copy of it.
      declare raising: UnknownStage do
        attribute :name

        validate :must_name_a_stage

        def must_name_a_stage
          return if STAGES.include?(name)

          errors.add(:name, "must be one of #{STAGES.join(" -> ")}, got #{name.inspect}")
        end
      end

      def self.all = STAGES.map { |name| new(name) }

      def initialize(name:)
        name = -name.to_s
        self.class.check!(name:)

        super
      end

      # Position in the pipeline, which is also the ordering {Comparable} uses --
      # `epic_plan` follows `research` because the pipeline says so.
      def index = STAGES.index(name)

      # `nil` for anything that is not a Stage -- the {Comparable} protocol,
      # which then raises "comparison of Lain::Epic::Stage with String failed"
      # and names both sides. Asked blind, this sent `#index` to the other
      # operand, and String answers that with something else entirely: the error
      # came out of `String#index`, naming neither Stage nor the comparison.
      def <=>(other) = other.is_a?(self.class) ? index <=> other.index : nil

      def last? = name == STAGES.last

      def issue_scoped? = ISSUE_STAGES.include?(name)

      # @raise [NoSuccessor] at the terminal stage
      def next
        raise NoSuccessor, "#{name} is the last epic stage -- nothing follows it" if last?

        self.class.new(STAGES.fetch(index + 1))
      end

      # Earliest first: exactly the partitions the boundary rule must find
      # drained.
      def preceding = STAGES.take(index).map { |earlier| self.class.new(earlier) }

      # The boundary check a gate runs before it opens at this stage.
      #
      # @param queue [#drained?, #parked] the sign-off queue, asked per earlier
      #   partition; `#parked` only once the check has refused, to name a park
      #   that holds every issue's gate
      # @param epic_slug [#to_s] the epic being walked; nothing outside it is consulted
      # @param issue_id [String, nil] the issue whose gate is opening; nil
      #   checks every issue, the conservative reading
      # @return [Stage] self, so the check reads as a precondition in a chain
      # @raise [StageBlocked] naming the epic and every earlier stage still holding
      def ensure_open!(queue, epic_slug:, issue_id: nil)
        blocked = preceding.reject { |earlier| queue.drained?(epic_slug, earlier.name, issue_id:) }
        raise StageBlocked, blocked_message(blocked, queue, epic_slug, issue_id) unless blocked.empty?

        self
      end

      def to_s = name

      private

      def blocked_message(blocked, queue, epic_slug, issue_id)
        "epic #{epic_slug.to_s.inspect} cannot open its #{name} stage#{for_issue(issue_id)} -- " \
          "#{blocked.map(&:name).join(", ")} still holds sign-offs parked " \
          "(approve or deny them before the boundary opens)#{unscoped(blocked, queue, epic_slug, issue_id)}"
      end

      # A park in an issue-scoped stage that names no issue -- written before
      # gates named their issue -- holds EVERY issue's gate. Named, or a reader
      # goes looking for a parked sibling that is not there. Asked of the queue
      # only once the check has already refused.
      def unscoped(blocked, queue, epic_slug, issue_id)
        return "" unless issue_id

        blocked.select(&:issue_scoped?)
               .flat_map { |earlier| queue.parked(epic_slug, earlier.name, issue_id:) }
               .reject(&:issue_id)
               .map { |item| legacy_note(item) }
               .join
      end

      def legacy_note(item)
        "; #{item.artifact_digest} (#{item.stage}) names no issue, so it holds every issue's gate"
      end

      def for_issue(issue_id) = issue_id ? " for issue #{issue_id.to_s.inspect}" : ""
    end
  end
end
