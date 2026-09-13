# frozen_string_literal: true

module Lain
  class Tool
    module Bounds
      # The no-total cap {Tools::Grep} and {Tools::AstSearch} each apply mid-walk,
      # pulled out from both once it was the same one-more-than-the-limit probe
      # and the same "... capped at N" wording in two files. {Bounds}'s own
      # ruling is why this is not {Enumeration}: that shape's {Enumeration#notice}
      # NEEDS the true count, which means it needs the whole ordered collection,
      # and the entire point of a walk cap is to never pull the rest of the
      # collection once it has one row past the limit. So this trailer names
      # only the limit, never a total -- the two are textually distinct on
      # purpose, and neither reader may be taught to expect the other's shape.
      WalkCap = Data.define(:limit) do
        def initialize(limit:) = super(limit: Bounds.ceiling(limit))

        # Pulls at most `limit + 1` items off `rows` and stops -- the one
        # opportunity a lazy walk gives to learn "more exist" without finding
        # out how many. A caller handing this an already-eager Array has
        # already spent the cost this exists to avoid; it works on one just
        # the same, but the point is to hand it something lazy.
        #
        # @param rows [#first] the walk's results, in delivery order --
        #   ordinarily an {Enumerator::Lazy}
        # @return [Found]
        def apply(rows)
          probed = rows.first(limit + 1)
          Found.new(rows: probed.first(limit), capped: probed.size > limit)
        end

        # The trailer sentence. Deliberately silent about the true count,
        # because this cap never learns one -- a number here would be a
        # count {#apply} did not take.
        #
        # @param unit [String] what is being counted, e.g. "matches"
        # @return [String]
        def notice(unit) = "... capped at #{limit} #{unit}"
      end

      # What a walk-capped search hands back either way it is built: through
      # {WalkCap#apply}, which derives `capped` from the probe itself, or
      # directly by a caller that already knows its own flag -- {Tools::Grep}'s
      # daemon arm reads `capped` off the wire rather than recounting rows a
      # remote engine already capped once.
      #
      # @!attribute rows
      #   @return [Array] the first {WalkCap#limit} rows when capped, or every
      #     row the walk found otherwise
      # @!attribute capped
      #   @return [Boolean] whether more rows existed than the limit allowed
      #     through
      Found = Data.define(:rows, :capped)
    end
  end
end
