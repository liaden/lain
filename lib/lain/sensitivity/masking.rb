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
        # different offset; the original encoding is restored at the end. The
        # placeholder is spelled as the {Regions::View} reads the bytes, so UTF-16
        # stays UTF-16, and a span that splits a UTF-16 character masks all of it.
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
          view = Regions::View.of(bytes)
          spans = view.aligned(regions.is_a?(Spans) ? regions : Spans.ascending(regions))
          pieces(bytes, spans, ordinals, view).join.force_encoding(content.encoding)
        end

        private

        # The bytes kept before each region, then the placeholder standing in
        # for it, and the bytes after the last.
        def pieces(bytes, spans, ordinals, view)
          cursor = 0
          spans.each_with_object([]) do |region, parts|
            placeholder = view.encode(format(Regions::PLACEHOLDER, ordinals.next))
            parts << bytes.byteslice(cursor, region.start - cursor) << placeholder
            cursor = region.start + region.length
          end << bytes.byteslice(cursor..)
        end
      end
    end
  end
end
