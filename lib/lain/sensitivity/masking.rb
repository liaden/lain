# frozen_string_literal: true

module Lain
  class Sensitivity
    # Content with the regions nobody has released rendered as
    # {Regions::PLACEHOLDER}, and the surrounding bytes untouched.
    #
    # Its own object because TWO arms withhold regions -- a `read_file` result
    # on its way out of the tool phase ({Middleware::RedactSecretReads}) and a
    # survey's projection of a file it may list ({Survey::Projection}) -- and a
    # shared format with two walks is only half a guarantee: the arms could
    # still disagree about the bytes AROUND the placeholder, the ordinal
    # sequence, or the encoding they hand back. One walk cannot.
    #
    # It does NOT decide what to mask. That answer is {Sensitivity::Ledger}'s,
    # and a caller passes only what nobody has released -- which is what keeps a
    # release rendering as real bytes rather than as a placeholder with a
    # special case.
    #
    # Beside {Regions} rather than inside it, deliberately: `Regions` is the
    # DETECTOR, its docstring is about thresholds and recall, and rendering is a
    # different responsibility that happens to share the value type. The
    # module-length cop naming that split is the reason this file exists, and
    # the split it named is a real one.
    module Masking
      class << self
        # Regions are byte offsets and {Regions.detect} guarantees them
        # ascending and non-overlapping, so one forward walk rebuilds the
        # content with each withheld span swapped for its placeholder. The whole
        # walk is in BINARY because an offset into re-decoded text is a
        # different offset; the original encoding is restored at the end, and
        # the placeholder is ASCII so it cannot invalidate it.
        #
        # @param content [String] the bytes the regions were detected in
        # @param regions [Enumerable<#start, #length>] the ones to withhold,
        #   ascending
        # @param ordinals [Enumerator] the placeholder numbering, supplied when
        #   a caller masks several pieces of one result and needs the ordinals
        #   to stay consecutive ACROSS them
        # @return [String] shaped and encoded as `content` arrived
        def render(content, regions, ordinals: (1..).each)
          bytes = content.b
          cursor, parts = regions.inject([0, []]) { |carry, region| swap(bytes, carry, region, ordinals) }

          (parts << bytes.byteslice(cursor..)).join.force_encoding(content.encoding)
        end

        private

        # The bytes kept since the previous region, then the placeholder that
        # stands in for this one -- carrying forward the offset just past it.
        def swap(bytes, (at, kept), region, ordinals)
          [region.start + region.length,
           kept + [bytes.byteslice(at, region.start - at), format(Regions::PLACEHOLDER, ordinals.next)]]
        end
      end
    end
  end
end
