# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `ran` is checked by inclusion: `presence:` would refuse a false.
      class TestsRan < Declarative::Carrier
        attribute :issue_id
        attribute :sha
        attribute :ran
        attribute :why
        validates :issue_id, presence: { message: "must name the issue, got %<value>s" }
        validates :sha, presence: { message: "must name the sha tested, got %<value>s" }
        validates :ran, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :why, presence: { message: "must say why the tests were not run, got %<value>s" }, unless: :ran
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

      def initialize(issue_id:, sha:, ran:, passed: 0, failed: 0, errors: 0, why: nil)
        Carriers::TestsRan.check!(issue_id:, sha:, ran:, why:)

        super(issue_id: -issue_id.to_s, sha: -sha.to_s, ran:, passed: Integer(passed), failed: Integer(failed),
              errors: Integer(errors), why: why && -why.to_s)
      end
    end
  end
end
