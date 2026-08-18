# frozen_string_literal: true

module Lain
  module Review
    module Surface
      # The editor's review surface: the ADAPTER between {Review::Surface}'s
      # seven messages and the four review rails
      # {Frontend::Neovim::RenderInlet} owns. {Surface::Text} is the
      # batch twin; this is the one a human actually reads a changeset on.
      #
      # It holds NO review state -- not an annotation, not a mark, not a
      # changeset, and not even the scope last presented. That is the port's own
      # promise (see {Review::Surface}'s class doc) and it is what lets the
      # editor half be rebuilt, swapped for a second frontend, or dropped
      # mid-review with nothing lost: the session (T13) is the aggregate, and
      # every message here is a translation with no memory. Its instance
      # variables are exactly its four collaborators, and a spec asserts that
      # by name rather than by inspection of what happens to be in them.
      #
      # == Which rail each message rides, and why two of them share one
      #
      # `present` -> `set_review`, through {Frontend::Neovim::ReviewView}, which
      # is the object that turns a changeset into sidebar rows and holds the
      # line -> file index a `<CR>` resolves through. The view's {Rendered}
      # carries the lines AND the stamp they belong to, and both go out
      # together -- there is no `#generation` reader to read them apart, which
      # is deliberate on the view's side and is what keeps a gesture from
      # resolving rendering N's row against rendering N+1's stamp.
      #
      # `annotate` and `thread` -> `set_thread`, both of them, THROUGH
      # {Frontend::Neovim::ThreadView}, because the thread pane is keyed by
      # ANCHOR ID and a note at an anchor is a message in that anchor's
      # conversation. `thread` sends no message at all (this object keeps no
      # history to replay -- {Surface::Text#thread} makes the same honest
      # reading of "open"), so the view renders its own invitation to ask;
      # `annotate` sends the note as one message. The extmark rail a note would
      # ALSO ride is T16's and does not exist yet, so a note is visible in the
      # pane and nowhere else until it does.
      #
      # THE VIEW IS THE ONE OWNER OF THAT PAYLOAD, and this object may not
      # build one itself. It used to: both messages posted `@rpc.set_thread(
      # anchor.id, lines)` -- a bare String where the editor half refuses
      # anything but a table `{id, path, side, line}`, because the pane is
      # cursor-driven and an id names no position. The refusal travelled over a
      # NOTIFY, so it reached nobody, and `Review::Session#annotate` -- the
      # whole production route to this rail -- produced no pane at all while
      # this object answered "it landed". Two owners of one wire shape is what
      # allowed the two to drift; there is now one, and this object's share is
      # deciding what ENTRIES a note becomes.
      #
      # `mark` and `refuse` and `verdict` and `settle` -> `review_refused`, the
      # review's ONE notice rail (`runtime/65_review.lua` echoes it into the
      # message area).
      # `refuse` is what that rail was built for. `mark` is there because
      # redrawing the sidebar so the file's tri-state marker moves needs the
      # CHANGESET, which is exactly the state this object must not hold. The
      # redraw does now happen -- {Review::Handover::Redraw} makes it, from the
      # gesture rail, which holds both the session and the scope -- so this
      # notice is no longer the only thing that says a mark landed; it stays
      # because it is the one that says so in WORDS, at the moment of the
      # gesture, and it is what a mark reaching this surface from anywhere but
      # that rail still has. `verdict` posts the ASK, because on an
      # interactive surface asking a human for a decision is a thing you do
      # rather than a thing you wait for; `settle` posts the ANSWER to that
      # ask, and it is here for `mark`'s reason plus one more -- a sidebar row
      # says what is REVIEWED and nothing in a row can say the round is CLOSED,
      # so words are the only place that fact fits.
      #
      # == What a message answers
      #
      # A refusal SENTENCE when the editor did not take it, and nothing that is
      # a String when it did -- {RenderInlet}'s own convention, passed straight
      # up rather than translated, because a detached editor is a fact the
      # caller has to be able to say out loud and an exception is the one shape
      # a port whose adapters DECLINE IN WORDS must not use. The four rails
      # already answer exactly this, so every command below is a tail call.
      #
      # {#verdict} is the exception and the reason is not tidiness:
      # `Review::VERDICTS` are Strings, so a refusal returned from the one
      # message that answers a verdict could not be told apart from a verdict.
      # It answers `nil`, the same as {Surface::Null#verdict} and
      # {Surface::Text#verdict}.
      #
      # A NULL VERDICT VALUE DOES NOT CLOSE THIS, and saying so is the point of
      # the paragraph -- an earlier draft here pointed at T13's `Verdict::None`
      # as the fix and a review panel was right that it is not one. A null
      # verdict says "no verdict"; it still cannot tell the caller that the
      # HUMAN DECLINED from that the EDITOR WAS DETACHED, which are different
      # facts with different things to do about them. What closes it is the
      # object this port does not have: an answer value carrying
      # verdict-or-refusal, returned by every message. That same object would
      # make the port's refusal law uniform and delete its `#verdict`
      # exemption (`spec/support/shared_examples/review_surface.rb`, law #5),
      # which is the one place the panel found nvim's convention shaping the
      # port. Left open deliberately rather than closed badly.
      #
      # {#settle} DOES NOT CLOSE IT EITHER, and the two must not be read as one
      # gesture. `settle` carries a verdict INWARD, so its answer has no
      # ambiguity to resolve and it obeys the refusal law like every other
      # command; `verdict` asks a human OUTWARD and still has nowhere to put a
      # refusal. Adding the one did not un-exempt the other.
      #
      # == The gesture leg, and where `drifted:` is measured
      #
      # {#marked_at} and {#marked} are the way BACK: the editor marked a row,
      # and the session is what records it. Nothing is recomputed on the way --
      # {Frontend::Neovim::ReviewView#marks} says which hunks the row named
      # against the rendering the human is actually looking at, and every key it
      # answers is forwarded verbatim.
      #
      # The ANNOTATE write joins the same leg, and `drifted:` is neither this
      # object's to compute nor the session's. Drift is the anchor text against
      # the line the number NOW names, and that line lives in the EDITOR
      # BUFFER -- which is neither the diff the session holds nor anything this
      # object may hold. So the comparison is made where the buffer is, in
      # T16's lua half at settle time, content against content, and arrives
      # INBOUND as a field on the `review_annotate` payload. This surface
      # FORWARDS it, the session receives it, and nobody computes it from state
      # they do not have. That is also exactly what the extmark contract
      # requires: a mark inside a rewritten span MOVES rather than
      # invalidating, so whether it survived can never answer the question and
      # only content can. The leg itself waits on `ReviewWrite::KEYS`, which
      # carries neither `drifted` nor the buffer's revision in this tree.
      #
      # THAT LEG REFUSES UNIFORMLY OR NOT AT ALL, and that is a rule rather
      # than a description of what it happens to do. T16's notes arrive ONE AT
      # A TIME, and the editor forgets the batch only after the last one lands
      # -- so a `wrote_annotation` that takes note 1 and refuses note 2 leaves
      # note 1 recorded while the editor still holds every note, and the
      # human's retry records note 1 a SECOND time. A note-by-note rail is safe
      # only while no consumer refuses per-note; that is a property of the
      # CONSUMERS, and this is one of them.
      #
      # So the refusal is computed from exactly one predicate -- is a session
      # bound to record against ({Unbound}) -- which cannot vary within a
      # batch. Everything a note CARRIES is either already judged at the
      # boundary by `Neovim::ReviewWrite` (shape, every key present, side and
      # kind closed, path and text non-blank, and `line` against
      # `Review::Anchor.line!`'s own domain, asked there precisely so nothing
      # downstream has to say it by raising), or is JOURNALED rather than
      # refused. `revision` and `drifted` are the second kind, deliberately:
      # `AnnotationPlaced` carries a revision so that "authored against one
      # diff, submitted against another" stays DETECTABLE IN THE RECORD, and
      # refusing it at the wire would defeat that AND make the refusal
      # per-note. A `validates`-shaped check added here -- one that can pass
      # one note and fail the next -- reintroduces the duplicate the moment it
      # exists.
      #
      # THIS OBJECT CAN NEVER ITSELF BE `@changeset_review`, and that is worth
      # knowing before somebody tries. `CLI::HumanReplies::Gestures` sends
      # `mark(line, state, generation:)`, which is exactly {#marked_at}'s shape
      # under another name -- but the PORT owns `mark` on this object for the
      # opposite direction (`mark(hunk_key, state)`, model to surface), so the
      # name is taken and cannot be shared. A separate gesture adapter,
      # answering `open`/`mark`/`ask` and delegating to this surface and its
      # view, is what `bind_changeset_review` has to be handed. That is a
      # wiring card's object, not this one's; the collision is stated here so
      # it is discovered by reading rather than by a rail that silently does
      # nothing.
      #
      # == The one leg this object cannot grow, and why
      #
      # {Frontend::Neovim::ReviewView}'s `changesets:` collaborator -- what a
      # `<CR>` on a sidebar row opens -- is NOT this object. Taking a changeset
      # in {#present} and rendering it immediately is not caching, and nothing
      # here does otherwise; but `changesets.open(path, line)` is driven by a
      # gesture arriving ARBITRARILY LATER than the `present` that drew the row,
      # and it needs that file's old side and both revisions. That is a
      # changeset held to answer a later message, which is the one state this
      # class is defined by not keeping.
      # {Frontend::Neovim::ReviewView::Unwired} keeps the gesture honest until
      # the object that holds the diff answers it.
      class Neovim
        # A mark, in words, because the sidebar row that would show it as a
        # glyph cannot be redrawn without the changeset (see the class doc).
        # The state goes LAST and unadorned so `reviewed` and `unreviewed` are
        # told apart by a word boundary rather than by a substring -- the trap
        # `spec/support/shared_examples/review_surface.rb` names explicitly.
        #
        # `hunk_key` here is already TRUNCATED by {#mark}, through
        # {Surface.preview} -- see that method's doc for how much of the
        # key survives and why. A real `Hunk` key is a 64-hex-character
        # content digest behind `Hunk::CONTENT_SCHEME` ("hunk-content-v1:"),
        # and the untruncated message runs past 90 characters.
        #
        # `65_review.lua:37` echoes this notice with `nvim_echo`, which
        # writes the MESSAGE AREA -- `&columns` wide, the whole editor over
        # `&cmdheight` lines -- NOT the review WINDOW a three-way
        # cockpit split narrows to 40 columns. (An earlier draft of this
        # comment named the review pane's own width as the constraint;
        # verified against a real embedded UI that it is not --
        # `nvim_echo` never reads the window.) Measured at `columns=40/80/
        # 120`: the untruncated message (96 characters, 102 once
        # `65_review.lua:37`'s `"lain: "` prefix is added) fits one message
        # line only at 120; this surface's own truncated message fits at
        # 80 and 120, not 40. A message that does not fit one line is what
        # F5 traces the `Press ENTER or type command to continue` prompt
        # to -- and that prompt blocks RPC on every mark -- so shorter is
        # what keeps the ordinary case out of it, at ordinary terminal
        # widths. No file name reaches this surface (`Session#mark` sends
        # only the key and the state -- see `review/session.rb`), so a
        # prefix of the key is the only identifying substance a human can
        # be shown here.
        MARKED = "%<hunk_key>s is now %<state>s"

        # A session that took some of a row's hunks and refused the rest. The
        # figures lead with what is now TRUE of the row rather than with the
        # refusal alone, because "nothing happened" and "half of it happened"
        # need different things from the human.
        PARTLY_MARKED = "%<refusal>s -- %<landed>d of %<total>d hunks on that row were recorded before it, " \
                        "so the row is now partly marked"

        # The ask, naming the vocabulary rather than a command: the changeset
        # review's `review_verdict` verb has no lua caller yet (T18/T20), and a
        # sentence naming a command nobody has written is worse than one
        # naming the words the human may answer with.
        ASK_VERDICT = "this review is waiting for a verdict -- one of %s"

        # The answer to that ask, once a policy admitted it and the journal
        # holds it. {MARKED}'s width argument applies unchanged and is why this
        # is one short clause: `65_review.lua:37` echoes it with `nvim_echo`
        # into the MESSAGE AREA, and a notice that does not fit one line stalls
        # nvim on `Press ENTER or type command to continue` -- which would block
        # RPC on the one gesture that ends the review. At `Review::VERDICTS`'
        # longest member this runs well inside a 40-column line, prefix
        # included.
        SETTLED = "this review is settled: %<verdict>s"

        # The session nobody bound. {Frontend::Neovim::ReviewView::Unwired}'s
        # honesty, one object over: it answers the one message this surface
        # sends it, so no path here asks whether a session exists, and it
        # REFUSES, because a gesture the human made that reaches no model must
        # say so rather than be dropped.
        module Unbound
          NO_SESSION = "no review session is bound to this surface, so there is nothing to record a mark against"

          module_function

          def mark(_hunk_key, _state) = NO_SESSION
        end

        # @param rpc [#set_review, #set_thread, #review_refused] the editor's
        #   render inlet ({Frontend::Neovim::RenderInlet}), the ONE
        #   way out of here; every one of those answers a refusal sentence or
        #   nothing
        # @param view [Frontend::Neovim::ReviewView] turns a changeset into
        #   sidebar rows and stamps each rendering
        # @param session [#mark] where a gesture coming BACK from the editor is
        #   recorded -- the review model, never this object
        # @param thread_view [#show] renders one anchor's conversation onto the
        #   `set_thread` rail ({Frontend::Neovim::ThreadView}) -- the ONE owner
        #   of that payload, see the class doc. Defaulted from `rpc` rather
        #   than required, because every caller that has the rail has all this
        #   view needs to be built.
        def initialize(rpc:, view: Frontend::Neovim::ReviewView.new, session: Unbound,
                       thread_view: Frontend::Neovim::ThreadView.new(rpc:))
          @rpc = rpc
          @view = view
          @session = session
          @thread_view = thread_view
        end

        # @param changeset [#files, #partitions] see {Review::Surface}'s class
        #   doc for the one place this duck is stated; {Frontend::Neovim::ReviewView}
        #   needs five members beyond it (a file's `#hunk_keys`, `#chunked?` and
        #   `#hunks`; a group's `#counted?` with either its `#added`/`#deleted`
        #   or its `#rendered_lines`) and its own doc says why
        # @param scope [Symbol] the name of a {Review::Partition} strategy as a
        #   Symbol; anything else raises from the view's own `fetch`
        # @return [String, nil] the editor's refusal, or nothing
        def present(changeset, scope:)
          rendered = @view.render(changeset, scope:)
          @rpc.set_review(rendered.lines, rendered.generation)
        end

        # A note is ONE message in the anchor's conversation, and its `kind` is
        # what it has instead of a speaker: `Review::ANNOTATION_KINDS` is what
        # tells a blocker from a passing remark, which is the one member a
        # verdict policy reads, so it heads the message rather than decorating
        # the text. That also puts it on the `]]`/`[[` boundary the editor half
        # jumps between, which a bracketed prefix inside a line would not be.
        #
        # @param anchor [#id, #path, #side, #line] one reviewable position
        #   ({Review::Anchor}); `id` is what keys the pane, because a line only
        #   names a position in the rendering that drew it, and the rest is the
        #   position the cursor-driven pane watches
        # @param text [String] the note itself
        # @param kind [Symbol, String] one of `Review::ANNOTATION_KINDS`
        # @return [String, nil]
        def annotate(anchor, text, kind:)
          @thread_view.show(anchor, [Frontend::Neovim::ThreadView::Entry.new(speaker: kind, text:)])
        end

        # @return [String, nil]
        def mark(hunk_key, state) = @rpc.review_refused(format(MARKED, hunk_key: Surface.preview(hunk_key), state:))

        # @return [String, nil]
        def thread(anchor) = @thread_view.show(anchor)

        # Asks, and answers nothing -- see the class doc for why this one
        # message cannot carry a refusal back.
        # @return [nil]
        def verdict
          @rpc.review_refused(format(ASK_VERDICT, Review::VERDICTS.join("/")))
          nil
        end

        # The ask's answer, coming back the other way. Unlike {#verdict} this
        # one CAN carry a refusal: the verdict travels inward as the argument,
        # so a String answered here is the editor's own "nobody took this" and
        # nothing else -- which is why it is a tail call like the rest.
        # @param verdict [String] a member of `Review::VERDICTS`, as journaled
        # @return [String, nil]
        def settle(verdict) = @rpc.review_refused(format(SETTLED, verdict:))

        # @return [String, nil]
        def refuse(message) = @rpc.review_refused(message)

        # The one gesture that travels the OTHER way: the editor marked a hunk,
        # and the session is what records it. Unchanged in both arguments and
        # forwarded to nobody else -- an adapter that normalized a hunk key
        # here would be a second, quieter place the review's identity is
        # decided, and the key is a content digest the editor never invents.
        #
        # Named for what HAPPENED rather than `mark`, which the port already
        # takes for the other direction: the two carry different arguments and
        # mean opposite things, and one name for both is how a surface ends up
        # marking a hunk because the model told it a hunk was marked.
        #
        # @param hunk_key [String] `Review::Hunk`'s content key
        # @param state [Symbol, String] one of `Review::MARK_STATES`
        # @return [Object] whatever the session answered, or {Unbound}'s refusal
        def marked(hunk_key, state) = @session.mark(hunk_key, state)

        # The mark gesture WHOLE, as the wire sends it: `["review_mark", [line,
        # state, generation]]`. A sidebar row renders no hunk key and a key is a
        # content digest that never crosses the wire, so the editor sends the
        # LINE and the stamp of the rendering it came from, and the view -- the
        # only object that can -- says which hunks that row named.
        #
        # Every one of them is marked, because a row IS a file and its marker
        # already means the whole file's tri-state.
        #
        # BOTH refusals fold into the one answer, and the second is the whole
        # reason this method is not three lines. The view can refuse (a stamp it
        # cannot resolve, a row naming no hunk) and so can the SESSION --
        # {Unbound} does, and a bound one may -- while
        # {CLI::HumanReplies::Gestures} asks `#marked?` and nothing else.
        # Handing the view's answer straight back therefore told the human a
        # mark had landed that nothing recorded, which is exactly the report
        # this leg exists to make honest.
        #
        # A refusal EMPTIES `hunk_keys`, because `#marked?` answers the human's
        # question -- did this gesture land -- and the answer to that is no.
        # What did reach the session is not thrown away, it is named in the
        # report: a session whose `#mark` takes one key and refuses the next
        # leaves the row partly marked, which is the same batch hazard the
        # annotate write's prohibition above exists for, and saying so is what
        # keeps it visible instead of silent.
        #
        # A String is a refusal and anything else is "taken" -- `RenderInlet`'s
        # convention and this port's own (law #5 in
        # `spec/support/shared_examples/review_surface.rb`), asked of the
        # session for the same reason: a refusal has to be a value an adapter
        # can hand back rather than an exception it has to catch.
        #
        # @param line [Integer] 1-based, as nvim's cursor reports it
        # @param state [Symbol, String] one of `Review::MARK_STATES`
        # @param generation [Integer, nil] the stamp on the buffer the gesture
        #   came from
        # @return [Frontend::Neovim::ReviewView::Marked]
        def marked_at(line, state, generation:)
          resolved = @view.marks(line, generation:)
          answers = resolved.hunk_keys.map { |hunk_key| marked(hunk_key, state) }
          refusal = answers.find { |answer| answer.is_a?(String) }
          return resolved if refusal.nil?

          unrecorded(refusal, answers.count { |answer| !answer.is_a?(String) }, answers.size)
        end

        private

        def unrecorded(refusal, landed, total)
          report = landed.zero? ? refusal : format(PARTLY_MARKED, refusal:, landed:, total:)
          Frontend::Neovim::ReviewView::Marked.new(hunk_keys: [].freeze, report:)
        end
      end
    end
  end
end
