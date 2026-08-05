# frozen_string_literal: true

module Lain
  module Review
    # The review AGGREGATE: one changeset, the marks and notes left on it, and
    # the verdict that closes it -- rebuildable from the journal, so a chat
    # restarted mid-review resumes rather than losing everything a human did
    # (octo#118 and octo#980 are both this problem, unsolved).
    #
    # It is the only object holding both halves of a review, which is why two
    # things that look like they belong elsewhere are here and two that look
    # like they belong here are not.
    #
    # == It holds the join no other object can make
    #
    # {MarkedChangeset} is built here because a {Changeset} knows structure and
    # nothing about review state, and {Marks} knows review state and nothing
    # about files. See its own doc; every surface's `present` takes one.
    #
    # == The presented SCOPE is view state, and is not held
    #
    # {#present} takes the scope as an argument and forgets it. Which of
    # {Review::SCOPES} is on screen belongs to whoever is drawing -- "the surface
    # holds no review state" is right about annotations and marks and wrong
    # about that. It is still validated here, because this is the one place
    # every surface is reached through, and a typo'd scope must fail loudly
    # rather than fall through to whichever branch a bare `==` left as default.
    #
    # == Admissibility is a POLICY, injected
    #
    # {Verdict::Policy} decides whether a verdict may stand; this object only
    # asks. Its interaction with the `deferred` gate is an open question, and a
    # rule you cannot swap is a rule you cannot experiment with on a bench.
    #
    # == A verdict is PUSHED, never PULLED
    #
    # Nothing here calls `surface.verdict`. A decision arrives as a gesture
    # reaching {#submit}, the same way a mark or a note does, so the `nil` that
    # {Surface::Null#verdict} answers never reaches this object and no guard is
    # needed for it. {#verdict} in turn answers {Verdict::None} rather than nil,
    # so no CALLER nil-checks either -- which is what that comment at
    # `Surface::Null#verdict` asked this card to settle.
    #
    # == Annotations are round-scoped
    #
    # Produced, consumed, then historical. Nothing re-anchors a note onto a
    # later round -- which is precisely what lets lain skip the cross-round
    # re-anchoring all three surveyed projects punt on. {Replay} says how a
    # round is bounded.
    #
    # == Every presentation is size-bounded, because this is where every one passes
    #
    # {Bounds} is injected and {#present} is its ONLY caller in the tree
    # (`spec/lain/review/bounds_spec.rb` pins that count mechanically). It used
    # to be called from {Lain::CLI::Review#present} instead, which bounded the
    # one text command that remembered to ask and left every editor surface
    # unguarded -- `/review` of an 800-file pull request drew all of it. The fix
    # was not a second caller: the guard belongs at the one place a surface is
    # reached, so "bounded" is a property of PRESENTING rather than of whichever
    # command happened to be written with it in mind.
    class Session
      # {.from_journal} was given a journal that opened no review here. Refused
      # rather than answered with an empty session: the two are indistinguishable
      # to a caller, and one of them means the wrong journal was handed in.
      class NotOpened < Error; end

      # A mark was submitted for a hunk key this changeset does not produce.
      # Journaling it would write a mark that no reconciliation can ever match
      # and that the next replay silently prunes -- {Marks::UnknownPath}'s
      # refusal, at the key granularity marks are actually recorded.
      class UnknownHunk < Error; end

      # A scope outside {Review::SCOPES}.
      class UnknownScope < Error; end

      # A second verdict over one round. The journal's reader cannot tell which
      # of two judgements stands, and inventing a rule (last wins? first?) is a
      # decision nobody took.
      class AlreadySettled < Error; end

      # Hashed, never merely prefixed -- {Hunk#key}'s lesson, for the same
      # forgery reason, and this address IS journaled.
      DIGEST_SCHEME = "review-changeset-v1"

      # The Symbol projection of {Review::SCOPES}, which is how a caller spells
      # one in process. Derived, not restated (`Anchor::SIDES`' rule).
      SCOPES = Review::SCOPES.map(&:to_sym).freeze

      # The changeset's content address, and what {ReviewVerdict} judges.
      #
      # Base, paths, statuses and hunk keys -- and deliberately NOT the head.
      # The head moves every time the author commits, and surviving that is the
      # entire purpose of {Hunk}'s content-addressed keys; an address that
      # included it would open a new round on every amend and throw away every
      # mark. The BASE is in it because {Marks} refuses to cross one at all, so
      # a base change is genuinely a different review.
      #
      # Statuses and paths are in it so a change no hunk can express -- a pure
      # rename, a mode change, a binary blob swapped -- still moves the address.
      #
      # @param changeset [Review::Changeset]
      # @return [String] scheme-prefixed hex digest
      def self.digest(changeset) = Keying.digest(DIGEST_SCHEME, digest_parts(changeset))

      # WHICH parts, in which order -- the only thing this object decides about
      # its own address. How they are framed and how the scheme is bound to them
      # belong to {Review::Keying}, where both properties have specs of their own
      # rather than a comment here claiming them.
      def self.digest_parts(changeset)
        keys = MarkedChangeset.keys_by_path(changeset)
        [changeset.base_ref,
         *changeset.files.flat_map { |file| [file.path, file.status.to_s, *keys.fetch(file.path, [])] }]
      end
      private_class_method :digest_parts

      # @param scope [Symbol, String] one of {SCOPES}
      # @return [Symbol]
      # @raise [UnknownScope] naming what was given
      def self.scope!(scope)
        candidate = scope.respond_to?(:to_sym) ? scope.to_sym : scope
        return candidate if SCOPES.include?(candidate)

        raise UnknownScope, "scope must be one of #{SCOPES.inspect}, got #{scope.inspect}"
      end

      # Begin a round. The head is journaled BEFORE the session exists --
      # {Epic::Review#open}'s order, and its invariant: nothing is ever held
      # without a record behind it, so a crash between the two loses a session
      # nobody could have resumed anyway rather than orphaning marks under a
      # round that was never opened.
      #
      # `source` is required and is NOT read off the changeset: a {Changeset}
      # holds its source privately and everything downstream reads four messages
      # without knowing which answered them ({Source}'s own premise). The
      # journal needs the name, so the caller that chose the source supplies it.
      #
      # @param changeset [Review::Changeset]
      # @param journal [#<<] where every record of this round lands
      # @param source [String] what produced the changeset
      # @param surface [#present, #annotate, #mark] where it is drawn
      # @param policy [Verdict::Policy] admissibility, injected
      # @param bounds [Bounds] the sizes past which {#present} refuses
      # @return [Session]
      def self.open(changeset:, journal:, source:, surface: Surface::Null.new,
                    policy: Verdict::Policy.default, bounds: Bounds.new)
        opened = ChangesetOpened.new(source:, base_ref: changeset.base_ref,
                                     head_ref: changeset.head_ref, digest: digest(changeset))
        journal << opened
        new(changeset:, journal:, surface:, policy:, opened:, bounds:)
      end

      # Resume the last round in `entries`, against the changeset as it stands
      # NOW -- which may not be the one that was opened, because the author has
      # gone on working. {Marks#reconcile} prunes the keys the regenerated diff
      # no longer produces, and raises {Marks::BaseMismatch} if the base moved,
      # which is the one change a mark set may not survive.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records
      # @param changeset [Review::Changeset] the changeset as it stands now
      # @param journal [#<<] where records of the resumed round go on landing
      # @param surface [#present, #annotate, #mark] where it is drawn
      # @param policy [Verdict::Policy] admissibility, injected
      # @param bounds [Bounds] the sizes past which {#present} refuses -- a
      #   resume is where a diff has had time to GROW, so it is bounded on
      #   exactly the same terms as a round this process opened
      # @return [Session]
      # @raise [NotOpened] if no round was ever opened in `entries`
      # @raise [Marks::BaseMismatch] if the round was opened against another base
      def self.from_journal(entries, changeset:, journal:, surface: Surface::Null.new,
                            policy: Verdict::Policy.default, bounds: Bounds.new)
        replay = Replay.new(entries)
        if replay.opened.nil?
          raise NotOpened, "these journal entries record no changeset_opened, so there is no round to " \
                           "resume -- Session.open begins one"
        end

        new(changeset:, journal:, surface:, policy:, opened: replay.opened, bounds:, replay:)
      end

      # @return [Review::Changeset] the whole, unfiltered changeset -- the only
      #   thing {Marks#reconcile} may be handed
      attr_reader :changeset

      # @return [Review::Marks]
      attr_reader :marks

      # @return [ChangesetOpened] the head of the round, as journaled
      attr_reader :opened

      # The judgement that closed this round, with the changeset it judged on
      # it -- {ReviewVerdict}, or {Verdict::None} when there is none.
      #
      # Kept beside {#verdict} rather than folded into it, because they answer
      # different questions and only one of them is renderable. `#verdict` is
      # the WORD, and its null renders as nothing; this is the RECORD, and
      # `changeset_digest` is the field {ReviewVerdict} makes mandatory
      # precisely so that a verdict read back is never a judgement of nothing.
      # A resumed session needs it: the diff may have moved on since, so "what
      # was approved" and "what is on screen" are different addresses.
      #
      # @return [ReviewVerdict, Verdict::None]
      attr_reader :judgement

      def initialize(changeset:, journal:, surface:, policy:, opened:, bounds:, replay: Replay.new([]))
        @changeset = changeset
        @journal = journal
        @surface = surface
        @policy = policy
        @opened = opened
        @bounds = bounds
        @marks = replay.marks(opened.base_ref).reconcile(changeset)
        @annotations = replay.annotations.dup
        @judgement = replay.judgement
      end
      private_class_method :new

      # @return [String] the changeset's content address, as it stands now --
      #   which is what a verdict judges, and not necessarily {#opened}'s digest
      def digest = @digest ||= self.class.digest(@changeset)

      # @return [String] what produced the changeset
      def source = @opened.source

      # Whether the diff has moved since this round was opened.
      #
      # This is what CONSUMES `opened.digest`, which the journal carried and
      # nothing here read -- a field with no reader is a field that quietly
      # stops being true. A resume is the case it exists for: the author goes on
      # working, {.from_journal} reconciles the marks against the changeset as
      # it stands NOW, and a surface that says nothing about the difference
      # shows a review of one diff over another. Both sides are content
      # addresses ({.digest}), so an amend that changed nothing answers false.
      #
      # @return [Boolean]
      def regenerated? = @opened.digest != digest

      # @return [Array<AnnotationPlaced>] this round's notes, oldest first
      def annotations = @annotations.dup.freeze

      # The word, never nil: {Verdict::None} answers `#empty?` and `#to_s` the
      # way a real verdict String does, so no caller type-tests and none
      # nil-checks. See the class doc.
      #
      # @return [String, Verdict::None]
      def verdict = @judgement.verdict

      # The join, rebuilt on demand rather than memoized: a mark changes it, and
      # a stale view is exactly the defect a marker exists to prevent.
      #
      # @return [MarkedChangeset]
      def marked = MarkedChangeset.of(@changeset, @marks, keys_by_path:)

      # The ceiling is checked on the RESOLVED scope, because `:commits` and
      # `:cumulative` bound differently and the refusal for one recommends the
      # other; and BEFORE the surface is told, because a refusal that has
      # already drawn is not one -- for an editor it is worse than none, since
      # the sidebar is up and the human believes they are looking at the whole
      # changeset.
      #
      # It RAISES rather than answering the port's refusal String. A String from
      # this method means "the surface did not take it" (`spec/support/
      # shared_examples/review_surface.rb`, law #5), and a ceiling is not that:
      # {Bounds} exists so that either the whole changeset is handled or nothing
      # is, which is a value no caller may read past.
      #
      # @param scope [Symbol, String] one of {SCOPES}
      # @return [Object] whatever the surface answers
      # @raise [UnknownScope]
      # @raise [Bounds::TooLarge] for a view past a ceiling at that scope
      def present(scope:)
        at = self.class.scope!(scope)
        @bounds.check_presentation!(@changeset, scope: at)
        @surface.present(marked, scope: at)
      end

      # Set one hunk's reviewed state.
      #
      # @param hunk_key [String] one of this changeset's own keys
      # @param state [String, Symbol] a member of {Review::MARK_STATES}
      # @return [self]
      # @raise [UnknownHunk] for a key this changeset does not produce
      # @raise [Marks::UnknownState] for a state outside the vocabulary
      def mark(hunk_key, state)
        key = Wire.token(hunk_key)
        refuse_unknown_hunk!(key)
        marked = HunkMarked.new(hunk_key: key, state: Marks.state!(state))
        @journal << marked
        @marks = @marks.mark(marked.hunk_key, marked.state)
        @surface.mark(marked.hunk_key, marked.state)
        self
      end

      # Place one note.
      #
      # `drifted` has no default, and that is {AnnotationPlaced}'s rule rather
      # than this method's taste: drift is a MEASUREMENT of `anchor_text`
      # against the document as it now reads, and a measurement nobody took is a
      # different fact from one that came back false. This object has no
      # document -- it holds a diff, not a working tree -- so it refuses to
      # guess and the caller that has the buffer supplies the answer
      # ({Epic::Review::Annotations.resolve} is that caller's shape).
      #
      # The revision recorded is the ANCHOR's, never the changeset's head: a
      # note placed while one commit is on screen was authored against that
      # commit, and an annotation authored against one diff and submitted
      # against another is a live defect in tuicr that only an on-record
      # revision makes detectable.
      #
      # @param anchor [Review::Anchor]
      # @param text [String] the human's own words
      # @param kind [String, Symbol] a member of {Review::ANNOTATION_KINDS}
      # @param drifted [Boolean] the measurement, taken by the caller
      # @return [AnnotationPlaced] the record, as journaled
      def annotate(anchor, text, kind:, drifted:)
        placed = AnnotationPlaced.new(id: anchor.id, path: anchor.path, side: anchor.side, line: anchor.line,
                                      anchor_text: anchor.anchor_text, text:, kind:, drifted:,
                                      revision: anchor.revision)
        @journal << placed
        @annotations << placed
        @surface.annotate(anchor, text, kind:)
        placed
      end

      # Close the round.
      #
      # The record is built FIRST, so the vocabulary is judged by the object
      # that owns it ({Review::VERDICTS}); the policy is asked SECOND, so a
      # refusal leaves no judgement on record; the journal is written LAST.
      #
      # @param verdict [String, Symbol] a member of {Review::VERDICTS}
      # @return [String] the verdict, in the vocabulary's own spelling
      # @raise [AlreadySettled] if this round already has one
      # @raise [Verdict::Policy::Incomplete] if the policy refuses
      def submit(verdict)
        refuse_second_verdict!
        judged = ReviewVerdict.new(verdict:, changeset_digest: digest)
        @policy.admit!(judged.verdict, changeset: @changeset, marks: @marks)
        @journal << judged
        @judgement = judged
        judged.verdict
      end

      private

      # Memoized: the changeset a session holds never changes, and this is a
      # blake3 pass over every hunk in it.
      def keys_by_path = @keys_by_path ||= MarkedChangeset.keys_by_path(@changeset)

      def hunk_keys = @hunk_keys ||= keys_by_path.values.flatten.to_set

      def refuse_unknown_hunk!(key)
        return if hunk_keys.include?(key)

        raise UnknownHunk, "#{key.inspect} is not a hunk key this changeset produces -- a mark under it " \
                           "could never be reconciled onto anything, and the next replay would prune it unread"
      end

      def refuse_second_verdict!
        return if verdict.empty?

        raise AlreadySettled, "this round was already judged #{verdict.inspect} -- a second verdict leaves a " \
                              "journal whose reader cannot tell which of the two stands"
      end
    end
  end
end

# Both are reached from method bodies only, so this placement is free; it reads
# in the order a reader meets them.
require_relative "session/marked_changeset"
require_relative "session/replay"
