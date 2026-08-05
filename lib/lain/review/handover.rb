# frozen_string_literal: true

module Lain
  module Review
    # The open changeset review, as the rails a human answers on see it -- what
    # {CLI::HumanReplies#bind_changeset_review} and
    # {Frontend::Neovim#bind_changeset_review} are both handed, and the only
    # object bound to both.
    #
    # It was {Tools::RequestReview::ChangesetReview}, where five of its six
    # messages declined because it held no view and the epic tool could not
    # reach one. Moved here and given the view, because nothing about serving a
    # human's gestures over a diff belongs to an epic: what the epic supplies is
    # a BATON, one collaborator, and a review opened outside an epic passes a
    # null one.
    #
    # == Two rails, and the difference is what may go wrong on each
    #
    # {#wrote_annotation} and {#wrote_verdict} are ANSWERED. They run on the RPC
    # THREAD, inside the human's `:w`, and their return value IS what that write
    # succeeds or fails with -- a refusal sentence, or nothing. So neither may
    # park, and neither may RAISE: a raise reaches
    # {Frontend::Neovim::RpcThread#answer}, which answers the editor and then
    # re-raises, ending the editor session over one note. That is why the
    # rescues below are wide (this project's own {Lain::Error} taxonomy, plus
    # the `ArgumentError` a record's guard refuses with) rather than a list that
    # a new refusal class one layer down could silently escape.
    #
    # {#open}, {#mark} and {#ask} are ACKED. They arrive on the command inbox
    # and are served by {CLI::HumanReplies::Gestures} on the reactor thread,
    # which asks each answer `#opened?`/`#marked?`/`#asked?` and renders
    # `#report` when it says no. Nothing here may raise on that rail either --
    # `Gestures` rescues only NoMethodError -- so {#mark} folds the session's
    # refusals into the answer instead of letting them out.
    #
    # == What is NOT on this object, and why
    #
    # Neither the changeset nor the rendering. {Review::Session} is the
    # aggregate and {Frontend::Neovim::ReviewView} holds the line -> row index a
    # gesture resolves through; this is the join between them and the place the
    # baton is settled, and it holds no review state of its own.
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
      # ({CLI::HumanReplies::Gestures}) asks them of whatever comes back and a
      # second shape here would be a second thing for it to understand.
      #
      # Unreachable in a headless run rather than merely unused: an `open` or a
      # `mark` gesture is something an EDITOR sends, so a run with none can
      # receive neither. It says what is true anyway, because a null that
      # answers a lie is worse than a nil check.
      module Detached
        NO_EDITOR = "no editor is attached to this review, so nothing has been rendered and this line names " \
                    "no row"

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

      # No docent, so a question about a hunk reaches nobody. A docent is
      # constructed by no wiring in this tree -- it needs an answerer, which
      # needs the run's role spawn -- so this is what `ask` honestly answers
      # until one is.
      #
      # It answers that capability's SHAPE and never its class, and that is a
      # deletability requirement rather than taste: the docent is one of this
      # chunk's removable capabilities, and `spec/lain/review/deletability_spec.rb`
      # fails on any file outside its row naming it in code -- as this one did.
      # A constant resolved inside a method body would survive the delete at
      # LOAD time and NameError at the first gesture, which is the silent half
      # of the same coupling. {CLI::HumanReplies::NoReview::Nothing} answers its
      # own outcome for the same reason.
      module Unattended
        NO_DOCENT = "no docent is wired to this review, so there is nobody to ask about this hunk and " \
                    "nothing was spent on it"

        # The duck {CLI::HumanReplies::Gestures} asks of whatever comes back:
        # `#asked?` decides whether the human is owed a sentence, and `#report`
        # is that sentence.
        module Unasked
          def self.asked? = false
          def self.report = NO_DOCENT
        end

        def self.ask(_anchor_id, _question) = Unasked
      end

      # A mark that reached the session for some of a row's hunks and was
      # refused for the rest. {Surface::Neovim::PARTLY_MARKED}'s sentence and
      # its reason: "nothing happened" and "half of it happened" need different
      # things from the human.
      PARTLY_MARKED = "%<refusal>s -- %<landed>d of %<total>d hunks on that row were recorded before it, " \
                      "so the row is now partly marked"

      # @param session [Review::Session] the aggregate every gesture records
      #   against
      # @param view [#open, #marks] the rendering a row number is resolved
      #   through ({Frontend::Neovim::ReviewView}) -- the SAME instance the
      #   surface draws with, since a stamp is only resolvable by the view that
      #   issued it
      # @param baton [#settle] what a verdict hands back, when anybody is
      #   holding one
      # @param docent [#ask] who answers a question about a hunk
      def initialize(session:, view: Detached, baton: Unheld, docent: Unattended)
        @session = session
        @view = view
        @baton = baton
        @docent = docent
      end

      # @return [Review::Session] the aggregate this rail records against
      attr_reader :session

      # The verdict, and the baton with it.
      #
      # The verdict is submitted BEFORE the baton is settled, so the fiber that
      # settling wakes cannot observe a closed review with no judgement on it --
      # and a policy that refuses ({Verdict::Policy::Incomplete}) leaves the
      # review open, which is what lets the human mark the rest and answer
      # again.
      #
      # First-answer-wins ({Approval::Queue::Pending#decide}'s rule) is not
      # implemented with a flag here: {Session#submit} already refuses a second
      # verdict over one round and {Epic::Review#settle} already refuses a
      # generation that is no longer open. A flag beside those would be a second
      # opinion free to disagree with them; what is needed is only that the
      # refusal comes back as a SENTENCE, which is what the rescue does.
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
      # `drifted` is FORWARDED and never computed. Drift is the anchor text
      # against the line the number now names, and that line lives in the editor
      # buffer -- neither the diff this session holds nor anything reachable
      # from here. The measurement is taken where the buffer is, in the lua half
      # at settle time, and this rail carries it. {AnnotationPlaced} gives it no
      # default for exactly that reason: a note nobody measured must not be
      # recorded as one that did not drift.
      #
      # The note's SHAPE was already judged at the boundary ({ReviewWrite}) --
      # every key present, side and kind closed, path and text non-blank, the
      # line inside {Anchor}'s own domain -- so what is left here is whether
      # THIS review can take it, which only the session holding the changeset
      # knows.
      #
      # @param note [Hash{String=>Object}] {ReviewWrite::KEYS}, normalized
      # @return [String, nil] a refusal in words, or nothing when it landed
      def wrote_annotation(note)
        @session.annotate(anchor(note), note["text"], kind: note["kind"], drifted: note["drifted"])
        nil
      rescue Lain::Error, ArgumentError => e
        e.message
      end

      # The sidebar's `<CR>`: open the file this row names, at its first
      # reachable hunk. Straight through to the view, which is the only object
      # that can say what a row means -- and which refuses in words when the
      # stamp is stale, when the row names no file, or when nothing is wired to
      # open one.
      #
      # @param line [Integer] 1-based, as nvim's cursor reports it
      # @param generation [Integer, nil] the stamp on the buffer it came from
      # @return [Frontend::Neovim::ReviewView::Opened]
      def open(line, generation:) = @view.open(line, generation:)

      # The sidebar's mark gesture: which hunks did this row name, and set every
      # one of them. A row IS a file, and its marker already means the whole
      # file's tri-state.
      #
      # NOT {Surface::Neovim#marked_at}, though the shape is that method's, and
      # the difference is not tidiness: that one folds refusals its session
      # answers as VALUES ({Surface::Neovim::Unbound} does), while a real
      # {Review::Session} RAISES them -- so calling it here would put an
      # exception on a rail whose consumer rescues only NoMethodError. The fold
      # below is over raises for that reason.
      #
      # @param line [Integer] 1-based
      # @param state [String, Symbol] one of `Review::MARK_STATES`
      # @param generation [Integer, nil] the stamp on the buffer it came from
      # @return [Frontend::Neovim::ReviewView::Marked]
      def mark(line, state, generation:)
        resolved = @view.marks(line, generation:)
        resolved.marked? ? recorded(resolved, state) : resolved
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

      # The position the note names, minted here rather than resolved against
      # the rendering: every member of it crossed the wire, which is the whole
      # reason {ReviewWrite::KEYS} carries `revision` and `anchor_text`.
      def anchor(note)
        Anchor.new(path: note["path"], side: note["side"], line: note["line"],
                   anchor_text: note["anchor_text"], revision: note["revision"])
      end

      # A refusal EMPTIES `hunk_keys`, because `#marked?` answers the human's
      # question -- did this gesture land -- and the answer to that is no. What
      # did reach the session is not thrown away, it is NAMED: a session that
      # takes one key and refuses the next leaves the row partly marked, and
      # saying so is what keeps that visible instead of silent.
      def recorded(resolved, state)
        landed = 0
        resolved.hunk_keys.each do |hunk_key|
          @session.mark(hunk_key, state)
          landed += 1
        end
        resolved
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
