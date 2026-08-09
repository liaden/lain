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
    # Said plainly, because a survey applies this to whole trees of prose rather
    # than to the one file a model named, and "no secret reaches the corpus" is
    # a claim this cannot make. A value the detector reports is masked wherever
    # it sits; a value it does not report is not. So a credential repeated in
    # a sentence, in a shell transcript, or inside a JSON body projects
    # verbatim; a `machine host login sam password hunter2` line has no
    # assignment shape and is not seen; and UTF-16LE content is invisible end to
    # end, because the shapes are byte-anchored. That is the detector's
    # documented residual and the read path behaves identically over the same
    # file -- this arm neither widens nor narrows it. What the projection
    # guarantees is narrower and true: no region the ledger holds as unreleased
    # survives into a survey artifact.
    #
    # == Applied at the SOURCE, which is where a leak can still be stopped
    #
    # {Middleware::RedactSecretReads}' argument, one layer over: unreleased bytes
    # must never exist above the thing that remembers them. Above the source,
    # the session, the surfaces, the journal and the docent see only released
    # bytes, so no survey artifact can carry an unreleased secret -- and unit
    # keys and the corpus address digest the PROJECTION, so a release
    # legitimately changes what the survey can show and the affected units
    # honestly demand a re-read.
    #
    # == The ledger is the run's one ledger
    #
    # `ledger:` is REQUIRED, with no default and no Null Object -- {Sensitivity::Ledger}'s
    # rule, honoured rather than dodged. A default is how a second ledger gets
    # built in silence, and a Null would answer "nothing outstanding" forever: a
    # release control that releases everything, wearing this codebase's Null
    # idiom as camouflage.
    #
    # `complete: true` on every call, and that is EARNED rather than assumed: a
    # corpus reads whole files by construction, never a prefix and never an
    # offset window, which is exactly what makes the reconcile inside
    # {Sensitivity::Ledger#outstanding} sound. A size cap here would have to come
    # back through `complete: false` or every projection past it forgets its
    # releases and re-masks what a human already approved.
    #
    # With no approval surface wired into a survey, the masked projection simply
    # stands -- a human can always open their own file in their own editor.
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
      # @param size [Integer, nil] what the walk measured, when the caller holds
      #   a {Walk::Listing}; checked against the bytes and refused on a
      #   disagreement. Absent for a caller with no listing, which has nothing
      #   to check against -- it is a cross-check, not a second source of truth.
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
        # MASKED regions in reading order, so a released one consumes no number
        # and the human sees `1, 2` rather than `2, 3`.
        Sensitivity::Masking.render(content, unreleased)
      end

      private

      # `complete: true` is a claim about the BYTES, and this object cannot see
      # a truncation by looking at one. Where a caller holds a listing it can
      # say what the walk measured, and the disagreement is caught here --
      # because the failure it prevents surfaces nowhere near the truncation:
      # a partial scan reconciles away releases for regions nobody looked at,
      # and the file re-masks what a human already approved, forever.
      def whole!(content, size)
        return if size.nil? || content.bytesize == size

        raise ArgumentError, "a projection is over the whole file: got #{content.bytesize} bytes, " \
                             "and the walk listed #{size}"
      end
    end
  end
end
