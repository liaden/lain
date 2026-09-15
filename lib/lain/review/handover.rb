# frozen_string_literal: true

module Lain
  module Review
    # The open changeset review, as the rails a human answers on see it -- what
    # {CLI::HumanReplies#bind_changeset_review} and
    # {Frontend::Neovim#bind_changeset_review} are both handed, and the only
    # object bound to both. It holds neither the changeset nor the rendering:
    # {Review::Session} is the aggregate and {Frontend::Neovim::ReviewView} holds
    # the line -> row index a gesture resolves through, and this is the join
    # between them and the place the baton is settled.
    #
    # Two arguments behind this rail live in `docs/review.md` under "The review
    # handover": why {#wrote_annotation}/{#wrote_verdict} are ANSWERED and
    # {#open}/{#mark}/{#ask} ACKED -- and what may therefore never raise on
    # either -- and why a gesture that changed a row draws that row again,
    # including the posted-not-applied race left open deliberately.
    class Handover
      # The baton nobody is holding: a review opened outside an epic. Genuinely
      # a no-op, and that is the test of the cut -- if this needed behaviour,
      # settling would belong to the epic and the collaborator would be in the
      # wrong place. A verdict still submits, still journals, still closes the
      # round; there is simply no second party to hand anything back to.
      module Unheld
        def self.settle = nil
      end

      # No editor attached, so no rendering, so no row a gesture could name.
      # {Frontend::Neovim::ReviewView}'s own answer shapes, because the consumer
      # asks them of whatever comes back and a second shape here would be a
      # second thing for it to understand. Unreachable in a headless run rather
      # than merely unused -- an `open` or a `mark` is something an EDITOR sends
      # -- but it says what is true anyway, because a null that answers a lie is
      # worse than a nil check.
      module Detached
        NO_EDITOR = "no editor is attached -- nothing is rendered, so this line names no row"

        def self.open(_line, **) = Frontend::Neovim::ReviewView::Opened.new(path: nil, line: nil, report: NO_EDITOR)

        def self.marks(_line, **)
          Frontend::Neovim::ReviewView::Marked.new(hunk_keys: [].freeze, report: NO_EDITOR)
        end

        # No view, so nothing to tell which changeset its rows belong to. A
        # no-op rather than a refusal, {Frontend::Neovim::ReviewView::Unwired#reviewing}'s
        # reading: naming the round is a wiring step and not a gesture, so there
        # is no human owed a sentence when it reaches nobody.
        def self.reviewing(_changeset) = nil
      end

      # No docent, so a question about a hunk reaches nobody. Both review
      # commands wire a real one off the editor's surface; what still reaches
      # this is a review drawn somewhere with no thread pane -- a text surface,
      # or the null one an epic's `implementation` stage opens headless -- where
      # a refusal is honest and a docent would spend a provider call and draw
      # nowhere.
      #
      # It answers that capability's SHAPE and never its class, which is a
      # deletability requirement rather than taste: `spec/lain/review/deletability_spec.rb`
      # fails on any file outside the docent's row naming it in code, as this one
      # did. A constant resolved inside a method body would survive the delete at
      # LOAD time and NameError at the first gesture.
      module Unattended
        NO_DOCENT = "no docent is wired to this review -- nothing was asked and nothing spent"

        # The duck {CLI::HumanReplies::Gestures} asks of whatever comes back:
        # `#asked?` decides whether the human is owed a sentence, and `#report`
        # is that sentence.
        module Unasked
          def self.asked? = false
          def self.report = NO_DOCENT
        end

        def self.ask(_anchor_id, _question) = Unasked

        # A thread nobody will answer in is still a thread the human may place
        # a note at, so this takes the anchor and does nothing with it rather
        # than making {Handover#wrote_annotation} ask whether a docent exists.
        def self.hold(_anchor) = nil
      end

      # Nothing is drawing this review, so no row of it is on a screen and there
      # is none to draw again. {Detached}'s reading one collaborator over: an
      # `open` or a `mark` is something an EDITOR sends, so a review nothing
      # renders receives neither, and this says so rather than leaving a nil
      # check at both call sites.
      module Undrawn
        def self.present(_session) = nil
      end

      # The sidebar, drawn again because a gesture changed what one of its rows
      # says: a row's marker moves when a mark lands, and a row nothing had read
      # carries no hunk key until an open reads the file it names. The human's
      # NEXT gesture is resolved against exactly the rendering they are still
      # looking at, so without this, `<CR>` then a mark refused the row the `<CR>`
      # had just made markable.
      #
      # It holds the SCOPE and not the session, because the scope is the one
      # thing this rail does not already have: {Review::Session#present} takes it
      # and forgets it, so it comes from whoever DREW the round.
      #
      # NOTHING HERE RAISES, and that is the gesture rail's law rather than this
      # object's caution: {CLI::HumanReplies::Gestures} asks the gesture's own
      # `#marked?`/`#opened?` and nothing else, so a re-presentation that failed
      # must not turn a gesture that LANDED into one the human is told failed.
      #
      # BUT NOBODY READS THAT SENTENCE, and saying so is the point rather than an
      # omission being confessed. Both call sites discard it, because this rail
      # has no channel for it: the only thing a gesture can say to a human is its
      # own `#report`, and a redraw that failed did not change what the gesture
      # did. So the value is DEFENCE -- it exists so a raise cannot reach the
      # fiber -- and not a message. It is also unreachable today:
      # `RenderInlet#set_review` is refusable, and {Session#widen} has no `lib/`
      # caller. Routing a redraw failure to a human means giving this object the
      # surface, which is a change rather than a tidy-up.
      #
      # IT IS O(CHANGESET), NOT O(ROW). {Session#present} rebuilds the whole
      # rendering and its `keys_by_path` walks the whole changeset, so the cost a
      # gesture pays scales with the SURVEY rather than the one row that changed.
      # Measured under perception at {Bounds::DEFAULT_MAX_FILES} (a mark at 300
      # files goes 62.5ms -> 80.0ms, of which the pre-existing `keys_by_path`
      # rebuild is 62.5); the lever, if it ever stops being under perception, is
      # that memo and not this redraw.
      #
      # THE SCOPE IS FROZEN AT WIRING TIME, correct while a round is drawn at one
      # grouping for its whole life -- verified: nothing toggles scope from the
      # editor, and a second `/review` or `/survey` opens a new round. If a
      # scope-toggle gesture ever ships, this is where it bites.
      class Redraw
        # @param scope [Symbol, String] one of {Session::SCOPES}, resolved HERE
        #   so a scope nobody declared refuses where it was wired rather than at
        #   the human's first gesture, which is a long way from the typo
        # @raise [Session::UnknownScope]
        def initialize(scope:)
          @scope = Session.scope!(scope)
          freeze
        end

        # @param session [Review::Session] the round to draw again
        # @return [String, nil] a refusal in words, or nothing -- DISCARDED by
        #   both callers, per the class doc; the value is what makes the rescue
        #   a value rather than a swallow, not a sentence anyone renders
        def present(session)
          session.present(scope: @scope)
        rescue Lain::Error, ArgumentError => e
          e.message
        end
      end

      # A mark that reached the session for some of a row's hunks and was refused
      # for the rest. {Surface::Neovim::PARTLY_MARKED}'s sentence and its reason:
      # "nothing happened" and "half of it happened" need different things from
      # the human.
      #
      # `%<refusal>s` is LAST, and that ordering is the rule
      # `spec/refusal_width_discipline_spec.rb` states and cannot assert: the
      # embedded sentence is another component's, of a length no width bar
      # reaches, so lain's own words go first and a shortened echo truncates the
      # quotation rather than the count. This row is the ONE rail sentence known
      # to exceed that spec's bar in service, so the ordering is the whole of the
      # mitigation available.
      PARTLY_MARKED = "marked %<landed>d of %<total>d hunks on that row; the rest were refused -- %<refusal>s"

      # A mark that reached the session for EVERY hunk a row names.
      # `Surface::Neovim#mark`'s per-key notice cannot speak for a row -- a hunk
      # key is a content digest with no path in it -- and `Session#mark`'s
      # per-call acknowledgement is a port law shared with `Surface::Text`, so it
      # cannot go silent for a batch and speak once at the end either. The row's
      # own acknowledgement is therefore composed HERE: `%<path>s` carries
      # {Frontend::Neovim::ReviewView::Marked#report} verbatim (already
      # "N hunk(s) of <path>", from the SAME view that resolved the row), quoted
      # LAST for {PARTLY_MARKED}'s reason -- lain's own words first, so a narrow
      # pane truncates the quotation and not the instruction.
      MARKED_ROW = "marked %<state>s: %<path>s"

      # @param session [Review::Session] the aggregate every gesture records
      #   against
      # @param view [#open, #marks] the rendering a row number is resolved
      #   through ({Frontend::Neovim::ReviewView}) -- the SAME instance the
      #   surface draws with, since a stamp is only resolvable by the view that
      #   issued it
      # @param baton [#settle] what a verdict hands back, when anybody is
      #   holding one
      # @param docent [#ask, #hold] who answers a question about a hunk, and
      #   what is told about the anchor a note just opened a thread at
      # @param redraw [#present] how the sidebar is drawn again once a gesture
      #   has changed what one of its rows says ({Redraw}), which needs the
      #   scope the round is being read at and so comes from whoever drew it
      # @param evidence [#anchor] what a note's position is read against --
      #   the round's own changeset ({Changeset#anchor}), which every caller
      #   already holds through the session, so no wiring can forget it
      def initialize(session:, view: Detached, baton: Unheld, docent: Unattended, redraw: Undrawn,
                     evidence: session.changeset)
        @session = session
        @view = view
        @baton = baton
        @docent = docent
        @redraw = redraw
        @evidence = evidence
      end

      # @return [Review::Session] the aggregate this rail records against
      attr_reader :session

      # The verdict, and the baton with it.
      #
      # The verdict is submitted BEFORE the baton is settled, so the fiber that
      # settling wakes cannot observe a closed review with no judgement on it --
      # and a policy that refuses ({Verdict::Policy::Incomplete}) leaves the
      # review open, which is what lets the human mark the rest and answer again.
      #
      # First-answer-wins is not implemented with a flag here: {Session#submit}
      # already refuses a second verdict over one round and {Epic::Review#settle}
      # already refuses a generation that is no longer open. A flag beside those
      # would be a second opinion free to disagree with them.
      #
      # TWO UNRELATED `settle`s MEET IN THESE FOUR LINES, so read them apart.
      # `@session.submit` acknowledges the verdict to the human by way of
      # `Surface#settle` -- one word, out to the editor. `@baton.settle` hands the
      # round back to whoever is parked on it -- no word, no argument, nothing to
      # do with a surface. Their arities differ so nothing can mis-dispatch. The
      # first cannot fail this call: {Session#submit} makes the acknowledgement
      # best effort precisely because the rescue below would otherwise turn a lost
      # message into a refusal of a durable verdict.
      #
      # @param verdict [String] a member of {Review::VERDICTS}
      # @return [String, nil] a refusal in words, or nothing when it stood
      def wrote_verdict(verdict)
        @session.submit(verdict)
        @baton.settle
        nil
      rescue Lain::Error, ArgumentError => e
        e.message
      end

      # One note, as {Frontend::Neovim::ReviewWrite} normalized it off the wire.
      #
      # The wire's `anchor_text` and `revision` are the BUFFER's, and neither is
      # recorded. The position is read against the round's own revision instead
      # ({Changeset#anchor}): a changeset's buffer can be a checkout that is not
      # the head, and a survey's is the file on disk, unprojected, so recording
      # its text would journal a credential the projection masks.
      #
      # `drifted` is FORWARDED and never computed. Drift is the buffer's text
      # against the line the number now names, and that buffer is not reachable
      # from here. The measurement is taken where the buffer is, in the lua half
      # at settle time. {AnnotationPlaced} gives it no default for that reason: a
      # note nobody measured must not be recorded as one that did not drift.
      #
      # The note's SHAPE was already judged at the boundary ({ReviewWrite}), so
      # what is left here is whether THIS review can take it, which only the
      # session holding the changeset knows.
      #
      # THE NOTE IS WHAT OPENS THE THREAD, which is why the docent is told about
      # one. A thread pane exists at an anchor only once something has posted that
      # anchor's id, and a note is the only thing that ever does -- `:LainThread`
      # merely reveals a buffer the note already created. So a docent that was not
      # told would answer every question with {Docent::NO_THREAD} while being
      # perfectly well wired.
      #
      # AFTER the session, and {Docent#hold} rather than `#open`, and those are
      # the same correctness rather than two preferences. The docent is told only
      # about a note that LANDED -- a kind the session refuses journals nothing,
      # and a thread opened over it would invite a question at an anchor no note
      # is recorded at, which the docent would answer with a real provider call.
      # And `hold` does not draw, so the note's own render is the only payload
      # this rail posts: the thread carries one payload per anchor.
      #
      # ONE KNOWN LOSS REMAINS, recorded rather than smoothed over, and it runs
      # the other way: a SECOND note at a line whose thread has already been
      # answered mints a second anchor (an id is per-{Anchor}, not per position),
      # so the pane the cursor finds becomes the note's and the answered thread is
      # no longer on screen. Nothing is destroyed -- both threads are held and
      # `docent_answered` is on the record -- but the human has to reopen it.
      # Closing it means an anchor identified by POSITION rather than a fresh
      # uuid, a change to {Anchor}'s identity. An example pins it, so the trade
      # cannot move in silence.
      #
      # @param note [Hash{String=>Object}] {ReviewWrite::KEYS}, normalized
      # @return [String, nil] a refusal in words, or nothing when it landed
      def wrote_annotation(note)
        placed = anchor(note)
        @session.annotate(placed, note["text"], kind: note["kind"], drifted: note["drifted"])
        @docent.hold(placed)
        nil
      rescue Lain::Error, ArgumentError => e
        e.message
      end

      # The sidebar's `<CR>`: open the file this row names, at its first
      # reachable hunk. Straight through to the view, the only object that can
      # say what a row means.
      #
      # The sidebar is drawn again after one that opened, because opening a row
      # is what makes a survey READ the file it names -- and a row nothing has
      # read carries no hunk key, so the rendering the human keeps looking at
      # would go on refusing the mark this gesture just made possible. Nothing is
      # drawn again for a refusal, which changed no row.
      #
      # @param line [Integer] 1-based, as nvim's cursor reports it
      # @param generation [Integer, nil] the stamp on the buffer it came from
      # @return [Frontend::Neovim::ReviewView::Opened]
      def open(line, generation:)
        opened = @view.open(line, generation:)
        @redraw.present(@session) if opened.opened?
        opened
      end

      # The sidebar's mark gesture: which hunks did this row name, and set every
      # one of them. A row IS a file, and its marker already means the whole
      # file's tri-state.
      #
      # NOT {Surface::Neovim#marked_at}, though the shape is that method's: that
      # one folds refusals its session answers as VALUES, while a real
      # {Review::Session} RAISES them -- so calling it here would put an exception
      # on a rail whose consumer rescues only NoMethodError.
      #
      # The sidebar is drawn again for every gesture that REACHED the session,
      # not only one that landed whole: a row the session took half of has moved
      # to partly marked, and a human told "nothing happened" over a sidebar
      # still reading unreviewed has been told two untrue things rather than one.
      #
      # @param line [Integer] 1-based
      # @param state [String, Symbol] one of `Review::MARK_STATES`
      # @param generation [Integer, nil] the stamp on the buffer it came from
      # @return [Frontend::Neovim::ReviewView::Marked]
      def mark(line, state, generation:)
        resolved = @view.marks(line, generation:)
        return resolved unless resolved.marked?

        recorded(resolved, state).tap { @redraw.present(@session) }
      end

      # The docent question: `["review_ask", [anchor_id, question]]`, the one
      # gesture carrying no stamp, because an anchor id names the same anchor in
      # every rendering.
      #
      # @param anchor_id [String] the id the editor cited back
      # @param question [String] the human's own words
      # @return [Review::Docent::Asked]
      def ask(anchor_id, question) = @docent.ask(anchor_id, question)

      private

      def anchor(note) = @evidence.anchor(path: note["path"], side: note["side"], line: note["line"])

      # A refusal EMPTIES `hunk_keys`, because `#marked?` answers the human's
      # question -- did this gesture land. What did reach the session is NAMED
      # instead: a session that takes one key and refuses the next leaves the row
      # partly marked.
      #
      # {Review::Session#mark_row}, not N calls to {Review::Session#mark}: the
      # per-key surface notice those calls would each send is what named a
      # content digest instead of a row (see {MARKED_ROW}). This composes the
      # row's ONE acknowledgement from `resolved.report` -- already the row's
      # name, from the same view that resolved its keys -- and hands back a NEW
      # {Frontend::Neovim::ReviewView::Marked}; `resolved` itself is never sent to
      # a human.
      def recorded(resolved, state)
        landed = 0
        @session.mark_row(resolved.hunk_keys, state) { landed += 1 }
        Frontend::Neovim::ReviewView::Marked.new(hunk_keys: resolved.hunk_keys,
                                                 report: format(MARKED_ROW, state:, path: resolved.report))
      rescue Lain::Error, ArgumentError => e
        unrecorded(e.message, landed, resolved.hunk_keys.size)
      end

      def unrecorded(refusal, landed, total)
        report = landed.zero? ? refusal : format(PARTLY_MARKED, refusal:, landed:, total:)
        Frontend::Neovim::ReviewView::Marked.new(hunk_keys: [].freeze, report:)
      end
    end
  end
end
