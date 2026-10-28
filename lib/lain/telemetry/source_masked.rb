# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A source and two non-negative Integer COUNTS, never content. The key
      # drives a control: {SessionRecord::Replay} folds it into the session, so a
      # record naming no source would withhold nothing, or the resume's cwd.
      class SourceMasked < Declarative::Carrier
        NAMED = {
          key: "must name the masked source"
        }.freeze

        attribute :tool_use_id, :lain_interned
        attribute :kind
        attribute :key, :lain_interned
        attribute :regions
        attribute :released, default: 0
        validates :kind, inclusion: { in: Session::Withheld::KINDS + Session::Withheld::KINDS.map(&:to_s),
                                      message: "must be one of #{Session::Withheld::KINDS.inspect}, got %<value>s" }
        validates :key, presence: { message: "must name the masked source, got %<value>s" }
        validates :regions, :released, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                                       message: "must be a non-negative Integer, got %<value>s" }
        include ReleasedWithinRegions

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

    # A file or memory item whose bytes reached the model with regions masked:
    # which source and how many regions, never which bytes. A resumed session
    # refuses to rewrite it.
    SourceMasked = Data.define(:tool_use_id, :kind, :key, :regions, :released) do
      include Journalable

      # The kind and counts stay as given so inclusion and numericality judge them before they are coerced.
      def initialize(tool_use_id:, kind:, key:, regions:, released: 0)
        settled = Carriers::SourceMasked.settle!(tool_use_id:, kind:, key:, regions:, released:)
        super(**settled, kind: settled.fetch(:kind).to_sym, regions: settled.fetch(:regions).to_i,
                         released: settled.fetch(:released).to_i)
      end
    end
  end
end
