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
      # mid-review with nothing lost: the session is the aggregate, and
      # every message here is a translation with no memory. Its instance
      # variables are exactly its four collaborators, and a spec asserts that
      # by name rather than by inspection of what happens to be in them.
      #
      # Six arguments behind this adapter live in `docs/review.md` under "The
      # editor's review surface": which rail each message rides and why
      # `annotate` and `thread` share one, what a message answers and why
      # {#verdict} alone cannot carry a refusal, where `drifted:` is measured and
      # why the note leg refuses uniformly or not at all, why this object can
      # never itself be `@changeset_review`, and the one leg it cannot grow.
      class Neovim
        # A mark, in words, because the sidebar row that would show it as a glyph
        # cannot be redrawn without the changeset (see the class doc). The state
        # goes LAST and unadorned so `reviewed` and `unreviewed` are told apart
        # by a word boundary rather than by a substring -- the trap
        # `spec/support/shared_examples/review_surface.rb` names explicitly.
        #
        # `hunk_key` is already TRUNCATED by {#mark}, through {Surface.preview}.
        #
        # `65_review.lua:37` echoes this notice with `nvim_echo`, which writes the
        # MESSAGE AREA -- `&columns` wide -- and NOT the review WINDOW a three-way
        # cockpit split narrows to 40 columns. (An earlier draft named the review
        # pane's width as the constraint; verified against a real embedded UI that
        # `nvim_echo` never reads the window.) Measured at `columns=40/80/120`:
        # the untruncated message (96 characters, 102 with the `"lain: "` prefix)
        # fits one message line only at 120, while the truncated one fits at 80
        # and 120. A message that does not fit one line is what the
        # `Press ENTER or type command to continue` prompt was traced back to --
        # and that prompt blocks RPC on every mark. No file name reaches this
        # surface (`Session#mark` sends only the key and the state), so a prefix
        # of the key is the only identifying substance a human can be shown here.
        MARKED = "%<hunk_key>s is now %<state>s"

        # A session that took some of a row's hunks and refused the rest. The
        # figures lead with what is now TRUE of the row rather than with the
        # refusal alone, because "nothing happened" and "half of it happened"
        # need different things from the human -- and because the embedded
        # refusal is of a length no width bar reaches, so lain's own words have
        # to come first. {Handover::PARTLY_MARKED} carries the same sentence,
        # and its comment records why this row is the one known to exceed
        # `spec/refusal_width_discipline_spec.rb`'s bar in service.
        PARTLY_MARKED = "marked %<landed>d of %<total>d hunks on that row; the rest were refused -- %<refusal>s"

        # The ask, naming the vocabulary rather than the command: the COMMAND is
        # taught once, in {Review::OpenedBanner}, at the moment the round opens,
        # and what this ask supplies is the part the human still has to choose.
        # Repeating the verb would also lengthen a notice that must fit one
        # `nvim_echo` line, for {MARKED}'s reason.
        ASK_VERDICT = "this review is waiting for a verdict -- one of %s"

        # The answer to that ask, once a policy admitted it and the journal holds
        # it. {MARKED}'s width argument applies unchanged and is why this is one
        # short clause. At `Review::VERDICTS`' longest member it runs well inside
        # a 40-column line, prefix included.
        SETTLED = "this review is settled: %<verdict>s"

        # The first line of the sidebar a declined review leaves behind, ahead
        # of the reason. Parenthesized like {Frontend::Neovim::ReviewView::PLACEHOLDERS},
        # so it reads as a state of the sidebar rather than as a row to open.
        NOTHING_UNDER_REVIEW = "(nothing under review)"

        # The session nobody bound. {Frontend::Neovim::ReviewView::Unwired}'s
        # honesty, one object over: it answers the one message this surface sends
        # it, so no path here asks whether a session exists, and it REFUSES,
        # because a gesture that reaches no model must say so rather than be
        # dropped.
        module Unbound
          NO_SESSION = "no review session is bound here -- open a review before marking a hunk"

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

        # The thread pane, for a collaborator that renders a CONVERSATION into it
        # rather than one message. {Review::Docent} is that collaborator and the
        # only one: its answers arrive on a task of their own, seconds after the
        # gesture that asked, so it draws them itself and cannot go through
        # {#annotate}, which posts exactly one entry.
        #
        # IT HANDS OVER THE HELD INSTANCE and never builds a second: there is ONE
        # owner of a `set_thread` payload, and a caller assembling its own view
        # over some other inlet would be a second, drawing into a pane keyed by
        # the same anchor from a different rail.
        #
        # NOT one of {Review::Surface}'s messages, and it must not become one: a
        # text surface has no pane, the port's promise is what the two adapters
        # SHARE, and a docent is a capability only the editor's surface can carry.
        #
        # @return [#show] takes `(anchor, entries)` and answers the notice
        #   saying why the render did not land, or nil
        attr_reader :thread_view

        # The sides ride THIS post and not {#open}'s, and the ordering forces it:
        # the editor builds its panes from the sidebar render, at first paint,
        # before any row is opened -- so a fact carried by the changeset open
        # arrives after the window it would have prevented already exists. It is
        # a FACT about the round and never an instruction, for {#focus}'s reason:
        # Ruby says what the round has, and what to build out of that is a layout
        # only the editor can see.
        #
        # @param changeset [#files, #partitions, #sides] see {Review::Surface}'s
        #   class doc for the one place this duck is stated;
        #   {Frontend::Neovim::ReviewView} needs five members beyond it and its
        #   own doc says why
        # @param scope [Symbol] the name of a {Review::Partition} strategy as a
        #   Symbol; anything else raises from the view's own `fetch`
        # @return [String, nil] the editor's refusal, or nothing
        def present(changeset, scope:)
          rendered = @view.render(changeset, scope:)
          @rpc.set_review(rendered.lines, rendered.generation, changeset.sides)
        end

        # Put the human in front of what {#present} drew, ONCE, when the round is
        # opened -- see {Review::Surface}'s class doc for why this is not part of
        # `present`. The editor decides where they land: this rail carries no
        # arguments, because a layout is the one thing only the editor can see.
        #
        # @return [String, nil] the editor's refusal, or nothing
        def focus = @rpc.review_focus

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

        # The ask's answer, coming back the other way. Unlike {#verdict} this one
        # CAN carry a refusal: the verdict travels inward as the argument, so a
        # String answered here is the editor's own "nobody took this".
        #
        # THE EDITOR IS TOLD THE ROUND IS OVER, FIRST, and that is a teardown
        # rather than a notice. Nothing about a verdict is visible in the editor
        # -- its tabpage, panes and buffers all survive one, and `47_diff.lua`
        # hands a stamp back to any file the round opened when the human
        # re-enters it, so a note placed after this point would name a review
        # nobody is holding. This message is the only moment any adapter learns a
        # round ended. BEFORE the notice, because the notice is what a human
        # reads as "it is over", and an editor that says so while still accepting
        # notes is telling them two different things.
        #
        # Its answer is DISCARDED and the notice's handed back: both legs refuse
        # the same way, and the sentence is the one the caller can act on.
        #
        # @param verdict [String] a member of `Review::VERDICTS`, as journaled
        # @return [String, nil]
        def settle(verdict)
          @rpc.review_settled
          @rpc.review_refused(format(SETTLED, verdict:))
        end

        # Decline the review, naming why -- and that is an END of the round in
        # the editor, as {#settle} is: torn down first, for {#settle}'s reason,
        # then the sidebar redrawn as a placeholder carrying the reason, so no
        # sidebar goes on claiming to show a round nothing is bound to. The
        # sentence then rides the notice rail too, which is what puts it in
        # `:messages`.
        #
        # The placeholder carries NO STAMP: it is no rendering of this view's, so
        # a gesture on it is refused as coming from an unrendered buffer. One
        # line per line of the reason, because a buffer line cannot hold a
        # newline. The sides are the whole vocabulary, since a declined round
        # presents none and the layout has to be told something.
        #
        # @return [String, nil] the notice's answer, {#settle}'s convention
        def refuse(message)
          @rpc.review_settled
          @rpc.set_review([NOTHING_UNDER_REVIEW, *message.to_s.split("\n")], nil, Review::SIDES)
          @rpc.review_refused(message)
        end

        # The one gesture that travels the OTHER way: the editor marked a hunk,
        # and the session is what records it. Unchanged in both arguments and
        # forwarded to nobody else -- an adapter that normalized a hunk key here
        # would be a second, quieter place the review's identity is decided.
        #
        # Named for what HAPPENED rather than `mark`, which the port takes for
        # the other direction: the two carry different arguments and mean
        # opposite things, and one name for both is how a surface ends up marking
        # a hunk because the model told it a hunk was marked.
        #
        # @param hunk_key [String] `Review::Hunk`'s content key
        # @param state [Symbol, String] one of `Review::MARK_STATES`
        # @return [Object] whatever the session answered, or {Unbound}'s refusal
        def marked(hunk_key, state) = @session.mark(hunk_key, state)

        # The mark gesture WHOLE, as the wire sends it: `["review_mark", [line,
        # state, generation]]`. A sidebar row renders no hunk key and a key is a
        # content digest that never crosses the wire, so the editor sends the
        # LINE and the stamp of the rendering it came from, and the view -- the
        # only object that can -- says which hunks that row named. Every one of
        # them is marked, because a row IS a file and its marker already means
        # the whole file's tri-state.
        #
        # BOTH refusals fold into the one answer, and the second is the whole
        # reason this method is not three lines. The view can refuse (a stamp it
        # cannot resolve, a row naming no hunk) and so can the SESSION, while
        # {CLI::HumanReplies::Gestures} asks `#marked?` and nothing else --
        # handing the view's answer straight back therefore told the human a mark
        # had landed that nothing recorded.
        #
        # A refusal EMPTIES `hunk_keys`, because `#marked?` answers the human's
        # question -- did this gesture land. What did reach the session is named
        # in the report instead: a session whose `#mark` takes one key and
        # refuses the next leaves the row partly marked, the same batch hazard
        # the annotate write's prohibition exists for.
        #
        # A String is a refusal and anything else is "taken" -- `RenderInlet`'s
        # convention and this port's own -- asked of the session for the same
        # reason: a refusal has to be a value an adapter can hand back rather
        # than an exception it has to catch.
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
