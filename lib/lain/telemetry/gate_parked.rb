# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `issue_id` and `sha` are untyped because interning would turn the nil of a stage that names neither into "".
      class GateParked < Declarative::Carrier
        attribute :artifact_digest, :lain_interned
        attribute :epic_slug, :lain_interned
        attribute :issue_id
        attribute :stage, :lain_interned
        attribute :sha
        attribute :question, :lain_interned
      end
    end

    # A deferred gate refused and parked an artifact. Journaled beside the
    # `gate_decision` because that record carries no question and no commit, so
    # the morning review could not otherwise say what it was being asked to
    # sign off or join the park to the test run on that commit.
    #
    # @!attribute [r] artifact_digest
    #   @return [String] the gate identity the sign-off queue parks under
    # @!attribute [r] epic_slug
    #   @return [String]
    # @!attribute [r] issue_id
    #   @return [String, nil]
    # @!attribute [r] stage
    #   @return [String]
    # @!attribute [r] sha
    #   @return [String, nil] the commit an implementation gate is about
    # @!attribute [r] question
    #   @return [String] the gate question, verbatim
    GateParked = Data.define(:artifact_digest, :epic_slug, :issue_id, :stage, :sha, :question) do
      include Journalable

      def initialize(artifact_digest:, epic_slug:, issue_id:, stage:, sha:, question:)
        super(**Carriers::GateParked.settle!(artifact_digest:, epic_slug:, issue_id:, stage:, sha:, question:))
      end
    end
  end
end
