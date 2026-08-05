# frozen_string_literal: true

module Lain
  module Review
    # A session's annotations, posted back to GitHub as ONE batched pull request
    # review.
    #
    # == The anchor IS GitHub's model, so nothing is translated
    #
    # `(path, side, line)` -- what {Anchor} has held since T1 -- is exactly the
    # modern review-comment model, plus `start_line`/`start_side` for a range and
    # one top-level `commit_id`. Both surveyed projects converged on it
    # independently (research §4.6). The only translation is the SPELLING of the
    # side, and that is a wire detail; see {SIDES}.
    #
    # `position` is NOT modelled, at all. It is an offset into the diff AS
    # SERVED, so it breaks under pagination and re-hunking, and octo's
    # hand-computed version of it (`position + offset - 1`) has zero test
    # coverage in that project. Not modelling it also removes the refusal octo
    # needs only because the legacy API has no range concept.
    #
    # == Validate first, because two checks GitHub enforces are easy to skip
    #
    # tuicr skips both and takes the 422: a range must sit within ONE hunk, and
    # the path must be present in the diff. Every check here runs before the
    # executor is touched, which is also what makes "no subprocess was spawned"
    # a fact about the code rather than about timing.
    #
    # == One unambiguous reason per rejection
    #
    # tuicr's `MixedSideRange` fires from three structurally different causes and
    # shows one string for all of them -- and its single-line and range paths
    # disagree about what a valid old-side line even is. {REASONS} is one
    # sentence per cause, and the spec pins that no two of them are equal or a
    # substring of one another.
    #
    # == Degrade a position, refuse a span
    #
    # An unmappable comment becomes a bullet under {UNPLACED_HEADING} rather than
    # being dropped -- the best idea in either surveyed project. That works
    # because a bullet keeps everything a single position had: the words, the
    # path, the line, the revision.
    #
    # A RANGE has one thing more, and no bullet has anywhere to put it. Narrowing
    # it to a single line (which tuicr does, silently) or flattening it to prose
    # both report something other than what the human selected, so a range that
    # cannot be placed raises instead.
    #
    # The rule turns on the COMMENT, never on the reason, and the distinction is
    # not academic: a range on a path the diff does not have is refused, while
    # the same note at a single position on that same path degrades. `unknown_path`
    # therefore appears on both sides, and so do `revision_moved` and
    # `no_such_line`. Three of the seven reasons ({REASONS}) can only ever arise
    # on a range and so only ever refuse, but that is a consequence of what they
    # check, not a second rule. {Rejection#range?} is the whole of it -- a reason
    # whitelist would be a second copy of a decision this object takes once, free
    # to disagree with it.
    #
    # == Nothing is saved here, because nothing had to be
    #
    # tuicr writes the session to disk before the network call so a lost round
    # trip costs nothing. Lain gets the same property for free and earlier:
    # {Session#annotate} journals each note as it is placed, so by the time this
    # object exists every annotation is already on the journal. This object then
    # reads and never writes -- a refused submit leaves the session byte for byte
    # as it was, and a resumed one rebuilds from the same lines.
    #
    # There is no retry, and that is deliberate: a batched review POST is not
    # idempotent. A refusal comes back as a {Forge::Gh::Answer} for a caller to
    # decide about.
    class Submit
      # A comment names a range GitHub cannot place. Raised before anything is
      # sent, naming every such comment.
      class Refused < Error; end

      # A review with no placeable comment and no words. GitHub refuses it too;
      # refusing here says which review, before a round trip.
      class Nothing < Error; end

      # GitHub's own spelling of a diff side.
      #
      # This is a WIRE DETAIL and deliberately not a member of
      # `Review::VOCABULARY`. That file holds the sets a JOURNALED record is
      # judged against; `LEFT`/`RIGHT` is never journaled, never compared against
      # a record, and belongs to one remote's API -- the same reading
      # {Review::FILE_STATUSES}' own doc reaches when it declines to force
      # GitHub's `removed`/`copied`/`changed` onto the local set.
      #
      # The DOMAIN it maps from is the vocabulary, though, so {SIDES} is derived
      # from {Review::SIDES} with `fetch` rather than restated: a member added
      # there and not here raises at load, instead of quietly acquiring no
      # GitHub spelling.
      GITHUB_SIDES = { "old" => "LEFT", "new" => "RIGHT" }.freeze

      # The Symbol projection an {Anchor}'s side is spelled in, mapped to
      # GitHub's word for it.
      SIDES = Review::SIDES.to_h { |name| [name.to_sym, GITHUB_SIDES.fetch(name)] }.freeze

      # GitHub's review `event`, per {Review::VERDICTS} member. Derived with
      # `fetch` for {SIDES}' reason -- and the one-member vocabulary is not this
      # object's to widen (research open question 3).
      GITHUB_EVENTS = { "approve" => "APPROVE" }.freeze

      EVENTS = Review::VERDICTS.to_h { |name| [name, GITHUB_EVENTS.fetch(name)] }.freeze

      # What a review with no verdict is. GitHub takes exactly one event per
      # review and a round that concluded nothing has still said something, so
      # the comments arrive as remarks rather than as a judgement nobody made.
      NO_VERDICT_EVENT = "COMMENT"

      # The heading unplaceable comments land under, in the review body.
      UNPLACED_HEADING = "## Unplaced comments"

      # Why one comment could not be placed, one sentence each.
      #
      # The keys double as the predicate names {Placer} dispatches on, so a
      # reason with no check raises `NoMethodError` at the dispatch. The reverse
      # -- a PREDICATE with no reason -- is silent: nothing dispatches to it and
      # it simply never runs, which is a check that looks present and is not.
      # That asymmetry is why the spec asserts the two sets equal rather than
      # trusting the dispatch to catch both directions; an earlier draft of this
      # comment claimed it caught both, and an orphan predicate went unnoticed
      # under it.
      #
      # Their ORDER is the priority: the first true one is the reason reported,
      # so the more specific fact has to come first.
      REASONS = {
        unknown_path: "the diff being submitted against shows no such file on that side",
        revision_moved: "authored against a revision this submission is not for",
        mixed_side_range: "the range's two ends are on different sides of the diff",
        range_inverted: "the range does not begin before it ends",
        no_such_line: "that line is not one the diff shows on that side",
        no_such_start_line: "the range begins at a line the diff does not show on that side",
        range_spans_hunks: "the range's two ends are in different hunks"
      }.freeze

      Comment = Data.define(:path, :side, :line, :start_line, :start_side, :body, :kind, :revision)

      # One comment as GitHub takes it, built from one {AnnotationPlaced}.
      #
      # `revision` rides along because it is what makes §4.6's live tuicr defect
      # detectable: there, comments are validated against the full-range diff and
      # submitted against a narrowed `commit_id`, so the anchors were checked
      # against one diff and posted against another. T13 put the revision on the
      # record precisely so "which diff did the human annotate" is a fact rather
      # than an implication of whatever is on screen.
      #
      # Reopened rather than folded into the `Data.define` block: {SIDES} written
      # inside that block would resolve against `Lain::Review`, not against this
      # class (the trap {Request::SYSTEM_PREFIX} records).
      class Comment
        # @param annotation [Review::AnnotationPlaced]
        # @param start_line [Integer, nil] the first line of a range; nil for a
        #   single position
        # @param start_side [Symbol, String, nil] defaults to the annotation's
        #   own side, because a range across sides is a thing to REFUSE by name
        #   rather than a thing to spell by hand
        # @return [Comment]
        def self.of(annotation, start_line: nil, start_side: nil)
          new(path: annotation.path, side: annotation.side, line: annotation.line, start_line:,
              start_side: start_line && (start_side || annotation.side), body: annotation.text,
              kind: annotation.kind, revision: annotation.revision)
        end

        def initialize(path:, side:, line:, body:, kind:, revision:, start_line: nil, start_side: nil)
          super(path: -path.to_s, side: Anchor.side!(side), line: Anchor.line!(line),
                start_line: start_line && Anchor.line!(start_line),
                start_side: start_side && Anchor.side!(start_side),
                body: -body.to_s, kind: -kind.to_s, revision: -revision.to_s)
        end

        def range? = !start_line.nil?

        # `compact` rather than a branch, and it is the claim as well as the
        # style: an absent range is a field GitHub never sees, not a field
        # carrying null. There is no `position` here and no place to put one.
        #
        # @return [Hash]
        def payload
          { "path" => path, "line" => line, "side" => SIDES.fetch(side), "body" => body,
            "start_line" => start_line, "start_side" => start_side && SIDES.fetch(start_side) }.compact
        end

        def span = range? ? "#{start_line}-#{line}" : line.to_s

        def to_s = "#{path}:#{span} (#{side})"
      end

      Placed = Data.define(:comment) do
        def placed? = true
      end

      Rejection = Data.define(:comment, :reason)

      # One comment the diff cannot place, and the single reason why.
      #
      # Reopened for {REASONS}, which a `Data.define` block could not resolve.
      class Rejection
        def placed? = false

        # Whether this rejection costs a SPAN rather than a position, which is
        # what decides between degrading and refusing -- and it asks the COMMENT,
        # never the reason. The same `unknown_path` degrades at a single position
        # and refuses on a range, because what is unrecoverable is the span, not
        # the cause. See the class doc.
        def range? = comment.range?

        def explanation = REASONS.fetch(reason)

        # tuicr's own form (`- [ISSUE] src/lib.rs: kaboom`), plus the revision,
        # because a note that could not be placed is exactly the one whose
        # provenance a reader needs.
        def bullet
          "- [#{comment.kind}] #{comment} @ #{comment.revision[0, 7]} -- #{comment.body} (#{explanation})"
        end

        def to_s = "#{comment} -- #{explanation}"
      end

      # Whether a comment names a position the diff GitHub is serving actually
      # has, and if not, the one reason it does not.
      #
      # Everything is read through {Changeset}'s public answers -- `#files` for
      # the hunks and `#each_anchor` for what a LINE is on a side. Re-deriving
      # the origin-marker rules here would be a second walk free to disagree with
      # the one that produced the anchors in the first place, which is the trap
      # {Review::SIDES}' own doc describes one level up.
      class Placer
        # @param changeset [Review::Changeset] the whole, unfiltered changeset
        def initialize(changeset)
          @changeset = changeset
          @index = {}
        end

        # @param comment [Comment]
        # @return [Placed, Rejection]
        def place(comment)
          reason = REASONS.keys.find { |name| send(:"#{name}?", comment) }
          reason.nil? ? Placed.new(comment:) : Rejection.new(comment:, reason:)
        end

        private

        def unknown_path?(comment) = !index(comment.side).key?(comment.path)

        # The revision the anchor was authored against must be the one this side
        # of the changeset rests on -- the head for the new side, the merge base
        # for the old one. Not "the commit_id", which is only the new side's.
        def revision_moved?(comment) = comment.revision != revision_of(comment.side)

        def mixed_side_range?(comment) = comment.range? && comment.start_side != comment.side

        # `>=` and not `>`: GitHub requires a multi-line comment's start to be
        # strictly before its end, and a range of one line is a single position
        # spelled the long way rather than a range.
        def range_inverted?(comment) = comment.range? && comment.start_line >= comment.line

        def no_such_line?(comment) = hunk_at(comment, comment.line).nil?

        def no_such_start_line?(comment) = comment.range? && hunk_at(comment, comment.start_line).nil?

        # Reached only once both ends are known to be real lines, so two nils
        # cannot compare equal here and read as one hunk.
        def range_spans_hunks?(comment)
          comment.range? && hunk_at(comment, comment.start_line) != hunk_at(comment, comment.line)
        end

        def hunk_at(comment, line) = index(comment.side).dig(comment.path, line)

        def revision_of(side) = side == :old ? @changeset.base_ref : @changeset.head_ref

        # path => line => the hunk that shows it, for one side. Memoized per
        # side; a changeset does not change under a submission.
        def index(side) = @index[side] ||= build(side)

        # The anchors decide WHICH lines exist; the hunk spans decide which hunk
        # each one belongs to. Both come from the same parse, so the two cannot
        # be built from different readings of the diff.
        def build(side)
          spans = spans_of(side)
          @changeset.each_anchor(side:).with_object({}) do |anchor, index|
            found = spans.fetch(anchor.path, []).find { |_hunk, span| span.cover?(anchor.line) }
            (index[anchor.path] ||= {})[anchor.line] = found&.first
          end
        end

        # Keyed by the SIDE-SPECIFIC path, which is what an anchor carries: an
        # old-side anchor on a renamed file names the old path, and indexing it
        # under the file's identity path would report every such comment as
        # naming a file the diff does not have.
        def spans_of(side)
          @changeset.files.each_with_object({}) do |file, by_path|
            path = side == :old ? file.old_path : file.new_path
            by_path[path] = file.hunks.map { |hunk| [hunk, span_of(hunk, side)] } if path
          end
        end

        def span_of(hunk, side)
          start, count = side == :old ? [hunk.old_start, hunk.old_count] : [hunk.new_start, hunk.new_count]
          start...(start + count)
        end
      end

      # The whole review as one payload: what placed, what did not, and the body
      # that carries the difference.
      class Draft
        # @param comments [Enumerable<Comment>]
        # @param placer [Placer]
        # @param commit_id [String] the revision the review is submitted against
        # @param event [String] one of {EVENTS}' values, or {NO_VERDICT_EVENT}
        # @param summary [String] the human's own words for the review as a whole
        def initialize(comments:, placer:, commit_id:, event:, summary:)
          @placed, @rejected = comments.map { |comment| placer.place(comment) }.partition(&:placed?)
          @commit_id = commit_id
          @event = event
          @summary = summary
        end

        attr_reader :placed, :rejected

        # @return [Array<Rejection>] the ones that cost a span rather than a
        #   position, which is what a submission stops for
        def unsubmittable = rejected.select(&:range?)

        # @return [Boolean] whether GitHub would be asked to record nothing
        def empty? = placed.empty? && body.empty?

        # @return [Hash] exactly what goes on the wire
        def payload
          { "commit_id" => @commit_id, "event" => @event, "body" => body,
            "comments" => placed.map { |placement| placement.comment.payload } }
        end

        # @return [String] the summary, then the degraded comments under their
        #   heading; either half alone when there is only one
        def body = [@summary, unplaced].reject(&:empty?).join("\n\n")

        private

        def unplaced
          rejected.empty? ? "" : [UNPLACED_HEADING, *rejected.map(&:bullet)].join("\n")
        end
      end

      # Every annotation this session holds, as single-position comments. A range
      # has no representation on {AnnotationPlaced} -- it is a gesture a surface
      # makes -- so a caller with one builds its {Comment} and uses {.new}.
      #
      # @param session [Review::Session]
      # @param executor [#submit_review] {Forge::Gh}, {Forge::Gh::Recorded} or
      #   {Forge::Journaled} over either
      # @param number [Integer, String] the pull request
      # @return [Submit]
      def self.for(session:, executor:, number:)
        new(session:, executor:, number:, comments: session.annotations.map { |placed| Comment.of(placed) })
      end

      # @param session [Review::Session] the round whose changeset every comment
      #   is validated against, and which this object only ever READS
      # @param executor [#submit_review] see {.for}
      # @param number [Integer, String] the pull request
      # @param comments [Enumerable<Comment>] what to place; see {.for}
      def initialize(session:, executor:, number:, comments:)
        @session = session
        @executor = executor
        @number = number
        @comments = comments.to_a.freeze
        freeze
      end

      # Build, validate, and send -- in that order, so nothing reaches a
      # subprocess that has not already been checked against the diff.
      #
      # @param body [String] the human's own summary of the review
      # @return [Forge::Gh::Answer] the executor's own answer, unchanged: a
      #   refusal is a value at this tier, and a batched review POST is not
      #   idempotent, so what to do about one is the caller's decision
      # @raise [Refused] if any comment names a range that cannot be placed
      # @raise [Nothing] if the review would say nothing at all
      def call(body: "")
        draft = draft(summary: body.to_s)
        refuse_unplaceable_ranges!(draft)
        raise Nothing, nothing_to_say if draft.empty?

        @executor.submit_review(number: @number, review: draft.payload)
      end

      private

      def draft(summary:)
        Draft.new(comments: @comments, placer: Placer.new(@session.changeset), summary:,
                  commit_id: @session.changeset.head_ref, event:)
      end

      def event = @session.verdict.empty? ? NO_VERDICT_EVENT : EVENTS.fetch(@session.verdict)

      def refuse_unplaceable_ranges!(draft)
        stopped = draft.unsubmittable
        return if stopped.empty?

        raise Refused, "#{stopped.size} of #{@comments.size} comments name a range GitHub cannot place, and " \
                       "a range narrowed to one line or flattened into the body is not the one the human " \
                       "selected -- #{stopped.join("; ")}"
      end

      def nothing_to_say
        "this review would carry no comment and no words, so there is nothing for GitHub to record -- " \
          "annotate something, or write a summary body"
      end
    end
  end
end
