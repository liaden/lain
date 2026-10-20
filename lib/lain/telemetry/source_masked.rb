# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A source and two non-negative Integer COUNTS, never content. The key
      # drives a control: {SessionRecord::Replay} folds it into the session, so a
      # record naming no source would withhold nothing, or the resume's cwd.
      class SourceMasked < Declarative::Carrier
        attribute :kind
        attribute :key
        attribute :regions
        attribute :released
        validates :kind, inclusion: { in: Session::Withheld::KINDS + Session::Withheld::KINDS.map(&:to_s),
                                      message: "must be one of #{Session::Withheld::KINDS.inspect}, got %<value>s" }
        validates :key, presence: { message: "must name the masked source, got %<value>s" }
        validates :regions, :released, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                                       message: "must be a non-negative Integer, got %<value>s" }
        include ReleasedWithinRegions
      end
    end

    # A file or memory item whose bytes reached the model with regions masked:
    # which source and how many regions, never which bytes. A resumed session
    # refuses to rewrite it.
    SourceMasked = Data.define(:tool_use_id, :kind, :key, :regions, :released) do
      include Journalable

      def initialize(tool_use_id:, kind:, key:, regions:, released: 0)
        Carriers::SourceMasked.check!(kind:, key:, regions:, released:)

        super(tool_use_id: -tool_use_id.to_s, kind: kind.to_sym, key: -key.to_s, regions: regions.to_i,
              released: released.to_i)
      end
    end
  end
end
