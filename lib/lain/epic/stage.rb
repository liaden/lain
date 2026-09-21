# frozen_string_literal: true

module Lain
  module Epic
    # Loud at construction, because a stage is a partition key: a typo that
    # constructs folds onto a partition nothing writes to, and reads as drained.
    class UnknownStage < Error; end

    # An epic's gates could not open here, because an earlier stage of the SAME
    # epic still has sign-offs parked, or was never approved at all.
    class StageBlocked < Error; end

    # One stage of one epic's pipeline, and the STAGE-BOUNDARY rule: a stage's
    # gates may only open when every EARLIER stage's sign-off partition is
    # drained AND carries an approval. Deferring is allowed to accumulate within
    # a stage -- that is what deferring is for -- but it may never cross a
    # boundary, or an epic would reach implementation on a plan nobody ever
    # signed off. Drained alone is the absence of a record, which a stage nobody
    # ever submitted has too, and so does one whose sign-off was journaled under
    # a damaged address: the approval is the evidence neither can fake.
    #
    # Partitions are keyed `(epic_slug, stage)`, so the check is scoped to ONE
    # epic: a global drain would let one epic's unreviewed research block every
    # other epic's planning, and concurrent epics are the normal case. The same
    # argument scopes the issue-scoped stages to one issue: a sibling's parked
    # plan is not this issue's boundary. The queue arrives as an argument
    # answering `#drained?` and `#approved?` rather than as a stored
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

      # @raise [Error] at the terminal stage
      def next
        # Asked what follows the last stage. Answering nil would push the same
        # question one call on, into a NoMethodError naming nothing.
        raise Error, "#{name} is the last epic stage -- nothing follows it" if last?

        self.class.new(STAGES.fetch(index + 1))
      end

      # Earliest first: exactly the partitions the boundary rule must find
      # drained.
      def preceding = STAGES.take(index).map { |earlier| self.class.new(earlier) }

      # The boundary check a gate runs before it opens at this stage.
      #
      # @param queue [#drained?, #approved?, #parked] the sign-off queue, asked
      #   per earlier partition; `#parked` only once the check has refused, to
      #   name a park that holds every issue's gate
      # @param epic_slug [#to_s] the epic being walked; nothing outside it is consulted
      # @param issue_id [String, nil] the issue whose gate is opening; nil
      #   checks every issue, the conservative reading
      # @return [Stage] self, so the check reads as a precondition in a chain
      # @raise [StageBlocked] naming the epic, every earlier stage still holding
      #   and every earlier stage never approved
      def ensure_open!(queue, epic_slug:, issue_id: nil)
        parked = preceding.reject { |earlier| queue.drained?(epic_slug, earlier.name, issue_id:) }
        unapproved = (preceding - parked).reject { |earlier| approved?(earlier, queue, epic_slug, issue_id) }
        return self if parked.empty? && unapproved.empty?

        raise StageBlocked, blocked_message(parked, unapproved, queue, epic_slug, issue_id)
      end

      def to_s = name

      private

      # An epic-wide stage is approved once for every issue, so its evidence
      # names no issue; an issue-scoped one is approved per issue.
      def approved?(earlier, queue, epic_slug, issue_id)
        queue.approved?(epic_slug, earlier.name, issue_id: (issue_id if earlier.issue_scoped?))
      end

      def blocked_message(parked, unapproved, queue, epic_slug, issue_id)
        reasons = [(held(parked, queue, epic_slug, issue_id) unless parked.empty?),
                   (never_approved(unapproved) unless unapproved.empty?)]
        "epic #{epic_slug.to_s.inspect} cannot open its #{name} stage#{for_issue(issue_id)} -- " \
          "#{reasons.compact.join("; ")}"
      end

      def held(parked, queue, epic_slug, issue_id)
        "#{parked.map(&:name).join(", ")} still holds sign-offs parked " \
          "(approve or deny them before the boundary opens)#{unscoped(parked, queue, epic_slug, issue_id)}"
      end

      def never_approved(unapproved)
        "#{unapproved.map(&:name).join(", ")} not approved " \
          "(a stage opens only once every earlier stage carries an approved sign-off)"
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
