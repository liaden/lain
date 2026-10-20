# frozen_string_literal: true

module Lain
  class Sensitivity
    # Content with the regions nobody has released rendered as
    # {Regions::PLACEHOLDER}, and the surrounding bytes untouched.
    #
    # Its own object because five callers render masks -- the read path
    # ({Middleware::RedactSecretReads}), a survey's projection
    # ({Survey::Projection}) and others -- and a shared format with several walks
    # is only half a guarantee: they could still disagree about the bytes AROUND
    # the placeholder, the ordinal sequence, or the encoding they hand back. One
    # walk cannot.
    #
    # It does NOT decide what to mask; that is {Sensitivity::Ledger}'s answer,
    # and a caller passes only what nobody has released -- which is what keeps a
    # release rendering as real bytes rather than a special-cased placeholder.
    #
    # Beside {Regions} rather than inside it: `Regions` is the DETECTOR, and
    # rendering is a different responsibility that happens to share the value
    # type. The module-length cop named the split, and it is a real one.
    module Masking
      class << self
        # Regions are byte offsets, held ascending and separated by {Spans}
        # (a plain list is checked, never sorted), so one forward walk rebuilds the
        # content with each withheld span swapped for its placeholder. The whole
        # walk is in BINARY because an offset into re-decoded text is a
        # different offset; the original encoding is restored at the end, and
        # the placeholder is ASCII so it cannot invalidate it.
        #
        # @param content [String] the bytes the regions were detected in
        # @param regions [Spans, Enumerable<#start, #length>] the ones to withhold,
        #   ascending; touching ones render as one slot
        # @param ordinals [Enumerator] the placeholder numbering, supplied when
        #   a caller masks several pieces of one result and needs the ordinals
        #   to stay consecutive ACROSS them
        # @return [String] shaped and encoded as `content` arrived
        def render(content, regions, ordinals: (1..).each)
          bytes = content.b
          spans = regions.is_a?(Spans) ? regions : Spans.ascending(regions)
          cursor, parts = spans.inject([0, []]) { |carry, region| swap(bytes, carry, region, ordinals) }

          (parts << bytes.byteslice(cursor..)).join.force_encoding(content.encoding)
        end

        # Detects and masks in one call, for a caller that releases nothing.
        #
        # @param text [String]
        # @param ordinals [Enumerator] see {render}
        # @return [String]
        def redact(text, ordinals:) = render(text, Regions.detect(text), ordinals:)

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
