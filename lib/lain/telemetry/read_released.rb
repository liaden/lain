# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Every name REQUIRED, and the count a positive Integer. The names are
      # coerced with `to_s`, so a nil would journal `""` and read as evidence;
      # a count is the one field bytes could ride in on, and a release of no
      # regions never happened.
      class ReadReleased < Declarative::Carrier
        attribute :tool_use_id, :lain_interned
        attribute :path, :lain_interned
        attribute :regions
        attribute :requester, :lain_interned
        attribute :surface, :lain_interned
        validates :tool_use_id, presence: { message: "must name the released call, got nil" }
        validates :path, presence: { message: "must name the released file, got nil" }
        validates :regions, numericality: { only_integer: true, greater_than: 0,
                                            message: "must be a positive Integer, got %<value>s" }
        validates :requester, presence: { message: "must name who the read was for, got nil" }
        validates :surface, presence: { message: "must name what released it, got nil" }
        validates :tool_use_id, raw_present: { message: "must name the released call" }
        validates :path, raw_present: { message: "must name the released file" }
        validates :requester, raw_present: { message: "must name who the read was for" }
        validates :surface, raw_present: { message: "must name what released it" }
      end
    end

    # A `read_file` whose sensitive regions were agreed to and sent to the model:
    # which file, how many regions THIS read released, the call it answered, who
    # it was asked for and the surface that said yes. {SourceMasked}'s
    # counterpart, and never its bytes.
    #
    # Its own record rather than a `source_masked` with nothing withheld, because
    # {SessionRecord::Replay} folds every `source_masked` into the withheld
    # set, and a release written as one would resume the file as masked.
    # Replay folds THIS record into nothing, not even the ledger: a resumed run
    # has no approval of its own for those regions, so it asks again.
    ReadReleased = Data.define(:tool_use_id, :path, :regions, :requester, :surface) do
      include Journalable

      # `regions` stays untyped so numericality judges what the caller gave ("2" passes) before it
      # becomes an Integer.
      def initialize(tool_use_id:, path:, regions:, requester:, surface:)
        settled = Carriers::ReadReleased.settle!(tool_use_id:, path:, regions:, requester:, surface:)
        super(**settled, regions: settled.fetch(:regions).to_i)
      end
    end
  end
end
