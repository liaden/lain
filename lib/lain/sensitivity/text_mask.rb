# frozen_string_literal: true

module Lain
  class Sensitivity
    # A command's output as one {Middleware::RedactSecretReads::Rows::Row}, so a
    # region and every recurrence of it, raw or escaped, mask alike. A
    # secret-named value joins as a {Literal}, found only by its recurrences.
    #
    # A command's output has no file to key a release on, so nothing here is
    # ever released: what is detected is masked.
    class TextMask
      Literal = Data.define(:bytes)

      # Matches no detected region, so only its recurrences mask.
      class Literal
        def digest = nil
      end

      # @param secrets [Array<String>] values masked wherever they appear
      def initialize(secrets:)
        @literals = secrets.map { Literal.new(bytes: _1) }.freeze
        freeze
      end

      # @param text [String] the whole output
      # @return [Array(String, Integer)] the masked text and how many spans were masked
      def call(text) = mask(text, (1..).each)

      # @param ordinals [Enumerator] the placeholder numbering; shared, it numbers
      #   several streams of one command as one
      # @return [Stream] a masker for output that arrives in pieces
      def stream(ordinals: (1..).each) = Stream.new(self, ordinals:)

      # @api private
      # @param text [String]
      # @param ordinals [Enumerator] the placeholder numbering, shared across a stream's pieces
      # @return [Array(String, Integer)]
      def mask(text, ordinals)
        row = Middleware::RedactSecretReads::Rows::Row.new(prefix: "", text:, path: nil, regions: Regions.detect(text))
        row.masked(row.regions + @literals, ordinals)
      end

      # Output arriving in pieces, masked with one numbering across all of them.
      # A line is shown once it ends at a newline or a carriage return, and a
      # private-key block only once its END line has arrived, because the tail
      # of a key is not a secret a line-wise detector can see.
      #
      # A line still open past {PARTIAL_CAP} is shown up to its last space or
      # tab, so a progress bar or a long unbroken line is not held until exit,
      # and a token, which holds neither, is masked whole.
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

        # @return [Integer] how many spans have been masked so far
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
          cut = @pending.rindex(LINE_END)
          return take(cut + 1, final: false) if cut
          return +"" if @pending.bytesize <= PARTIAL_CAP

          take(partial_cut, final: false)
        end

        # @return [String] the rest, masked whole; never raw
        def finish = take(@pending.bytesize, final: true)

        private

        # A held key block is taken whole, so it answers to {HOLD_CAP} alone.
        def partial_cut
          blank = @pending.rindex(BLANK) unless @pending.match?(KEY_BEGIN)
          blank&.positive? ? blank + 1 : @pending.bytesize
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

        def sink(held, final)
          @sunk = !final
          span = Spans::Span.new(start: 0, length: held.bytesize)
          @count += 1
          Masking.render(held.force_encoding(Encoding::UTF_8), Spans.of([span]), ordinals: @ordinals)
        end

        def masked(text)
          out, spans = @mask.mask(text.force_encoding(Encoding::UTF_8), @ordinals)
          @count += spans
          out
        end
      end

      private_constant :Literal
    end
  end
end
