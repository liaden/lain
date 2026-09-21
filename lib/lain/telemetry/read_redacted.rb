# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Two non-negative Integer COUNTS, never anything else. `Data` freezes the
      # record but never its members, so without this a mutable String ("3") or
      # a Hash of leaked bytes sails straight through -- silently breaking
      # `Ractor.shareable?` and, for the Hash, defeating the entire point of a
      # record whose job is counts instead of content.
      #
      # `released <= regions` is asserted too: released is a SUBSET of what was
      # found, so "released > regions" is impossible rather than unsafe -- shape,
      # not a second security check.
      class ReadRedacted < Declarative::Carrier
        attribute :path
        attribute :regions
        attribute :released
        # This one DRIVES a control. `SessionRecord::Replay` folds a
        # `read_redacted` back into the masked read-set, so a record with no
        # path masks `path.to_s` -> `""` -> whatever the resume's cwd normalizes
        # to: the mask lands on a directory, the file it was meant to protect
        # reads back as wholly seen, and `write_file` replaces the secret with
        # its own placeholder. Unreachable from the live writer, which always
        # has a resolved path -- but a salvaged or hand-edited journal is what
        # these records exist to survive.
        validates :path, presence: { message: "must name the redacted path, got nil" }
        validates :regions, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                            message: "must be a non-negative Integer, got %<value>s" }
        validates :released, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                             message: "must be a non-negative Integer, got %<value>s" }
        validate :released_within_regions

        private

        # Skipped when either count already failed numericality above: a Hash
        # has no `#to_i` a raw comparison could fall back on, and the
        # numericality error already names the real problem.
        def released_within_regions
          return if errors[:regions].any? || errors[:released].any?
          return if released.to_i <= regions.to_i

          errors.add(:released, "must be <= regions (#{regions}), got #{released}")
        end
      end
    end

    # A `read` whose bytes were released with some regions masked. `regions`
    # and `released` are COUNTS, never the masked or released bytes themselves
    # -- {WriteRefused}'s "name what matched, never the matched bytes"
    # discipline extended to a partial release. `to_i` runs after
    # {Carriers::ReadRedacted} has proven the value numeric, so it only
    # normalizes to the frozen-by-nature Integer the record needs to stay
    # `Ractor.shareable?`.
    ReadRedacted = Data.define(:tool_use_id, :path, :regions, :released) do
      include Journalable

      def initialize(tool_use_id:, path:, regions:, released:)
        Carriers::ReadRedacted.check!(path:, regions:, released:)

        super(tool_use_id: tool_use_id.dup.freeze, path: path.to_s.dup.freeze,
              regions: regions.to_i, released: released.to_i)
      end
    end
  end
end
