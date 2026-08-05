# frozen_string_literal: true

module Lain
  module Review
    # A critique's findings, offered to the human as suggestions rather than as
    # notes he already made.
    #
    # == The sidecar is NDJSON, beside the prose
    #
    # A critique writes prose for a human; NOTHING parses it. The findings the
    # review surface can act on travel in a second file beside it -- one JSON
    # object per line, at {Sidecar.beside}'s path -- so the prose stays free to be
    # written for its reader, and the machine-readable half never becomes a
    # format the author has to keep valid mid-sentence.
    #
    # == One line, never a range -- FOR NOW
    #
    # A finding names ONE line: the one the problem starts on, with its extent in
    # its own words ("lines 170-182 ..."), which is the form the human reads
    # anyway. The reason is narrower than it looks, so read it as dated rather
    # than as architecture: no carrier this sidecar feeds holds a range YET
    # ({Anchor#line}, {AnnotationPlaced}, the anchor extmark and a diagnostic's
    # single `lnum` are each one position), so an `end_line` would be dropped at
    # the first hop while reading, in the sidecar, as though it had been honoured.
    #
    # T23 ships `start_line`/`start_side` and a range annotation whose ends fall
    # in different hunks. The moment it lands, this is the one place in the
    # pipeline that cannot express a range GitHub accepts, and THAT is where the
    # decision gets revisited -- not by a later reader discovering the paragraph
    # above went stale.
    #
    # == A finding renders in its OWN diagnostic namespace
    #
    # {PROJECTION} carries {NAMESPACE} and {SOURCE}, both different from the
    # human's ({Projection::Diagnostics::DEFAULT_NAMESPACE}), so the two RECORDS
    # are separate: clearing one diagnostic namespace never touches the other,
    # and every entry says which door it came in by.
    #
    # What that does NOT yet buy is a visible difference on screen: nvim 0.12.4
    # draws the same sign for a finding, for a human's blocker and for an LSP's
    # error, and the anchors namespace is shared, so clearing THAT drops both
    # records' positions at once. Both belong to `49_diagnostics.lua`
    # (per-namespace `vim.diagnostic.config` is the fix), are ticketed against
    # T17, and are latent until something wires findings into a buffer.
    #
    # == Promotion is per-finding, and the gesture is an EDIT
    #
    # Joel's ruling: a posted comment is his responsibility and triaging it is
    # his obligation, so there is no bulk accept. {#edit} makes one finding the
    # human's; ignoring it drops it, since only {#submittable} is offered for
    # submission and an unedited finding is never in it. An edit to the finding's
    # own words still promotes -- agreeing verbatim is a gesture the human made,
    # and refusing it would leave a finding he deliberately kept with no way to
    # keep it.
    #
    # Promotion state is not a vocabulary and is not stored as one: it IS the
    # human's text, held under the finding's address, so there is no state field
    # free to disagree with the words. The one closed set here -- the critique's
    # BLOCKER/SHOULD-FIX/NIT ranks -- is not restated either; {KINDS} DERIVES it
    # from the two maps T17 already ships. Neither belongs in
    # `review/vocabulary.rb`, for {Placement}'s reason and one of its own: no
    # record journals a rank or a promotion, and a set in that file would have to
    # be edited to delete this capability.
    #
    # == Deletable
    #
    # Removable by deleting this file and its `prefill/` directory, its spec, its
    # unit-index line in `lib/lain/review.rb`,
    # `prompt/templates/skill/critique/sidecar.md`, and the two lines of that
    # skill's `skill.md` that declare and render the hole.
    # Nothing outside those names {Prefill}. Deleting T17's
    # {Projection::Diagnostics} forces deleting this too: {KINDS} derives from
    # its maps while this class body runs.
    class Prefill
      include Enumerable

      # A sidecar line that cannot be read as a finding, or a finding written
      # twice. ALWAYS names WHERE -- the line number for a line that could not be
      # read, BOTH line numbers for a repeat -- because skipping is the defect
      # octo shipped (`gh/init.lua:170-182` turned a crash into a quietly
      # truncated list) and a refusal that cannot say where sends the human
      # grepping a 200-line file for the difference between two identical
      # sentences.
      class Malformed < Error; end

      # A rank outside the three the critique skill ranks by.
      class UnknownRank < Error; end

      # An id naming no finding in this sidecar.
      class UnknownFinding < Error; end

      # A finding, or a promotion, with nothing in it.
      class Blank < Error; end

      # A finding asked to render before the editor placed it. Refused here
      # rather than sent as a null mark: the lua half would then name a mark
      # nobody chose, and the slip is Ruby's.
      class Unplaced < Error; end

      # Two annotation kinds sharing one severity tier, which would make the
      # rank-to-kind derivation ambiguous. See {.invert}.
      class AmbiguousTier < Error; end

      # Where a finding renders, and what nvim prints beside it. Both differ
      # from the human's own ({Projection::Diagnostics::DEFAULT_NAMESPACE},
      # {Projection::Diagnostics::DEFAULT_SOURCE}) -- that difference is the
      # whole mechanism by which a suggestion is visibly a suggestion.
      NAMESPACE = "lain_review_findings"
      SOURCE = "critique"

      # Hashed and versioned like every other address this tier journals
      # ({Review::Keying}); a finding's id is its CONTENT, so two loads of one
      # sidecar agree and a promotion survives a reload.
      DIGEST_SCHEME = "review-finding-v1"

      # The whole singleton in one place, ahead of the derived constants below
      # because {.invert} runs while this class body does.
      class << self
        # Read a whole sidecar. Every line is a finding; one that cannot be read
        # refuses the LOT, naming its number (see {Malformed}). An empty sidecar
        # is a critique that found nothing, and loads to no findings.
        #
        # @param sidecar [String] NDJSON
        # @return [Prefill]
        # @raise [Malformed]
        def load(sidecar) = new(findings: Sidecar.read(sidecar))

        # The lua argument list for these findings, in the findings' namespace.
        #
        # @param buffer [Integer]
        # @param findings [Enumerable<Finding>] every one of them placed
        # @return [Array]
        # @raise [Unplaced] naming the findings with no extmark
        def arguments(buffer, findings) = PROJECTION.arguments(buffer, anchored!(findings))

        # Severity => kind, from kind => severity.
        #
        # A plain `to_h` inversion would DROP a kind that shares a tier with
        # another and hand every rank on that tier the survivor, silently. That
        # is the one way {KINDS}' derivation could go quietly wrong, so it is
        # refused instead, naming both kinds.
        #
        # @param severities [Hash{String => String}] kind => nvim severity name
        # @return [Hash{String => String}] frozen
        # @raise [AmbiguousTier]
        def invert(severities)
          severities.each_with_object({}) do |(kind, severity), kinds|
            ambiguous!(severity, kinds[severity], kind) if kinds.key?(severity)
            kinds[severity] = kind
          end.freeze
        end

        # @return [Hash{String => Finding}] frozen, keyed by content address
        # @raise [Malformed] if two findings share one address
        def index(findings)
          findings.each_with_object({}) do |finding, by_id|
            repeated!(finding) unless by_id[finding.id].nil?
            by_id[finding.id] = finding
          end.freeze
        end

        # The one refusal with two callers, so there is one message rather than
        # two free to disagree: {Sidecar} knows which LINES a finding was written
        # on and says both, {.index} catches the same condition for findings a
        # caller built in memory, where there are no line numbers to give.
        # {Malformed}'s "always names where", at whatever resolution the input has.
        #
        # @raise [Malformed]
        def repeated!(finding, first = nil, second = nil)
          where = first.nil? ? "twice" : "on lines #{first} and #{second}"
          raise Malformed, "this sidecar repeats the finding #{finding} #{where} -- the two share one " \
                           "address, so an edit could only ever promote one of them"
        end

        # @return [String] the rank, in the critique skill's own spelling
        # @raise [UnknownRank] naming it and the ranks that exist
        def rank!(value)
          rank = Wire.token(value)
          return rank if KINDS.key?(rank)

          raise UnknownRank, "rank must be one of #{KINDS.keys.join("/")}, got #{value.inspect} -- " \
                             "the critique skill ranks every finding by one of those three"
        end

        # A human's words, or a critique's. Blank is refused rather than kept:
        # {AnnotationPlaced} would refuse it later anyway, and a promotion with
        # nothing in it is an ambiguous gesture -- a finding is dropped by being
        # IGNORED.
        #
        # @return [String] interned, never stripped ({Wire.text}'s rule)
        # @raise [Blank]
        def words!(value)
          text = Anchor.string!(value, field: "text")
          return -text unless text.strip.empty?

          raise Blank, "text must carry what was found, got #{value.inspect} -- a finding is dropped by " \
                       "being ignored, never by being blanked"
        end

        # @return [Integer] the extmark id
        # @raise [Unplaced]
        def extmark!(value)
          return value if value.is_a?(Integer)

          raise Unplaced, "a finding is placed at the extmark id the editor answered with, got #{value.inspect}"
        end

        # @return [Integer, nil] nil for a finding nobody has placed yet
        def mark!(value) = value.nil? ? nil : extmark!(value)

        private

        def ambiguous!(severity, held, kind)
          raise AmbiguousTier, "#{severity} is the tier of both #{held.inspect} and #{kind.inspect}, so a " \
                               "rank on that tier could be promoted as either"
        end

        def anchored!(findings)
          unplaced = findings.reject(&:placed?)
          return findings if unplaced.empty?

          raise Unplaced, "#{unplaced.join(", ")} have no extmark -- a diagnostic's line comes from its " \
                          "mark, so only the editor that placed one may say where a finding renders"
        end
      end

      # The rank a critique writes, to the annotation kind a human's note would
      # carry -- DERIVED through the two maps T17 already ships rather than
      # restated as a third. A rank keeps its tier: whatever severity
      # {Projection::Diagnostics::RANKS} puts BLOCKER on, this hands back the
      # kind {Projection::Diagnostics::SEVERITIES} puts there.
      #
      # Restating it would be the trap `review/vocabulary.rb` documents: two
      # independent declarations of one correspondence are free to disagree, and
      # the disagreement is invisible -- a promoted finding would simply render
      # at a different severity than it did as a suggestion.
      #
      # What the derivation actually catches, stated precisely because the loose
      # version ("any new rank fails loudly") is half false: a kind DROPPED,
      # RENAMED or added to {Review::ANNOTATION_KINDS}, and a rank on a tier no
      # kind holds, each raise while this class body runs. A fourth RANK on an
      # existing tier loads clean and takes that tier's kind -- which is the
      # intended answer, not an escape: the tier is the correspondence, and a
      # rank that names one is ranked.
      KINDS_BY_SEVERITY = invert(Projection::Diagnostics::SEVERITIES)
      private_constant :KINDS_BY_SEVERITY

      KINDS = Projection::Diagnostics::RANKS
              .transform_values { |severity| KINDS_BY_SEVERITY.fetch(severity) }.freeze

      # The findings' own diagnostic layer. One instance: {Projection::Diagnostics}
      # freezes itself and holds nothing per render.
      PROJECTION = Projection::Diagnostics.new(namespace: NAMESPACE, source: SOURCE)

      # @return [Array<Finding>] in the order the critique wrote them
      attr_reader :findings

      # Every promotion is RE-JUDGED here rather than carried, and that is what
      # makes {#edit}'s guarantees properties of the object instead of properties
      # of one method: this constructor is reachable directly, and a promotion
      # under an id this sidecar does not hold, or with nothing in it, is exactly
      # what {#edit} refuses.
      def initialize(findings:, promotions: {})
        @findings = findings.to_a.freeze
        @by_id = self.class.index(@findings)
        @promotions = promotions.to_h { |id, text| [fetch(id).id, self.class.words!(text)] }.freeze
        freeze
      end

      def each(&block) = @findings.each(&block)

      # @param id [String] a finding's content address
      # @return [Finding]
      # @raise [UnknownFinding]
      def fetch(id)
        @by_id.fetch(-id.to_s) do
          raise UnknownFinding, "#{id.inspect} is not a finding in this sidecar, which holds #{@findings.size}"
        end
      end

      # @raise [UnknownFinding] rather than answering false for an id nobody
      #   holds -- "not promoted" and "not here" are different facts
      def promoted?(id) = @promotions.key?(fetch(id).id)

      # Make one finding the human's own. Per-finding by construction: there is
      # no gesture here that touches a second one.
      #
      # @param id [String] the finding being taken over
      # @param text [String] his words, which replace the critique's
      # @return [Prefill] a new one; this object is unchanged
      # @raise [UnknownFinding]
      # @raise [Blank]
      def edit(id, text)
        self.class.new(findings: @findings, promotions: @promotions.merge(fetch(id).id => text))
      end

      # Give one finding the extmark the editor answered with.
      #
      # Here rather than on the caller because this object already owns the id
      # index. Without it every caller keeps a second map from id to mark beside
      # the prefill -- two records of one position, free to disagree, and the
      # second one has to be rebuilt by hand after every promotion.
      #
      # @param id [String] the finding that was placed
      # @param mark [Integer] the extmark id
      # @return [Prefill] a new one; this object is unchanged
      # @raise [UnknownFinding]
      # @raise [Unplaced]
      def place(id, mark)
        placed = fetch(id).at(mark)
        self.class.new(findings: @findings.map { |finding| finding.id == placed.id ? placed : finding },
                       promotions: @promotions)
      end

      # @return [Array<Promoted>] what the human has taken responsibility for --
      #   the ONLY thing this object offers for submission
      def submittable
        @findings.select { |finding| @promotions.key?(finding.id) }
                 .map { |finding| Promoted.new(origin: finding, text: @promotions.fetch(finding.id)) }.freeze
      end

      # @return [Array<Finding>] still suggestions: what the findings' namespace
      #   should be showing
      def unpromoted = @findings.reject { |finding| @promotions.key?(finding.id) }.freeze
    end
  end
end

# The values a sidecar carries, in their own file: reached from method bodies
# only, so this placement is free (`session.rb`'s rule).
require_relative "prefill/finding"
require_relative "prefill/sidecar"
