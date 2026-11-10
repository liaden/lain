# frozen_string_literal: true

module Lain
  class Sensitivity
    module Regions
      # The text a detector reads out of bytes, and the way back from an offset into that text to one
      # into the bytes. Callers tag what they hand over UTF-8 or BINARY whatever the bytes are, so the
      # tag never says UTF-16: a byte order mark or the NUL pattern of mostly-ASCII UTF-16 decides
      # instead, once, here, for the detector and every renderer alike.
      module View
        MARKS = { BOM => :utf8, "\xFF\xFE".b => :utf16le, "\xFE\xFF".b => :utf16be }.freeze
        ENCODINGS = { utf16le: Encoding::UTF_16LE, utf16be: Encoding::UTF_16BE }.freeze
        UNPACK = { utf16le: "v*", utf16be: "n*" }.freeze

        # @param bytes [String] in any encoding
        # @return [Utf8, Utf16]
        def self.of(bytes)
          bytes = bytes.b
          mark, encoding = MARKS.find { |prefix, _| bytes.start_with?(prefix) }
          encoding ||= NulPattern.of(bytes)
          skip = mark ? mark.bytesize : 0
          encoding == :utf8 ? Utf8.new(bytes, skip) : Utf16.new(bytes, encoding, skip)
        end

        # Bytes read as they stand, past a UTF-8 byte order mark if one leads.
        class Utf8
          # @return [String] the UTF-8 bytes a detector scans, tagged BINARY
          attr_reader :text

          # @param bytes [String] BINARY
          # @param skip [Integer] the length of the byte order mark in front of the text
          def initialize(bytes, skip)
            @text = skip.zero? ? bytes : bytes.byteslice(skip..)
            @skip = skip
            freeze
          end

          # @return [Symbol] `:utf8`, `:utf16le` or `:utf16be`
          def encoding = :utf8

          def utf16? = false

          # @param utf8_byte [Integer] an offset into {#text}
          # @return [Integer] the first byte of the character it falls in, in the original bytes
          def offset(utf8_byte) = utf8_byte + @skip

          # @param utf8_byte [Integer] an offset into {#text}
          # @return [Integer] the byte past the character it falls in, so a span mapped back only widens
          def end_offset(utf8_byte) = utf8_byte + @skip

          # @param utf8 [String]
          # @return [String] those characters as the original bytes spell them, BINARY
          def encode(utf8) = utf8.b

          # @param bytes [String] a slice of the original bytes
          # @return [String] what it reads as, UTF-8 bytes tagged BINARY
          def decode(bytes) = bytes.b

          # @param spans [Spans]
          # @return [Spans] each span grown to whole characters of the original bytes
          def aligned(spans) = spans
        end

        # A lone surrogate reads as U+FFFD and keeps its 2 bytes, so every offset still maps back.
        #
        # Not frozen: the text and its offsets are decoded on first use, since a renderer needs only
        # the byte order and the decoding is a Ruby pass over every unit.
        class Utf16
          attr_reader :encoding

          # @param bytes [String] BINARY
          # @param encoding [Symbol] `:utf16le` or `:utf16be`
          # @param skip [Integer] the length of the byte order mark in front of the text
          def initialize(bytes, encoding, skip)
            @bytes = bytes
            @encoding = encoding
            @skip = skip
          end

          def utf16? = true

          # @return [String] the UTF-8 bytes a detector scans, tagged BINARY
          def text = decoding.fetch(:text)

          # @param utf8_byte [Integer] an offset into {#text}
          # @return [Integer] the first byte of the character it falls in, in the original bytes
          def offset(utf8_byte)
            utf8_starts = decoding.fetch(:utf8_starts)
            decoding.fetch(:starts).fetch((utf8_starts.bsearch_index { _1 > utf8_byte } || utf8_starts.size) - 1)
          end

          # @param utf8_byte [Integer] an offset into {#text}
          # @return [Integer] the byte past the character it falls in, so a span mapped back only widens
          def end_offset(utf8_byte)
            decoding.fetch(:starts).fetch(decoding.fetch(:utf8_starts).bsearch_index { _1 >= utf8_byte } || -1)
          end

          # @param utf8 [String]
          # @return [String] those characters in this view's byte order, BINARY
          def encode(utf8) = utf8.encode(ENCODINGS.fetch(encoding)).b

          # @param bytes [String] a slice of the original bytes
          # @return [String] what it reads as, UTF-8 bytes tagged BINARY
          def decode(bytes)
            String.new(bytes, encoding: ENCODINGS.fetch(encoding))
                  .encode(Encoding::UTF_8, invalid: :replace, undef: :replace).b
          end

          # @param spans [Spans]
          # @return [Spans] each span grown to whole 2-byte units
          def aligned(spans)
            Spans.of(spans.map do |span|
              start = span.start & ~1
              Spans::Span.new(start:, length: [(span.finish + 1) & ~1, @bytes.bytesize].min - start)
            end)
          end

          private

          def decoding
            @decoding ||= begin
              units = @bytes.byteslice(@skip, (@bytes.bytesize - @skip) & ~1).unpack(UNPACK.fetch(encoding))
              points, starts, utf8_starts = decoded(units, @skip)
              { text: points.pack("U*").b, starts:, utf8_starts: }.freeze
            end
          end

          # 1 pass, since a UTF-16 read can be a quarter-megabyte: each character's code point, where it
          # starts in the original bytes, and where it starts in the UTF-8 text.
          def decoded(units, skip)
            points = []
            starts = [skip]
            utf8_starts = [0]
            at = 0
            while at < units.size
              width = surrogates?(units[at], units[at + 1]) ? 2 : 1
              points << point(units[at], width == 2 ? units[at + 1] : nil)
              starts << (starts.last + (width * 2))
              utf8_starts << (utf8_starts.last + utf8_width(points.last))
              at += width
            end
            [points, starts, utf8_starts]
          end

          def surrogates?(high, low) = high.between?(0xD800, 0xDBFF) && low&.between?(0xDC00, 0xDFFF)

          def point(unit, low)
            return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00) if low

            unit.between?(0xD800, 0xDFFF) ? 0xFFFD : unit
          end

          def utf8_width(point)
            return 1 if point < 0x80
            return 2 if point < 0x800

            point < 0x10000 ? 3 : 4
          end
        end

        # Whether bytes with no byte order mark are mostly-ASCII UTF-16, read from a leading sample as
        # `file` reads one, so a megabyte of binary costs no more than its first {SAMPLE} bytes.
        # Deliberately narrow: no unit may be NUL, which nearly every binary format holds, a third of
        # the units must be ASCII or Latin-1, and every one of those must be printable or whitespace.
        module NulPattern
          MINIMUM = 4
          SAMPLE = 8 * 1024
          WHITESPACE = [0x09, 0x0A, 0x0C, 0x0D, 0x1B].freeze

          module_function

          # @param bytes [String] BINARY
          # @return [Symbol] `:utf16le`, `:utf16be` or `:utf8`
          def of(bytes)
            return :utf8 unless bytes.include?("\0")

            sample = bytes.byteslice(0, [bytes.bytesize, SAMPLE].min & ~1)
            cut = sample.bytesize < bytes.bytesize - 1
            %i[utf16le utf16be].find { utf16?(units(sample, _1, cut:)) } || :utf8
          end

          # A sample cut short may end between the 2 halves of a surrogate pair, so its last unit is not judged.
          def units(sample, encoding, cut:)
            units = sample.unpack(UNPACK.fetch(encoding))
            cut ? units[0...-1] : units
          end

          def utf16?(units)
            latin = units.select { _1 < 0x100 }
            latin.size >= [MINIMUM, units.size / 3.0].max && latin.all? { printable?(_1) } && paired?(units)
          end

          def printable?(unit) = unit.between?(0x20, 0x7E) || unit >= 0xA0 || WHITESPACE.include?(unit)

          # Padded at both ends, so a surrogate at either end needs its partner as much as one inside.
          def paired?(units)
            [0, *units, 0].each_cons(2).none? { |before, after| high?(before) ^ low?(after) }
          end

          def high?(unit) = unit.between?(0xD800, 0xDBFF)

          def low?(unit) = unit.between?(0xDC00, 0xDFFF)
        end
      end
    end
  end
end
