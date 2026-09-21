# frozen_string_literal: true

require "monitor"

module Lain
  module Review
    # The review AGGREGATE: one changeset, the marks and notes left on it, and
    # the verdict that closes it -- rebuildable from the journal, so a chat
    # restarted mid-review resumes rather than losing everything a human did
    # (octo#118 and octo#980 are both this problem, unsolved).
    #
    # It is the only object holding both halves, which is why {MarkedChangeset}
    # is built here: a {Changeset} knows structure and nothing about review
    # state, and {Marks} knows review state and nothing about files.
    #
    # THE PRESENTED SCOPE IS VIEW STATE and is not held. {#present} takes it as
    # an argument and forgets it -- which of {Partition::STRATEGIES} is on screen
    # belongs to whoever is drawing, and "the surface holds no review state" is
    # right about annotations and marks and wrong about that. It is still
    # validated here, because this is the one place every surface is reached
    # through. Two refusals, kept apart deliberately; {Scope} is where the
    # reasoning for the split is written.
    #
    # ADMISSIBILITY IS A POLICY, injected. {Verdict::Policy} decides whether a
    # verdict may stand and this object only asks -- a rule you cannot swap is a
    # rule you cannot experiment with on a bench.
    #
    # A VERDICT IS PUSHED, NEVER PULLED. Nothing here calls `surface.verdict`; a
    # decision arrives as a gesture reaching {#submit}, so the `nil` that
    # {Surface::Null#verdict} answers never reaches this object. {#verdict} in
    # turn answers {Verdict::None} rather than nil, so no CALLER nil-checks
    # either.
    #
    # A ROUND ENDS ONCE, by a verdict or by a close, and the two arrive on
    # different threads -- `/review close` on the chat's, `:LainReviewVerdict`
    # on the editor's RPC thread. So each ending's guard, record and state are
    # one step under one lock, and the loser is refused in words.
    #
    # ANNOTATIONS ARE ROUND-SCOPED: produced, consumed, then historical. Nothing
    # re-anchors a note onto a later round, which is what lets lain skip the
    # cross-round re-anchoring all three surveyed projects punt on.
    #
    # EVERY PRESENTATION IS SIZE-BOUNDED, because this is where every one passes.
    # {Bounds} is injected and {#present} is its ONLY caller in the tree. It used
    # to be called from {Lain::CLI::Review#present}, which bounded the one text
    # command that remembered to ask and left every editor surface unguarded --
    # `/review` of an 800-file pull request drew all of it. The fix was not a
    # second caller: the guard belongs at the one place a surface is reached, so
    # "bounded" is a property of PRESENTING rather than of whichever command
    # happened to be written with it in mind.
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

      # A scope no {Partition::STRATEGIES} member declares.
      class UnknownScope < Error; end

      # A scope naming a real strategy that THIS source cannot be grouped by --
      # the commit walk over a source with no walk. Separate from
      # {UnknownScope} because the two are different mistakes: one is a typo,
      # the other is a grouping that exists and does not apply here, and
      # collapsing them would tell a human to check their spelling when their
      # spelling was right.
      class UnsupportedScope < Error; end

      # A second verdict over one round. The journal's reader cannot tell which
      # of two judgements stands, and inventing a rule (last wins? first?) is a
      # decision nobody took.
      class AlreadySettled < Error; end

      # A verdict, or a second close, over a round already let go without one.
      class Closed < Error; end

      # Every scope a caller may name, which is every strategy that registered.
      # Read off {Partition::STRATEGIES}' keys rather than restated, so
      # shipping a strategy is the whole of making it reachable -- that is the
      # property, and a literal list here is exactly what used to break it.
      SCOPES = Partition::STRATEGIES.keys.freeze

      # What a resumed chat says when it opens a round on a target the session
      # it resumed left open. Nothing is carried over, deliberately -- see the
      # class doc on round-scoped annotations -- so the sentence is the whole of
      # what that earlier round costs the human: they must not believe its notes
      # are on the sidebar they are reading.
      NOT_CARRIED_OVER = "%<target>s was still open in a session this chat resumed from -- this is a new " \
                         "round, and the notes and marks left there are not carried over; they stay on that " \
                         "session's journal"

      # The changeset's content address, and what {ReviewVerdict} judges.
      #
      # ASKED, not composed. This used to know what a changeset was made of --
      # base, paths, statuses, hunk keys -- which meant one method here had to
      # know what every KIND of source was made of, and a second kind could only
      # have been served by a type test. Now the object that HAS the parts
      # supplies them, and nothing on this path asks what it is holding.
      #
      # A diff source composes exactly what this method composed, so every
      # `/review` address is bit-identical across the change and every journalled
      # `changeset_digest` still joins.
      #
      # @param changeset [Review::Changeset]
      # @return [String] scheme-prefixed hex digest
      def self.digest(changeset) = changeset.identity.digest

      # The resolved scope's NAME -- {Scope.resolve}, kept reachable here because
      # this is what every caller outside the review tier already knows it by
      # (both CLI paths, and the flag enums their specs drive through it), and
      # because a Symbol is what they hand on.
      #
      # @param scope [Symbol, String] one of {SCOPES}
      # @return [Symbol]
      # @raise [UnknownScope]
      def self.scope!(scope) = Scope.resolve(scope).name

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
      # @param target [String, nil] what the human named, for {.left_open?}
      # @return [Session]
      def self.open(changeset:, journal:, source:, surface: Surface::Null.new,
                    policy: Verdict::Policy.default, bounds: Bounds.new, target: nil)
        opened = ChangesetOpened.new(source:, base_ref: changeset.base_ref,
                                     head_ref: changeset.head_ref, digest: digest(changeset), target:)
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

      # Whether the LAST round in `entries` was opened on `target` and is still
      # neither judged nor closed. The last round because it is the one a chat
      # still held when it stopped: opening a round replaces the one before it.
      # A round recorded before rounds named their target names none, so it
      # matches nothing.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records
      # @param target [String]
      # @return [Boolean]
      def self.left_open?(entries, target:)
        Replay.new(entries).open_on?(target)
      end

      # @return [Review::Changeset] the whole, unfiltered changeset -- the only
      #   thing {Marks#reconcile} may be handed
      attr_reader :changeset

      # @return [Review::Marks]
      attr_reader :marks

      # @return [ChangesetOpened] the head of the round, as journaled
      attr_reader :opened

      # The judgement that closed this round, with the changeset it judged on it
      # -- {ReviewVerdict}, or {Verdict::None} when there is none.
      #
      # Kept beside {#verdict} rather than folded into it, because they answer
      # different questions and only one is renderable. `#verdict` is the WORD,
      # and its null renders as nothing; this is the RECORD, whose
      # `changeset_digest` is what keeps a verdict read back from being a
      # judgement of nothing. A resumed session needs it: the diff may have moved
      # on, so "what was approved" and "what is on screen" are different
      # addresses.
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
        @closed = replay.closed?
        @ending = Monitor.new
        @recorded_digest = replay.digest(opened)
      end
      private_class_method :new

      # @return [String] the changeset's content address, as it stands now --
      #   which is what a verdict judges, and not necessarily {#opened}'s digest
      def digest = @digest ||= self.class.digest(@changeset)

      # @return [String] what produced the changeset
      def source = @opened.source

      # @return [Boolean] whether this round was let go without a verdict
      def closed? = @closed

      # Whether the changeset has moved UNDER this round -- a different question
      # from whether it has moved since the round opened, and the difference is
      # the whole of what accretion needs. This is what CONSUMES the digests the
      # journal carried and nothing here read; a field with no reader is a field
      # that quietly stops being true. Both sides are content addresses, so an
      # amend that changed nothing answers false.
      #
      # It reads the LAST digest put on record rather than the opened one, and
      # that is {#widen}'s doing: a widening is something the human asked for, so
      # a survey reporting itself regenerated the moment it grew would say the
      # ground had shifted when nothing had. For a changeset there are no
      # extension records at all, so last-recorded IS the opened digest.
      #
      # @return [Boolean]
      def regenerated? = @recorded_digest != digest

      # Grow this round to span more paths, keeping everything already marked.
      #
      # MUTATION, and chosen over rebuilding. {.from_journal} over the wider
      # corpus would replay through the only sanctioned constructor and could not
      # miss a field -- but a live review is HELD: {Handover} and
      # {Frontend::Neovim::ReviewView} hold this object, and a widening that
      # swapped the instance would strand them holding the round as it was.
      # Identity for the holders is the requirement; the inventory is its price,
      # and it is exactly three -- `@changeset`, `@marks` and the two digests, of
      # which only `@digest` is a memo. The memos this method used to invalidate
      # are gone: {#keys_by_path} and {#marked} are both deliberately
      # un-memoized.
      #
      # {Widening} owns the decision, the record and the ordering that keeps a
      # refusal off the journal. It re-reconciles, and over a lazily chunked
      # corpus that CHUNKS -- a mark set cannot name the paths it belongs to, so
      # a surviving mark is told from a stale one only by walking. A round with
      # nothing marked yet pays nothing.
      #
      # @param changeset [Review::Changeset] the whole, unfiltered changeset over
      #   the wider path set -- built by the caller, since a session holds no
      #   walk, no projection and no classifier to build one with
      # @return [CorpusExtended] the record, as journaled
      # @raise [AlreadySettled] if this round has been judged
      # @raise [NotWidened] for a changeset that drops a path or adds none
      # @raise [Marks::BaseMismatch] for a changeset from another base
      def widen(changeset)
        refuse_settled_widening!
        widened = Widening.new(from: @changeset, to: changeset).into(@journal, marks: @marks)
        @changeset = changeset
        @marks = widened.marks
        @digest = @recorded_digest = widened.record.digest
        widened.record
      end

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
      # The GROUPING is an argument because a marked changeset carries its
      # partitions, and a surface picks between the flat table and the grouped
      # one by the scope it is told. Built at one strategy and drawn at another,
      # `--scope by_directory` rendered the COMMIT walk under a directory heading.
      #
      # @param strategy [Partition::Strategy] how the files are grouped
      # @return [MarkedChangeset]
      def marked(strategy: MarkedChangeset::WALK) = MarkedChangeset.of(@changeset, @marks, keys_by_path:, strategy:)

      # {Scope#support!} runs BEFORE the ceiling, and the order is the point: the
      # ceiling walks the partitions, and that walk is what would die on the
      # missing message.
      #
      # The ceiling is checked on the RESOLVED scope, because `:commits` and
      # `:cumulative` bound differently and the refusal for one recommends the
      # other; and BEFORE the surface is told, because a refusal that has already
      # drawn is not one -- for an editor it is worse than none, since the
      # sidebar is up and the human believes they are looking at the whole
      # changeset.
      #
      # It RAISES rather than answering the port's refusal String. A String from
      # this method means "the surface did not take it", and a ceiling is not
      # that: {Bounds} exists so either the whole changeset is handled or nothing
      # is, which is a value no caller may read past.
      #
      # @param scope [Symbol, String] one of {SCOPES}
      # @return [Object] whatever the surface answers
      # @raise [UnknownScope]
      # @raise [UnsupportedScope] for a grouping this source cannot answer for
      # @raise [Bounds::TooLarge] for a view past a ceiling at that scope
      def present(scope:)
        at = Scope.resolve(scope)
        at.support!(@changeset, source:)
        @bounds.check_presentation!(@changeset, scope: at.name)
        @surface.present(marked(strategy: at.strategy), scope: at.name)
      end

      # Set one hunk's reviewed state -- {#mark_row} of one, so the two can
      # never drift: {#mark} used to carry its own copy of the validate,
      # journal and `@marks`-merge steps, and a panel measured that as a
      # SECOND place those three steps could disagree with {#mark_row}'s,
      # which is worse than the duplicate lines it cost to avoid.
      #
      # @param hunk_key [String] one of this changeset's own keys
      # @param state [String, Symbol] a member of {Review::MARK_STATES}
      # @return [self]
      # @raise [UnknownHunk] for a key this changeset does not produce
      # @raise [Marks::UnknownState] for a state outside the vocabulary
      def mark(hunk_key, state)
        mark_row([hunk_key], state) { |marked| @surface.mark(marked.hunk_key, marked.state) }
        self
      end

      # {#mark}'s batch: every key a whole ROW names, recorded together.
      # Validation, the journal record and the `@marks` merge are identical to
      # calling {#mark} once per key -- {#mark} is built ON this method for that
      # reason -- but the per-key `@surface.mark` notice is left to the CALLER: a
      # single hunk key carries no row name, so a batch that notified per key
      # would post N notices each naming a truncated content hash, which is both
      # wrong (a hash is not a row) and redundant.
      #
      # Yields each RECORD as it lands (not merely its key), so a caller can both
      # count how many landed before an unmarkable one raised -- {Handover#mark}
      # reports a row the session took only half of -- and read what state each
      # key landed at.
      #
      # @param hunk_keys [Enumerable<String>] every key the row names
      # @param state [String, Symbol] a member of {Review::MARK_STATES}
      # @yieldparam marked [HunkMarked] the record just journaled
      # @return [self, Enumerator] `self` when a block was given; otherwise an
      #   {Enumerator} over `[:mark_row, hunk_keys, state]` that does nothing
      #   until driven -- the block is genuinely optional, unlike {#mark}'s
      # @raise [UnknownHunk] for a key this changeset does not produce
      # @raise [Marks::UnknownState] for a state outside the vocabulary
      def mark_row(hunk_keys, state)
        return enum_for(:mark_row, hunk_keys, state) unless block_given?

        recorder = marking
        hunk_keys.each do |hunk_key|
          marked = recorder.call(hunk_key, state)
          @marks = @marks.mark(marked.hunk_key, marked.state)
          yield marked
        end
        self
      end

      # Place one note.
      #
      # `drifted` has no default, and that is {AnnotationPlaced}'s rule: drift is
      # a MEASUREMENT of `anchor_text` against the document as it now reads, and
      # a measurement nobody took is a different fact from one that came back
      # false. This object has no document -- it holds a diff, not a working tree
      # -- so it refuses to guess.
      #
      # The revision recorded is the ANCHOR's: the revision its evidence was read
      # at ({Changeset#anchor} -- the head for a new-side note, the base for an
      # old-side one), never the one the editor's buffer was stamped with. An
      # annotation submitted against a different diff stays detectable because
      # that revision is on the record.
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
      # The record is built FIRST, so the vocabulary is judged by the object that
      # owns it ({Review::VERDICTS}); the policy is asked SECOND, so a refusal
      # leaves no judgement on record; the journal is written LAST.
      #
      # THE SURFACE IS TOLD, from HERE rather than by whoever called: this is
      # {#mark}'s rail exactly, and it is the one place a verdict that landed can
      # be told from one a policy refused. Before it, the review's one TERMINAL
      # gesture was the only one that acknowledged nothing. It has to be a PUSH
      # and not a return value, because {Handover#wrote_verdict} answers `nil` for
      # "taken" -- its answer is what the editor's `:w` succeeds with.
      #
      # It goes LAST, after the judgement is on record, and through
      # {Surface.acknowledge} rather than straight at the surface, because "last"
      # alone does not make it unable to unmake the verdict -- an adapter that
      # RAISES still does. That guard lives at the port because it enforces the
      # port's own promise. The answer is discarded either way: a fact about the
      # editor, not about the round.
      #
      # THE NOTES GO TOO, and they are not decoration on the call: `blocker` is
      # the one {Review::ANNOTATION_KINDS} member documented as readable by a
      # verdict policy, and until it was passed here no policy could read it -- a
      # human's own "not this" was journaled, drawn as a marker, and refused
      # nothing. What counts as RESOLVED is the policy's answer
      # ({Verdict::Policy.unresolved}); this round only holds them.
      # @param verdict [String, Symbol] a member of {Review::VERDICTS}
      # @return [String] the verdict, in the vocabulary's own spelling
      # @raise [AlreadySettled] if this round already has one
      # @raise [Closed] if this round was let go without one
      # @raise [Verdict::Policy::Incomplete] if the policy refuses
      # @raise [Verdict::Policy::Blocked] if the policy refuses over a blocker
      def submit(verdict)
        @ending.synchronize do
          refuse_closed!
          refuse_second_verdict!
          judged = ReviewVerdict.new(verdict:, changeset_digest: digest)
          @policy.admit!(judged.verdict, changeset: @changeset, marks: @marks, annotations:)
          @journal << judged
          @judgement = judged
          Surface.acknowledge(@surface, judged.verdict)
          judged.verdict
        end
      end

      # Let the round go without a verdict. Journal-first, as {.open} and
      # {#submit} are: the record is built (so the closer is judged by the record
      # that owns the vocabulary), journaled, and only then held as closed.
      #
      # A JUDGED ROUND IS REFUSED. Its verdict is what `/review-submit` posts, and
      # a close journaled after it would leave a reader unable to say whether the
      # round ended in a judgement or without one.
      #
      # @param by [String] a member of {Review::CLOSED_BY}
      # @return [ChangesetClosed] the record, as journaled
      # @raise [AlreadySettled] if this round was judged
      # @raise [Closed] if it was already closed
      def close(by:)
        @ending.synchronize do
          refuse_closing_settled!
          refuse_closed!
          closed = ChangesetClosed.new(changeset_digest: digest, closed_by: by)
          @journal << closed
          @closed = true
          closed
        end
      end

      # {#close}, for a caller that does not care whether something else ended
      # the round first: a refusal raised after the bind, where a gesture may
      # already have landed and must not turn the refusal into its own. Asked
      # and done under the ending lock, so nothing ends the round in between.
      #
      # @param by [String] a member of {Review::CLOSED_BY}
      # @return [ChangesetClosed, nil] the record, or nil when the round had
      #   already ended
      def close_unless_ended(by:)
        @ending.synchronize { close(by:) if verdict.empty? && !closed? }
      end

      private

      # {Marking}, built fresh for every gesture -- see its own doc for why one
      # may never be held across two. {#mark} and {#mark_row} share it for the
      # validate-and-journal step; each still applies the result to `@marks`
      # itself, because that merge is this object's own state to hold.
      def marking = Marking.new(journal: @journal, known_hunks: hunk_keys)

      # NOT memoized, and the memo that used to be here was the reason {#present}
      # chunked a corpus it had been handed lazily. The table names the files
      # something has READ, and a survey reads more of itself as it is looked at
      # -- so a table built once answers for the corpus as it stood before
      # anything was opened, and {#mark} then refuses a key off a row the reader
      # is looking at. {#marked}'s rule for {#marked}'s reason: a stale view is
      # exactly the defect a marker exists to prevent.
      #
      # The cost is a blake3 pass over the hunks already in hand, growing with
      # what has been READ rather than with the changeset. Where it lands is
      # worth saying precisely, because the average hides it: the FIRST present
      # is unchanged (3.3ms at 40 files and 400 hunks), and what got slower is
      # every LATER present (1.3ms -> 3.2ms) and every {#mark} gesture (free off
      # the memo, 2.5ms now). At {Bounds}' default ceiling that is 18.4ms per
      # gesture against a 25ms present, still under anything a human perceives.
      def keys_by_path = MarkedChangeset.keys_by_path(@changeset)

      def hunk_keys = keys_by_path.values.flatten.to_set

      def refuse_second_verdict!
        return if verdict.empty?

        raise AlreadySettled, "this round was already judged #{verdict.inspect} -- a second verdict leaves a " \
                              "journal whose reader cannot tell which of the two stands"
      end

      def refuse_closed!
        return unless closed?

        raise Closed, "this round was already closed without a verdict -- open another with /review or /survey"
      end

      def refuse_closing_settled!
        return if verdict.empty?

        raise AlreadySettled, "this round was already judged #{verdict.inspect}, so there is nothing to close -- " \
                              "the judgement stands, and /review-submit still posts it"
      end

      # The verdict is judged ONCE, against the changeset {#judgement} names, and
      # {#refuse_second_verdict!} means it can never be judged again -- so a
      # widening here would leave the round reporting that verdict over a file
      # nobody has looked at, with no way left to correct it. Refusing is the
      # conservative half of the pair: reopening a settled round is a larger
      # decision (it has to say what becomes of the judgement already journaled),
      # and a human who wants one can open a fresh survey today.
      def refuse_settled_widening!
        return if verdict.empty?

        raise AlreadySettled, "this round was already judged #{verdict.inspect} -- widening it would put a file " \
                              "nobody reviewed under a verdict that already stands, and a second verdict is " \
                              "refused, so nothing could correct it"
      end
    end
  end
end
