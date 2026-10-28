# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `ran` is checked by inclusion: `presence:` would refuse a false.
      class TestsRan < Declarative::Carrier
        NAMED = {
          issue_id: "must name the issue",
          sha: "must name the sha tested"
        }.freeze

        attribute :issue_id, :lain_interned
        attribute :sha, :lain_interned
        attribute :ran
        attribute :why, default: nil
        validates :issue_id, presence: { message: "must name the issue, got %<value>s" }
        validates :sha, presence: { message: "must name the sha tested, got %<value>s" }
        validates :ran, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :why, presence: { message: "must say why the tests were not run, got %<value>s" }, unless: :ran

        validate :names_are_not_blank

        private

        # The interning cast turns false, [] and {} into present Strings, so blankness is judged on the raw value.
        def names_are_not_blank
          NAMED.each do |name, text|
            raw = @attributes[name.to_s].value_before_type_cast
            errors.add(name, "#{text}, got #{raw.inspect}") if raw.blank? && !errors.include?(name)
          end
        end
      end
    end

    # What the project's own suite did on the sha an implementation gate is
    # about to name, or why it was not run. Counts, not names: the gate reads
    # how many, and the names stay with the run that produced them.
    TestsRan = Data.define(:issue_id, :sha, :ran, :passed, :failed, :errors, :why) do
      include Journalable

      # @param run [Grader::TestHarness::Run]
      # @param issue_id [String]
      # @param sha [String]
      # @return [TestsRan]
      def self.from(run, issue_id:, sha:)
        new(issue_id:, sha:, ran: true, passed: run.passed.size, failed: run.failed.size, errors: run.errors.size)
      end

      # @param issue_id [String]
      # @param sha [String]
      # @param why [String]
      # @return [TestsRan]
      def self.unrun(issue_id:, sha:, why:) = new(issue_id:, sha:, ran: false, why:)

      # The counts are not declared: `errors` is ActiveModel's own reader for the carrier's refusals.
      def initialize(issue_id:, sha:, ran:, passed: 0, failed: 0, errors: 0, why: nil)
        super(**Carriers::TestsRan.settle!(issue_id:, sha:, ran:, why: why && -why.to_s),
              passed: Integer(passed), failed: Integer(failed), errors: Integer(errors))
      end
    end
  end
end
