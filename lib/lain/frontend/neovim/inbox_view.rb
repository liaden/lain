# frozen_string_literal: true

# {Renderings} and {Row} must exist before this file's body runs
# `private_constant` on them, so they load FIRST -- the same "load it early"
# exception neovim.rb documents for {RpcThread}, and still this subtree's index
# owning the require. Neither reads a constant of this file's at LOAD time
# (Row's are all inside method bodies), which is what keeps that order legal.
require_relative "inbox_view/renderings"
require_relative "inbox_view/row"

module Lain
  module Frontend
    class Neovim
      # The human inbox as a projection (I6): lain://inbox IS
      # {Event::Projection#pending}("human") rendered -- {Buffers}' fourth
      # view, PULL-shaped like its siblings, fed the two record shapes the
      # telemetry tee actually carries:
      #
      # * a {Telemetry::Message} addressed to the human lists (sender, age,
      #   question), and
      # * a {Telemetry::TurnUsage} retires whatever the named head's chain has
      #   cited among its turns' causal_parents -- the delivery commit's edge
      #   ({Agent#perform_tools}), which is the ONLY consumption the pending
      #   projection counts. A REPLY :message alone never retires an item;
      #   that pinned rule is what keeps this view and {StatusFeed}'s
      #   inbox_count in agreement (the parity spec holds them to it).
      #
      # Consumption is a standing digest Set, {StatusFeed}'s own shape, so a
      # replayed log that delivers the consuming turn before the question
      # never lists a retired item. Like {Buffers}, this never touches nvim:
      # it turns records into plain lines; {RpcThread} does the rendering.
      #
      # THREAD CONTRACT, AND THE LOCK. {#update} runs on the frontend's drain
      # thread; {#open}, {#open_next} and {#digest_at} run on whichever thread
      # serves the editor's commands (the reply consumer's fiber, on the
      # reactor); and {#answered} is reached from the TTY's own reply fibers as
      # well, since a set answered at the terminal must stop being offered by
      # the editor's advance. They share `@pending` -- mutated by an arrival or a
      # retirement, ITERATED by the render that indexes it -- and the rendering
      # index that a gesture then resolves through, so every one of them takes
      # one `Mutex`. It is {QuestionView}'s `@slot` for {QuestionView}'s reason:
      # a check-then-act across this seam does not fail loudly, it opens the
      # wrong thing. Holding it is also what lets {Renderings} and {Gestures} be
      # lock-free -- they are only ever reached from inside it.
      #
      # NOTHING UNDER THIS LOCK MAY WAIT ON THE EDITOR, and that is the
      # invariant the whole gesture rests on rather than a preference. A
      # gesture holds this lock, and {QuestionView#open} takes ITS lock inside
      # it, and posts from there; if that post could block on a full render
      # queue, a keypress would hold both locks waiting for the RPC thread --
      # the one thread that empties that queue AND the thread that serves the
      # editor's own writes. It cannot: the post is
      # {RenderQueue#post_question}'s non-blocking push, which REFUSES a full
      # queue rather than waiting on it, and the refusal comes back as this
      # gesture's report. Nothing on the far side ever calls back here either,
      # so the two locks are only ever taken in one order. There is a spec that
      # saturates the queue and holds this to a bounded refusal.
      class InboxView
        NAME = "lain://inbox"

        # See {Row}: a pending question is model- or human-authored prose, and a
        # rendered LINE may not carry a newline.
        NEWLINES = /\R+/

        # How much of a sender's name the column shows. A clamp on the LEAD, so
        # a fleet's rows still line up their ages -- and the only field {Row}
        # draws the same way in its summary and in its body, because a truncated
        # name is a column decision rather than something the fold recovers.
        SENDER = 19

        EMPTY = ["(no questions pending)"].freeze

        # How wide a rendered line may be before it is cut or wrapped. Sized as
        # {ApprovalView::WIDTH} is and for its reason: the cockpit nvim pane's
        # measured 110 columns, less `10_folds.lua`'s `"  (+N lines)"` marker,
        # so a CLOSED item still sits on one screen line. It is also
        # {Tools::AskHuman::Announcement::WIDTH} by coincidence rather than by
        # dependency -- that one clamps the summary the record carries, this one
        # clamps the row drawn around it.
        WIDTH = 96

        # What marks a continuation line, in the ONE spelling the runtime tests
        # for (`05_records.lua`'s CONTINUATION). Spelled here rather than read
        # off {ApprovalView::INDENT} because `neovim.rb`'s manifest loads this
        # file FIRST -- a constant reference would resolve before that class
        # exists. The two spellings and the lua pattern are pinned to each other
        # by inbox_view_spec, which is what keeps them from drifting apart in
        # silence.
        INDENT = "  "

        # What says a summary was cut. ASCII, {ApprovalView::ELISION}'s
        # spelling, so a font with no ellipsis glyph shows a cut rather than a
        # replacement box.
        ELISION = "..."

        # An item's body: the whole row, hard-wrapped, never at a word boundary
        # ({ApprovalView::BODY}'s ruling -- ONE wrapping mode, so what is under
        # the summary is the same row drawn the same way rather than a second
        # rendering of it; see {Row#whole} for the invariant that buys, and for
        # the stronger 'the summary is a cut prefix' claim it does NOT buy).
        # `/m` so a newline would be CARRIED rather than dropped, which is the
        # safe direction: {Row#prose} scrubs the question, and a newline that
        # reached a line would be refused downstream rather than silently
        # halving it.
        BODY = /.{1,#{WIDTH - INDENT.length}}/m

        # The keys, under the list, and their FIRST job is structural: see
        # {#trailer_for}. That they also tell a human what to press is the
        # second, and it is {ApprovalView::HINT}'s argument -- the only
        # discoverability a projection has is the thing in front of the reader.
        HINT = "-- <CR> or r opens the set  (:LainOpen / :LainReply {answer})"

        # A blank between the prose and the keys, for the same reason
        # {ApprovalView} draws one: an item's last wrapped line runs right up to
        # the keys otherwise.
        TRAILER = ["", HINT].freeze

        # {Tools::AskHuman::HUMAN}, named rather than imported for the same
        # reason {StatusFeed::INBOX_RECIPIENT} is: this view depends on the
        # record stream, not on the Tools tree. Both spellings are spec-pinned.
        RECIPIENT = "human"

        # {Tools::AskHuman::ASKED_BY}, named here for {RECIPIENT}'s reason and
        # pinned the same way. It is the asker's NAME, and it is what fills the
        # sender column when the record carries it: `from` is the asker chain's
        # correlation -- its ROOT digest -- and an `:inherit` child is
        # `parent.fork`, so a child and its parent share a root PERMANENTLY and
        # rendered one indistinguishable sender here. The TTY prefers the same
        # name off the ARRIVAL ({CLI::HumanReplies::InboxItem.asked}); this view
        # never sees an arrival, so it reads it off the record.
        ASKED_BY = "asked_by"

        # One listed question: who asked, what, when this view first saw it, and
        # the record's own body. `asked_at` is OBSERVATION time by necessity --
        # events are content-addressed and carry no wall clock -- which is
        # exactly what an inbox's "age" means: how long the item has sat here
        # unanswered. `body` is kept whole rather than reduced to the summary
        # line, because the `<CR>` gesture rebuilds the SET a human answers from
        # exactly the record that produced the row.
        Item = Data.define(:from, :question, :asked_at, :body)
        private_constant :Item

        # Its own file (inbox_view/renderings.rb): reconciling "what I drew"
        # with "what you are looking at" is a rule of its own, and this class
        # was over `Metrics/ClassLength` carrying it -- the same thing
        # {CommandInbox}'s extraction answered, and the cop naming the object
        # that was missing.
        private_constant :Renderings

        # Its own file (inbox_view/row.rb) for the same reason and by the same
        # cop: once an item could span lines, "what a listed set looks like on
        # screen" stopped being one interpolation and became a rule -- summary,
        # cut, wrap, and the invariant that ties them.
        private_constant :Row

        # The set the `<CR>` gesture opened, or the reason none did:
        # {Buffers::TimelineView::Pin}'s shape, for its reason -- this object
        # touches neither nvim nor stdio, so "report the failure" can only mean
        # "hand it back".
        Opened = Data.define(:digest, :report) do
          def opened? = !digest.nil?
        end

        # The question surface nobody wired ({QuestionView::Detached}'s honesty,
        # one object over): it answers the one message this view sends it, so no
        # path below asks whether a surface exists -- and it refuses, because an
        # inbox with nowhere to open a set must say so rather than report an
        # open that never happened.
        module Unwired
          module_function

          def open(_set, _digest) = "no question surface is wired to this inbox, so nothing opens from it"
        end

        # @param store [Lain::Store] resolves a TurnUsage's head so the chain's
        #   causal edges are readable; the {Buffers::DetachedStore} default
        #   renders consumption as simply never observed, same honesty as the
        #   timeline view's unavailable state
        # @param clock [#call] wall time for ages, injectable so a spec never
        #   races a real clock
        # @param questions [#open] where a set the human chose is opened for
        #   answering -- {QuestionView}, which takes `(set, digest)` and answers
        #   the notice saying why it did not open, or nil
        def initialize(store: Buffers::DetachedStore.instance, clock: -> { Time.now }, questions: Unwired)
          @store = store
          @clock = clock
          @questions = questions
          @pending = {}
          @consumed = Set.new
          @answered = Set.new
          @renderings = Renderings.new
          @gestures = Gestures.new(pending: @pending, answered: @answered, renderings: @renderings, questions:)
          @slot = Mutex.new
        end

        # The at-rest projection (see {Surfaces#prime}): the inbox exists
        # from attach, saying it is empty rather than reading as broken.
        # @return [Hash{String=>Array<String>}]
        def initial
          @slot.synchronize { { NAME => placeholder } }
        end

        # The stamp the rendering now on its way to the editor carries, for
        # whoever posts that rendering to send along with it
        # ({Buffers#generation_of}). Read on the drain thread, immediately after
        # the render that produced the lines and from the same thread, so the
        # lines posted and the stamp posted are always one rendering's.
        # @return [Integer]
        def generation = @slot.synchronize { @renderings.generation }

        # Which set this view rendered on `line` OF THE RENDERING THE EDITOR IS
        # HOLDING -- {Buffers::TimelineView#digest_at}'s twin, plus the argument
        # that view does not need. The row carries no digest, so a line number
        # is the only thing a gesture can carry back; but a line number alone
        # names a POSITION, and this view's positions are not stable -- a
        # retirement removes a row and every row below it moves up, while the
        # render that removes it is still queued for nvim.
        #
        # So the editor says which rendering its position is IN, by sending back
        # the GENERATION this view stamped that buffer with. A rendering this
        # view no longer holds answers nothing, rather than the nearest
        # rendering it happens to have.
        #
        # @param line [Integer] 1-based, as nvim's cursor reports it
        # @param generation [Integer] the stamp on the buffer the human is
        #   looking at (b:lain_view_generation, stamped by the runtime's 45_views.lua)
        # @return [String, nil] that set's Q digest; nil when the line names no
        #   set (line 0, past the end, or the empty-state placeholder) or when
        #   the rendering it names is not one still held here
        def digest_at(line, generation:) = @slot.synchronize { @renderings.digest_at(line, generation) }

        # The `<CR>`/`r` gesture from lain://inbox (the runtime's 70_inbox.lua):
        # open the question set the cursor sits on. The LINE rides -- :LainPin's
        # recorded rule, never a digest -- and it is resolved through the index
        # built by the very render that produced that row, so what opens is what
        # the human is looking at.
        #
        # @param line [Integer] 1-based cursor line
        # @param generation [Integer] the stamp on the buffer the human is
        #   looking at
        # @return [Opened]
        def open(line, generation:) = @slot.synchronize { @gestures.open(line, generation) }

        # The ADVANCE (T16): the human just submitted a document, so open the
        # next set they have to answer -- of those still pending, the one this
        # view lists FIRST, which is the one they would have pressed enter on.
        # No line and no rendering, because this gesture is not a cursor: it is
        # the submit's own continuation, and it is the CONSUMER of the answer
        # rail that calls it. It cannot be the `submit` callable and it cannot
        # be {QuestionView#wrote}: that lock is not reentrant, and this ends in
        # {QuestionView#open}.
        #
        # It opens the first set NOT already answered ({#answered}), which has
        # to be a standing record rather than "the one just submitted": an item
        # leaves this view only when a committed turn CITES it (the pinned
        # consumption rule -- a reply is a :message and retires nothing), so
        # every set answered in a burst is still listed, not merely the last.
        #
        # @return [Opened]
        def open_next = @slot.synchronize { @gestures.open_next }

        # A listed set has been answered -- by the editor's document, by
        # :LainReply, or at the terminal prompt; the consumer reports all three
        # through its one delivery path, so this view never has to guess which
        # surface took it.
        #
        # It is remembered rather than retired, because retiring it here would
        # break the pinned consumption rule ({StatusFeed} parity: a reply is a
        # :message and clears nothing). The row stays; what changes is that
        # neither gesture will hand the human a blank document over an answer
        # they already gave, and {#open_next} walks past it to a set they have
        # not seen.
        # @return [void]
        def answered(digest)
          @slot.synchronize { @answered << digest }
          nil
        end

        # @param event [Object] one Channel event
        # @return [Array<String>, nil] full replacement lines when the pending
        #   set moved, nil otherwise (ages alone never force a rewrite --
        #   {Buffers#workspace_update}'s change-guard idiom)
        def update(event)
          @slot.synchronize do
            moved = question?(event) ? arrive(event) : consume(event)
            moved ? render : nil
          end
        end

        private

        def question?(event)
          event.respond_to?(:kind) && event.kind == :message && event.to == RECIPIENT
        end

        # @return [Item, nil] the newly listed item, nil when the question is
        #   already listed or already consumed
        def arrive(event)
          return nil if @consumed.include?(event.digest) || @pending.key?(event.digest)

          @pending[event.digest] = listed_item(event, body_of(event))
        end

        def listed_item(event, body)
          Item.new(from: asker_of(event, body), question: summary_of(body), asked_at: @clock.call, body:)
        end

        # WHO the human is told is asking: the name the asker wrote into the
        # record when it has one, else the envelope's own attribution. See
        # {ASKED_BY} for why `from` alone cannot answer this.
        def asker_of(event, body)
          named = body[ASKED_BY]
          Blankness.blank?(named) ? event.from : named
        end

        # The consuming edges ride committed turns, and what the tee carries
        # for a commit is a {Telemetry::TurnUsage} naming the head -- so the
        # cited digests are read off the head's chain in the shared Store,
        # {Buffers#timeline_update}'s idiom, including its never-raise rule: a
        # head this store cannot resolve is a miss, not a drain-thread death.
        def consume(event)
          return false unless event.respond_to?(:usage) && event.respond_to?(:digest)

          cited_by_chain(event.digest).inject(false) do |moved, digest|
            @consumed << digest
            # The tombstone dies with the row it was standing in for. It exists
            # only to stop an answered-but-not-yet-retired set being offered
            # again; once the consuming turn has retired it, `@consumed` is what
            # keeps it from being re-listed, and keeping both is a set that grows
            # for the life of the session.
            @answered.delete(digest)
            !@pending.delete(digest).nil? || moved
          end
        end

        def cited_by_chain(head_digest)
          Timeline.new(head_digest:, store: @store).to_a.flat_map(&:causal_parents)
        rescue Store::MissingObject
          []
        end

        # The Q body as this view reads it: a Hash, or nothing at all. The
        # record reaches here as a {Telemetry::Message} (`payload`) or as an
        # {Event} (`body`), and either may carry something that is not a Hash --
        # so the miss is answered ONCE, here, and every reader below is a plain
        # lookup on a Hash.
        def body_of(event)
          body = event.respond_to?(:payload) ? event.payload : event.body
          body.is_a?(Hash) ? body : {}
        end

        def summary_of(body) = body.fetch("question", "(no question text)")

        # The lines and the line -> digest index are ONE pass' two outputs, off
        # one walk of the ordered map: an index built by a SECOND walk would
        # disagree with the rendering the first time either changed. What T12
        # changed is the index's shape, not that rule -- {Renderings} holds one
        # entry per LINE now, so an item may draw as many lines as its question
        # needs and every one of them names the set that drew it.
        def render
          return placeholder if @pending.empty?

          drawn = @pending.map { |digest, item| [digest, lines_for(item)] }
          @renderings.remember(owners: owners_in(drawn))
          drawn.flat_map(&:last) + trailer_for(drawn)
        end

        def owners_in(drawn)
          drawn.flat_map { |digest, lines| Array.new(lines.size, digest) }.freeze
        end

        # THE TRAILER RULE, and it is structural rather than decoration:
        # `10_folds.lua` closes every fold at rest and then RE-OPENS the one
        # holding the buffer's LAST line, so a list whose last line belongs to
        # the last item hands the human that item open, every time (T9 measured
        # exactly this on lain://approval, which gets its trailer free from the
        # keys it already drew). A line below the rows that starts a record of
        # its own is what absorbs that re-open -- and this one does start one,
        # on the pattern alone: the runtime's test is "not indented", and
        # neither the blank nor the keys are.
        #
        # Only where something FOLDS, which is the whole of the cost control: a
        # list of one-line items has no fold to protect, so it renders exactly
        # as this view has always rendered it, down to the bytes.
        def trailer_for(drawn) = drawn.any? { |_, lines| lines.size > 1 } ? TRAILER : []

        # The rendering that names no set. It is REMEMBERED like any other and
        # not a reset: its one line is the placeholder, and a human still
        # holding the rendering it replaced has to keep getting the truth about
        # the row they can see (that its set retired) rather than being told the
        # buffer they are looking at never existed.
        def placeholder
          @renderings.remember(owners: [].freeze)
          EMPTY.dup
        end

        # ONE ITEM, drawn by {Row} -- which is where the summary, the cut and
        # the wrap now live, with the clock resolved to an age on the way in so
        # nothing below this line can race one.
        #
        # A ROW USED TO BE PINNED TO ONE LINE, and the pin is gone rather than
        # relaxed. It read: a question is prose, so it is folded onto one line
        # the way {Buffers::TimelineView#preview} folds a turn -- and for the
        # sharper of that fold's two reasons, that {Renderings} indexed digests
        # by POSITION, so a two-line row would send `<CR>` to a set the human
        # did not choose. That was true of the index it described. The index
        # addresses by IDENTITY now (one entry per LINE, built by {#render}'s
        # own pass), so the reason a reader would find here no longer holds and
        # the row may grow -- which is the point: a question a human cannot read
        # is a question they have to open a document to see.
        # {RenderQueue#checked_lines} is untouched and still refuses rather than
        # repairs, and it stays a BACKSTOP rather than the guard: every field a
        # row draws off the record -- the question AND the sender -- goes through
        # {Row#prose} first, so nothing this view posts can carry a newline into a
        # line. The sender was the exception until a review found it, and the
        # asymmetry was the whole defect: one scrubbed field beside an unscrubbed
        # one reads as a rule when it is an oversight.
        def lines_for(item) = Row.new(item, age: age_of(item.asked_at)).lines

        def age_of(asked_at)
          seconds = (@clock.call - asked_at).to_i
          return "#{seconds}s" if seconds < 60
          return "#{seconds / 60}m" if seconds < 3600

          "#{seconds / 3600}h"
        end
      end
    end
  end
end

# LAST, and the twin of the require at the top: {Gestures} names {InboxView}'s
# own NAME and {Opened} in its body, so it can only be read once that body has
# run -- where {Renderings} had to be read BEFORE it, to be made private there.
require_relative "inbox_view/gestures"
