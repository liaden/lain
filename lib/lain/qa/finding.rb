# frozen_string_literal: true

module Lain
  module QA
    # One defect a QA pass observed, in a shape somebody else can check.
    #
    # FALSIFIABLE OR REFUSED. A finding with no evidence or no reproduction is
    # an opinion, and an implementer handed an opinion spends a round arguing
    # with it instead of fixing anything; so both are required, and what counts
    # as "no evidence" is {QA.words!}'s question rather than this file's.
    # `evidence` is what was observed -- command output, a file and line, a
    # screenshot reference -- and `reproduction` is how to observe it again.
    #
    # `criterion` names what the finding is measured against: an acceptance
    # criterion, or a card's own claim about the files it would touch when the
    # rung that found it spent no model at all.
    Finding = Data.define(:severity, :criterion, :summary, :evidence, :reproduction, :tier) do
      include Declarative

      declare raising: MalformedFinding do
        attribute :severity
        attribute :criterion
        attribute :summary
        attribute :evidence
        attribute :reproduction
        attribute :tier
        validates :severity, inclusion: { in: SEVERITIES, message: "must be one of #{SEVERITIES.join("/")}" }
        validates :tier, inclusion: { in: TIERS, message: "must be one of #{TIERS.join("/")}" }
      end

      # @param hash [Hash] the wire form, String or Symbol keys
      # @return [Finding]
      # @raise [MalformedFinding] naming the members that are missing or wrong
      def self.from_h(hash)
        raise MalformedFinding, "a finding must be an object, got #{hash.inspect}" unless hash.is_a?(Hash)

        keyed = hash.transform_keys(&:to_sym)
        missing = members - keyed.keys
        raise MalformedFinding, "a finding names no #{missing.join(", ")}" unless missing.empty?

        new(**keyed.slice(*members))
      end

      def initialize(severity:, criterion:, summary:, evidence:, reproduction:, tier:)
        values = QA.words!({ severity:, criterion:, summary:, evidence:, reproduction:, tier: },
                           refusal: MalformedFinding)
        self.class.check!(**values)

        super(**values)
      end

      # Whether this finding stops the work it is about from going further.
      def holds? = HOLDING.include?(severity)

      def to_h = super.transform_keys(&:to_s)
    end
  end
end
