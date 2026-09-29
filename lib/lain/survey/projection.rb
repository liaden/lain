# frozen_string_literal: true

module Lain
  module Survey
    # What a survey may SEE of a file it is allowed to list: the file's own
    # bytes, with every region nobody has released rendered as the read path's
    # placeholder.
    #
    # == Why a listed file is still projected
    #
    # A gated file enters the corpus REDACTED to its released regions. The two
    # alternatives are each wrong in one direction: withholding it wholesale
    # makes a survey stricter than {Middleware::RedactSecretReads} over the same
    # file, and entering it whole makes a survey looser. Neither is defensible
    # when both arms are looking at the same bytes for the same human.
    #
    # And EVERY file is projected, not just the gated ones, for the content
    # boundary's own reason: a path rule cannot see a key pasted into
    # `notes.txt`. {Walk} decides which paths enter; this decides which bytes of
    # them do, and the two together are one admission policy.
    #
    # == What it masks is exactly what {Sensitivity::Regions} finds, no more
    #
    # Said plainly, because a survey applies this to whole trees of prose and "no
    # secret reaches the corpus" is a claim it cannot make. A value the detector
    # reports is masked wherever it sits; one it does not report is not. So a
    # credential repeated in a sentence, a shell transcript or a JSON body
    # projects verbatim; UTF-16LE content is invisible end to end, because the
    # shapes are byte-anchored. That is the detector's documented
    # residual, and the read path behaves identically over the same file. What
    # the projection guarantees is narrower and true: no region the ledger holds
    # as unreleased survives into a survey artifact.
    #
    # == Applied at the SOURCE, which is where a leak can still be stopped
    #
    # {Middleware::RedactSecretReads}' argument one layer over: unreleased bytes
    # must never exist above the thing that remembers them. Above the source, the
    # session, journal, docent and model see only released bytes -- and unit keys
    # and the corpus address digest the PROJECTION, so a release legitimately
    # changes what the survey can show and the affected units honestly demand a
    # re-read.
    #
    # One surface is NOT that artifact: on a SURVEY the window `:LainNote`
    # operates on is the diff's `new` slot, a REAL file buffer the human can
    # edit, and it shows the file on disk unprojected, deliberately -- a survey is
    # a survey of project STATE. A human can always open their own file in their
    # own editor, so unprojected bytes there are correct. What WOULD be a leak is
    # unprojected bytes inside the artifact itself: the journal, the docent brief,
    # a `/critique` prefill. So a note placed in that buffer journals its
    # evidence through {#line}, never the buffer's text.
    #
    # == The ledger is the run's one ledger
    #
    # `ledger:` is REQUIRED, with no default and no Null Object -- {Sensitivity::Ledger}'s
    # rule, honoured rather than dodged. A default is how a second ledger gets
    # built in silence, and a Null would answer "nothing outstanding" forever: a
    # release control that releases everything, wearing this codebase's Null
    # idiom as camouflage.
    #
    # `complete: true` on every call is EARNED rather than assumed: a corpus reads
    # whole files by construction, never a prefix and never an offset window,
    # which is what makes the reconcile inside {Sensitivity::Ledger#outstanding}
    # sound. A size cap here would have to come back through `complete: false`, or
    # every projection past it forgets its releases and re-masks what a human
    # already approved.
    #
    # With no approval surface wired into a survey, the masked projection simply
    # stands.
    class Projection
      # The contract the required `ledger:` keeps, named so the raise and the
      # doc above it cannot drift into two different arguments.
      LEDGER_CONTRACT = "the run has ONE region ledger, built on the Switchboard and injected -- " \
                        "a second one holds releases nobody ever sees"

      # @param ledger [Sensitivity::Ledger] the run's ONE region ledger
      # @raise [ArgumentError] on a nil ledger
      def initialize(ledger:)
        # A missing KEYWORD is Ruby's error; a nil VALUE is not, and nil is what
        # a caller reaching for an unwired board holds.
        raise ArgumentError, "a ledger is required: #{LEDGER_CONTRACT}" unless ledger

        @ledger = ledger
        freeze
      end

      # @param path [String, Pathname] the file, ABSOLUTE -- the ledger is
      #   per-run and has no cwd of its own to resolve against, and refuses a
      #   relative path rather than merging two files behind one key
      # @param content [String] its whole bytes, in any encoding
      # @param size [Integer, nil] what the walk measured, when the caller holds a
      #   {Walk::Listing}; checked against the bytes and refused on a
      #   disagreement. A cross-check, not a second source of truth.
      # @return [String] the same bytes with every unreleased region masked,
      #   shaped and encoded as it arrived
      # @raise [ArgumentError] on a relative path (from the ledger) or on
      #   content that is not the whole file
      def project(path, content, size: nil)
        # BEFORE the ledger is touched, for {Middleware::RedactSecretReads}'
        # reason: `outstanding` reconciles, so asking it about a view we are
        # about to refuse would forget releases for regions nobody looked at.
        whole!(content, size)
        # Asked UNCONDITIONALLY, even of content holding nothing: `outstanding`
        # is what reconciles this path's releases against the regions the file
        # holds now, so skipping the call for an empty scan would leave a
        # release standing for a secret that has been deleted -- and send it
        # unasked if it ever came back.
        unreleased = @ledger.outstanding(path, Sensitivity::Regions.detect(content), complete: true)
        return content if unreleased.empty?

        # {Sensitivity::Masking} and not a walk of this object's own: the read
        # path renders withheld regions too, and one walk is what stops the two
        # arms drifting on the bytes around the placeholder. The ordinal counts
        # MASKED regions, so a released one consumes no number.
        Sensitivity::Masking.render(content, unreleased)
      end

      # One line of the projection, numbered as the file on disk numbers it --
      # which {#project}'s answer is not, because a region spanning lines (a
      # private key block) collapses into one placeholder. A note is placed in
      # the unprojected buffer, so the number it names is the disk's.
      #
      # The ledger is asked about the WHOLE file, exactly as {#project} asks it:
      # a scan of one line would reconcile away every release for a region on
      # any other line. Each region crossing the line is then masked where it
      # crosses, under the ordinal the whole projection gives it, so a line
      # inside a masked region answers that region's placeholder and never a
      # neighbour's text.
      #
      # @param path [String, Pathname] the file, ABSOLUTE, as for {#project}
      # @param content [String] its whole bytes
      # @param number [Integer] 1-based, by {Review::Anchor.lines}' rule
      # @return [String, nil] that line with its unreleased regions masked, in
      #   the content's encoding; nil when the file holds no such line
      def line(path, content, number)
        unreleased = @ledger.outstanding(path, Sensitivity::Regions.detect(content), complete: true)
        from, to = span(content, number)
        return nil if from.nil?

        crossing = unreleased.each_with_index.select { |region, _| crosses?(region, from, to) }
        Sensitivity::Masking.render(content.byteslice(from, to - from),
                                    crossing.map { |region, _| clipped(region, from, to) },
                                    ordinals: crossing.map { |_, index| index + 1 }.each)
      end

      # Where a raw line lands in {#project}'s answer. A region collapses to one
      # placeholder, so every line it spans answers the placeholder's line and
      # every line below shifts up by the newlines the regions above swallowed.
      #
      # @param path [String, Pathname] the file, ABSOLUTE, as for {#project}
      # @param content [String] its whole bytes
      # @param raw_line [Integer] 1-based, by {Review::Anchor.lines}' rule
      # @return [Integer] 1-based; `raw_line` itself when the file holds no such line
      def projected_line(path, content, raw_line)
        unreleased = @ledger.outstanding(path, Sensitivity::Regions.detect(content), complete: true)
        from, to = span(content, raw_line)
        return raw_line if from.nil?

        offset = unreleased.find { |region| crosses?(region, from, to) }&.start || from
        1 + newlines(content, 0, offset) - swallowed_before(content, unreleased, offset)
      end

      private

      def newlines(content, start, length) = content.b.byteslice(start, length).count("\n")

      def swallowed_before(content, regions, offset)
        regions.select { |region| region.start + region.length <= offset }
               .sum { |region| newlines(content, region.start, region.length) }
      end

      Clipped = Data.define(:start, :length)
      private_constant :Clipped

      # Byte offsets of one line, without its terminator.
      def span(content, number)
        lines = Review::Anchor.lines(content.b)
        return [nil, nil] unless number.between?(1, lines.size)

        from = lines.first(number - 1).sum { |line| line.bytesize + 1 }
        [from, from + lines[number - 1].bytesize]
      end

      # Half-open, which already holds for an empty line: a region spanning it
      # starts before its offset and ends after it. A region STARTING at an
      # empty line would begin with its newline, and no detector emits one.
      def crosses?(region, from, to) = region.start < to && region.start + region.length > from

      def clipped(region, from, to)
        start = [region.start, from].max
        Clipped.new(start: start - from, length: [region.start + region.length, to].min - start)
      end

      # `complete: true` is a claim about the BYTES, and this object cannot see a
      # truncation by looking at one. The failure it prevents surfaces nowhere
      # near the truncation: a partial scan reconciles away releases for regions
      # nobody looked at, and the file re-masks what a human approved, forever.
      def whole!(content, size)
        return if size.nil? || content.bytesize == size

        raise ArgumentError, "a projection is over the whole file: got #{content.bytesize} bytes, " \
                             "and the walk listed #{size}"
      end
    end
  end
end
