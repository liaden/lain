# frozen_string_literal: true

module Lain
  class Compare
    # A failure nobody could place is counted apart rather than folded into one of the 4 kinds.
    module Attribution
      KINDS = %i[environment reasoning grader prompt].freeze

      # A task that never produced a graded subject has none to be labelled by, so its task is the key.
      Failure = Data.define(:task, :subject, :kind)

      # @param outcomes [Enumerable<Symbol, nil>] one kind per failed task, nil where none is known
      # @return [Hash{Symbol=>Integer}] a count for every kind, plus :unattributed
      def self.tally(outcomes)
        counts = outcomes.to_a.tally
        [*KINDS, :unattributed].to_h { |kind| [kind, counts.fetch(kind == :unattributed ? nil : kind, 0)] }
      end

      # A hand-kept label outranks the run's own kind, looked up by the subject's digest and then the task's.
      #
      # @param attempts_by_arm [Hash{String=>Array<Array>}] per arm, the attempts of each task: a run
      #   answering `#grade` and `#timeline`, or an {Arm::Driver::TaskFailure}
      # @param tasks [Array<String>] the suite, in the order the attempts are
      # @param labels [Bench::Labels]
      # @return [Array<String>] the rendered table, or nothing when no arm failed anything
      def self.sections(attempts_by_arm, tasks:, labels:)
        tallies = attempts_by_arm.transform_values do |tries|
          tally(failures_of(tries, tasks).map { |failure| labelled(failure, labels) || failure.kind })
        end
        return [] if tallies.values.all? { |counts| counts.values.sum.zero? }

        headers = ["arm", *KINDS, "unattributed"].map(&:to_s)
        rows = tallies.map { |name, counts| [name, *counts.values.map(&:to_s)] }
        ["failure attribution (failed attempts)\n#{Table.new(headers:, rows:)}"]
      end

      def self.failures_of(tries, tasks)
        tries.zip(tasks).flat_map { |attempts, task| attempts.filter_map { |result| failure(result, task) } }
      end
      private_class_method :failures_of

      def self.failure(result, task)
        return Failure.new(task:, subject: nil, kind: result.kind) if result.is_a?(Arm::Driver::TaskFailure)

        grade = result.grade
        return unless grade.respond_to?(:pass?) && !grade.pass?

        Failure.new(task:, subject: result.timeline&.head_digest, kind: kind_of(grade))
      end
      private_class_method :failure

      def self.kind_of(grade) = grade.respond_to?(:failure_kind) ? grade.failure_kind || :reasoning : nil
      private_class_method :kind_of

      def self.labelled(failure, labels)
        digests = [failure.subject, Canonical.digest(failure.task)].compact
        digests.filter_map { |digest| labels.fetch(digest) }.first&.to_sym
      end
      private_class_method :labelled
    end
  end
end
