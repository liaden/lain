# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A memory id and one non-negative Integer COUNT, never content. The id
      # drives a control: {SessionRecord::Replay} folds it into the session, so
      # a record naming no item would refuse nothing after a resume.
      class MemoryMasked < Declarative::Carrier
        attribute :id
        attribute :regions
        attribute :prior
        validates :id, presence: { message: "must name the memory item read masked, got %<value>s" }
        validates :regions, :prior, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                                    message: "must be a non-negative Integer, got %<value>s" }
      end
    end

    # A `memory_read` whose body had spans masked: which item, how many, and how
    # many placeholders it already held, never which bytes. A resumed session
    # refuses to rewrite that item. `prior` defaults to 0 so a record journaled
    # before it existed still reads.
    MemoryMasked = Data.define(:tool_use_id, :id, :regions, :prior) do
      include Journalable

      def initialize(tool_use_id:, id:, regions:, prior: 0)
        Carriers::MemoryMasked.check!(id:, regions:, prior:)

        super(tool_use_id: -tool_use_id.to_s, id: -id.to_s, regions: regions.to_i, prior: prior.to_i)
      end
    end
  end
end
