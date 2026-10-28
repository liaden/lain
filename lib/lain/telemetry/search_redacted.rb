# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A path and two non-negative Integer COUNTS, never content; `released` is
      # a subset of `regions`, so more released than found is a malformed record.
      class SearchRedacted < Declarative::Carrier
        NAMED = {
          path: "must name the redacted path"
        }.freeze

        attribute :tool_use_id, :lain_interned
        attribute :path, :lain_interned
        attribute :regions
        attribute :released
        validates :path, presence: { message: "must name the redacted path, got nil" }
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

    # A `grep` or `ast_search` result whose rows had regions of one file
    # masked: which file, how many regions the rows showed, and how many of
    # those were already released. Counts, never bytes, as {SourceMasked}.
    #
    # Its own record rather than a `source_masked`, because
    # {SessionRecord::Replay} folds every `source_masked` into the withheld
    # set, and a search reads no file whole: folded as a mask, one grep
    # would leave every file it matched unwritable after a resume. Replay
    # folds this record into nothing.
    SearchRedacted = Data.define(:tool_use_id, :path, :regions, :released) do
      include Journalable

      # The counts stay untyped so numericality judges what the caller gave before they become Integers.
      def initialize(tool_use_id:, path:, regions:, released:)
        settled = Carriers::SearchRedacted.settle!(tool_use_id:, path:, regions:, released:)
        super(**settled, regions: settled.fetch(:regions).to_i, released: settled.fetch(:released).to_i)
      end
    end
  end
end
