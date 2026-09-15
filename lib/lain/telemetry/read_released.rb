# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Every name REQUIRED, and the count a positive Integer. The names are
      # coerced with `to_s`, so a nil would journal `""` and read as evidence;
      # a count is the one field bytes could ride in on, and a release of no
      # regions never happened.
      class ReadReleased < Declarative::Carrier
        attribute :tool_use_id
        attribute :path
        attribute :regions
        attribute :requester
        attribute :surface
        validates :tool_use_id, presence: { message: "must name the released call, got nil" }
        validates :path, presence: { message: "must name the released file, got nil" }
        validates :regions, numericality: { only_integer: true, greater_than: 0,
                                            message: "must be a positive Integer, got %<value>s" }
        validates :requester, presence: { message: "must name who the read was for, got nil" }
        validates :surface, presence: { message: "must name what released it, got nil" }
      end
    end

    # A `read_file` whose sensitive regions were agreed to and sent to the model:
    # which file, how many regions THIS read released, the call it answered, who
    # it was asked for and the surface that said yes. {ReadRedacted}'s
    # counterpart, and never its bytes.
    #
    # Its own record rather than a `read_redacted` with nothing withheld, because
    # {SessionRecord::Replay} folds every `read_redacted` into the masked
    # read-set, and a release written as one would resume the file as masked.
    # Replay folds THIS record into nothing, not even the ledger: a resumed run
    # has no approval of its own for those regions, so it asks again.
    ReadReleased = Data.define(:tool_use_id, :path, :regions, :requester, :surface) do
      include Journalable

      def initialize(tool_use_id:, path:, regions:, requester:, surface:)
        Carriers::ReadReleased.check!(tool_use_id:, path:, regions:, requester:, surface:)

        super(tool_use_id: -tool_use_id.to_s, path: -path.to_s, regions: regions.to_i,
              requester: -requester.to_s, surface: -surface.to_s)
      end
    end
  end
end
