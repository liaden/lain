# frozen_string_literal: true

module Lain
  class Sensitivity
    # A command's output masked as one text, so a region and every recurrence of
    # it, raw or escaped, mask alike. A secret-named value joins as a literal,
    # found only by its recurrences.
    #
    # A placeholder already in the text is a slot whose bytes are gone: it is
    # kept, counted as `prior`, and never renumbered, so masking is idempotent.
    #
    # A detected region whose digest is in `released` is shown; a secret-named
    # value is masked whatever was released.
    class TextMask
      # @param text [String] the whole output
      # @param secrets [#to_a] values masked wherever they appear
      # @return [String] the text with every detected or given secret masked
      def self.text(text, secrets:) = new(secrets: secrets.to_a).call(text).text

      # Masks a record handed whole to a reader nobody releases anything to.
      # A region one text reveals in context is masked in every text, even
      # where it stands bare, so the bytes masked are the same whatever order
      # the texts arrive in. The ordinals run across all of them.
      #
      # @param texts [Array<String>]
      # @param secrets [#to_a] values masked wherever they appear
      # @return [Array<String>] one per text, in order, numbered past every
      #   placeholder any of them already holds
      def self.transcript(texts, secrets:)
        found = texts.map { Regions.detect(_1) }
        union = Union.new((found.flatten.map(&:bytes) + secrets.to_a).uniq)
        ordinals = ((texts.map { Regions.highest(_1) }.max.to_i + 1)..).each
        texts.zip(found).map { |text, regions| new(secrets: union.in(text)).masked(text, regions, ordinals).text }
      end

      # The values a transcript masks, each with the spellings
      # {Regions.recurrences} seeks, so a text is handed only the values it
      # holds: a long transcript otherwise costs texts times values.
      class Union
        # @param values [Array<String>]
        def initialize(values)
          @spelled = values.to_h { [_1, Regions.spellings(_1)] }
          freeze
        end

        # A UTF-16 text is handed every value, since its spellings depend on the text.
        #
        # @param text [String]
        # @return [Array<String>] the values some spelling of which the text holds
        def in(text)
          bytes = text.b
          return @spelled.keys if Regions::View.of(bytes).utf16?

          @spelled.select { |_, spellings| spellings.any? { bytes.include?(_1) } }.keys
        end
      end

      # @param secrets [Array<String>] values masked wherever they appear
      # @param released [Set<String>] digests of detected regions to show
      def initialize(secrets:, released: Set.new)
        @secrets = secrets.map(&:-@).freeze
        @released = released.to_set.freeze
        freeze
      end

      # @param text [String] the whole output
      # @return [Masked] numbered after the highest placeholder already present
      def call(text) = mask(text, Regions.numbering_after(text))

      # @param input [ScanInput]
      # @param found [Array<Regions::Region>] the input's regions
      # @return [Masked] as {#call}, over the input's checksums flag
      def scanned(input, found) = masked(input.text, found, Regions.numbering_after(input.text))

      # @param ordinals [Enumerator] the placeholder numbering; shared, it numbers
      #   several streams of one command as one
      # @return [Stream] a masker for output that arrives in pieces
      def stream(ordinals: (1..).each) = Stream.new(self, ordinals:)

      # @api private
      # @param text [String]
      # @param ordinals [Enumerator] the placeholder numbering, shared across a stream's pieces
      # @return [Masked]
      def mask(text, ordinals) = masked(text, Regions.detect(text), ordinals)

      # @api private
      # @param text [String]
      # @param found [Array<Regions::Region>] what the detector found in `text`
      # @param ordinals [Enumerator]
      # @return [Masked]
      def masked(text, found, ordinals)
        found = found.reject { @released.include?(_1.digest) }
        spans = Spans.of(found + Regions.recurrences(text, found.map(&:bytes) + @secrets))
        Masked.new(text: Masking.render(text, spans, ordinals:), fresh: spans.count, prior: Regions.placeholders(text))
      end

      # Output arriving in pieces, masked with one numbering across all of them.
      # A line is shown once it ends at a newline or a carriage return, and a
      # private-key block only once its END line has arrived, because the tail
      # of a key is not a secret a line-wise detector can see.
      #
      # A line still open past {PARTIAL_CAP} is shown up to its last space or
      # tab, so a progress bar or a long unbroken line is not held until exit,
      # and a token, which holds neither, is masked whole.
      #
      # UTF-16 output is cut only after a whole 2-byte newline or blank, and each
      # piece is masked behind the stream's byte order mark, since a later piece
      # carries none and must still be read, and spelled back, as UTF-16.
      class Stream
        # Roughly what a held block may grow to (one chunk past it) before it is
        # masked unfinished; an endless BEGIN must not hold the display forever.
        HOLD_CAP = 256 * 1024
        PARTIAL_CAP = 4 * 1024
        LINE_END = /[\n\r]/n
        BLANK = /[ \t]/n
        KEY_BEGIN = /^-----BEGIN [A-Z ]*KEY-----/n
        KEY_END = /-----END [^\n]*\n/n
        SUNK = /\A.*?-----END [^\n]*\n/mn

        Layout = Data.define(:line, :blank, :width, :mark)

        # How one encoding spells the newline and the blank a cut lands after.
        class Layout
          # @param bytes [String] BINARY, starting on a character boundary
          # @param pattern [Regexp] {#line} or {#blank}
          # @return [Integer, nil] the length up to and including the last whole match
          def after_last(bytes, pattern)
            found = Enumerator.produce(bytes.rindex(pattern)) { _1.positive? ? bytes.rindex(pattern, _1 - 1) : nil }
                              .take_while(&:itself).find { (_1 % width).zero? }
            found && (found + width)
          end

          # @return [Integer] the most of `bytes` that ends on a character boundary
          def whole(bytes) = bytes.bytesize - (bytes.bytesize % width)

          # @return [String] `mark` in front of `text`, unless it is there already
          def marked(text) = text.start_with?(mark) ? text : mark + text
        end

        LAYOUTS = {
          utf8: Layout.new(line: LINE_END, blank: BLANK, width: 1, mark: "".b.freeze),
          utf16le: Layout.new(line: /[\n\r]\0/n, blank: /[ \t]\0/n, width: 2, mark: "\xFF\xFE".b.freeze),
          utf16be: Layout.new(line: /\0[\n\r]/n, blank: /\0[ \t]/n, width: 2, mark: "\xFE\xFF".b.freeze)
        }.freeze

        # @return [Integer] how many fresh spans have been masked so far
        attr_reader :count

        # @param mask [TextMask]
        # @param ordinals [Enumerator] the placeholder numbering
        def initialize(mask, ordinals:)
          @mask = mask
          @ordinals = ordinals
          @pending = String.new(encoding: Encoding::BINARY)
          @count = 0
          @sunk = false
        end

        # @param chunk [String]
        # @return [String] the masked text safe to show now
        def <<(chunk)
          @pending << chunk.b
          cut = layout.after_last(@pending, layout.line)
          return take(cut, final: false) if cut
          return +"" if @pending.bytesize <= PARTIAL_CAP

          take(partial_cut, final: false)
        end

        # @return [String] the rest, masked whole; never raw
        def finish = take(@pending.bytesize, final: true)

        private

        # Read from the first 2 bytes or more, since a byte order mark arrives only once.
        def layout
          return @layout if @layout
          return LAYOUTS.fetch(:utf8) if @pending.bytesize < 2

          @layout = LAYOUTS.fetch(Regions::View.of(@pending).encoding)
        end

        # A held key block is taken whole, so it answers to {HOLD_CAP} alone.
        def partial_cut
          blank = layout.after_last(@pending, layout.blank) unless @pending.match?(KEY_BEGIN)
          blank && blank > layout.width ? blank : layout.whole(@pending)
        end

        def take(length, final:)
          text = settled(@pending.slice!(0, length))
          start = text.rindex(KEY_BEGIN)
          return masked(text) unless start && text.byteindex(KEY_END, start).nil?

          hold(text, start, final)
        end

        def hold(text, start, final)
          held = text.byteslice(start..)
          head = masked(text.byteslice(0, start))
          return head + sink(held, final) if final || held.bytesize + @pending.bytesize > HOLD_CAP

          @pending.prepend(held)
          head
        end

        # The rest of a block already masked unfinished is dropped, through its END line.
        def settled(text)
          return text unless @sunk

          @sunk = !text.match?(SUNK)
          text.sub(SUNK, "")
        end

        # The numbering is shared and cannot rewind, so a slot the input already shows is stepped over.
        def skip_shown(text)
          highest = Regions.highest(text)
          @ordinals.next while @ordinals.peek <= highest
        end

        def sink(held, final)
          @sunk = !final
          span = Spans::Span.new(start: 0, length: held.bytesize)
          @count += 1
          Masking.render(held.force_encoding(Encoding::UTF_8), Spans.of([span]), ordinals: @ordinals)
        end

        def masked(text)
          marked = layout.marked(text).force_encoding(Encoding::UTF_8)
          skip_shown(marked)
          masked = @mask.mask(marked, @ordinals)
          @count += masked.fresh
          masked.text.byteslice((marked.bytesize - text.bytesize)..)
        end
      end
    end
  end
end
