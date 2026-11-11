# frozen_string_literal: true

module Lain
  module Epic
    # One partition's gate as every reader sees it: what {Signoff} folded for it, beside the
    # artifact's digest now. {#phase} is the one precedence, so landing, the queue and status
    # cannot each rank a parked draft against a standing approval their own way.
    #
    # @!attribute [r] partition
    #   @return [SignoffQueue::Partition]
    # @!attribute [r] standing
    #   @return [Signoff::Standing, nil] the newest settling verdict, nil where none settled it
    # @!attribute [r] drafts
    #   @return [Array<String>] the digests still parked, in park order
    # @!attribute [r] superseded
    #   @return [Array<String>] the parked digests the standing approval came after; still listed, never waited on
    # @!attribute [r] held
    #   @return [Array<String>] the digests a human asked to wait, in hold order
    # @!attribute [r] current
    #   @return [String, nil] the artifact's digest now, nil where it is gone
    GateView = Data.define(:partition, :standing, :drafts, :superseded, :held, :current) do
      def initialize(partition:, standing:, drafts:, held:, current:, superseded: [])
        super(partition:, standing:, drafts: digests(drafts), superseded: digests(superseded), held: digests(held),
              current: current && -current.to_s)
      end

      # A waiting draft outranks an approval, because the approval may be of the work it replaces. A
      # draft parked before the approved one waits on nothing: clearing it must not stall the epic.
      #
      # @return [Symbol] :parked, :held, :approved, :edited, :gone, :denied or :open
      def phase
        return :parked if waiting.any?
        return :held if held.any?
        return approval_phase if approved_standing?

        standing.nil? ? :open : :denied
      end

      # @return [String, nil] the standing digest while the phase is approved
      def landable_digest = phase == :approved ? standing.digest : nil

      # @return [Array<String>] the parked drafts the phase counts; a superseded one again once its approval falls
      def waiting = approved_standing? ? drafts - superseded : drafts

      # @param digest [#to_s]
      # @return [Boolean] whether the partition stands denied, and at exactly this digest
      def denied?(digest) = phase == :denied && standing.digest == digest.to_s

      private

      def digests(list) = list.map { -_1.to_s }.freeze

      def approved_standing? = standing&.verdict&.approved? || false

      def approval_phase
        return :gone if current.nil?

        standing.digest == current ? :approved : :edited
      end
    end
  end
end
