# frozen_string_literal: true

# {Row} must exist before this file's body runs `private_constant` on it, so it
# loads FIRST. It reads no constant of this file's at LOAD time, which is what
# keeps that order legal.
require_relative "inbox_view/row"

module Lain
  module Frontend
    class Neovim
      # The human inbox as a projection: lain://inbox IS
      # {Event::Projection#pending}("human") rendered -- {Buffers}' fourth
      # view, PULL-shaped like its siblings, fed the three record shapes the
      # telemetry tee actually carries:
      #
      # * a {Telemetry::Message} addressed to the human lists (sender, age,
      #   question),
      # * a {Telemetry::TurnUsage} retires whatever the named head's chain has
      #   cited among its turns' causal_parents -- the delivery commit's edge
      #   ({Agent#perform_tools}), which is the ONLY consumption the pending
      #   projection counts. A REPLY :message alone never retires an item;
      #   that pinned rule is what keeps this view and {StatusFeed}'s
      #   inbox_count in agreement (the parity spec holds them to it), and
      # * a {Telemetry::QuestionsConsumed} retires the digests it names outright:
      #   the SPAWNED chain's carrier, whose own doc holds why the child's turn
      #   cannot ride this tee. The same :turn-edges-only rule under a different
      #   name -- but NOT the same delivery guarantee; {#consume} says what that
      #   costs.
      #
      # Consumption is a standing digest Set, {StatusFeed}'s own shape, so a
      # replayed log that delivers the consuming turn before the question
      # never lists a retired item. Like {Buffers}, this never touches nvim:
      # it turns records into plain lines; {RpcThread} does the rendering.
      #
      # THE RING IS {ListView}'s, shared with lain://approval: "keep the last N
      # stamped renderings and resolve a cursor line to its owner" is one rule,
      # and both surfaces need it. What stays here is this view's own -- which
      # records list, when a row retires, and the sentences a refused keypress
      # gets ({Gestures}).
      #
      # THREAD CONTRACT, AND THE LOCK. {#update} runs on the frontend's drain
      # thread; the gestures run on whichever thread serves the editor's
      # commands; and {#answered} is reached from the TTY's reply fibers too,
      # since a set answered at the terminal must stop being offered by the
      # editor's advance. They share `@pending` -- mutated by an arrival or a
      # retirement, ITERATED by the render that indexes it -- and the rendering
      # index a gesture resolves through, so every one of them takes one
      # `Mutex`: a check-then-act across this seam does not fail loudly, it opens
      # the wrong thing. Holding it is also what lets {ListView} and {Gestures}
      # be lock-free.
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

        EMPTY = ["(no questions pending)"].freeze

        # How wide a rendered line may be before it is cut or wrapped. Sized as
        # {ApprovalView::WIDTH} is and for its reason: the cockpit nvim pane's
        # measured 110 columns, less `10_folds.lua`'s `"  (+N lines)"` marker,
        # so a CLOSED item still sits on one screen line. It is also
        # {Tools::AskHuman::Announcement::WIDTH} by coincidence rather than by
        # dependency -- that one clamps the summary the record carries, this one
        # clamps the row drawn around it. {Fold}'s own, not a second measurement.
        WIDTH = Fold::WIDTH

        # The ONE spelling the runtime tests for (`05_records.lua`'s
        # CONTINUATION), now read off {Fold::INDENT} rather than spelled a
        # second time: `neovim.rb`'s manifest loads {Fold} before this file, so
        # the load-order reason the two spellings used to be independent no
        # longer holds.
        INDENT = Fold::INDENT

        # What says a summary was cut. ASCII, {ApprovalView::ELISION}'s
        # spelling, so a font with no ellipsis glyph shows a cut rather than a
        # replacement box. {Fold}'s own.
        ELISION = Fold::ELISION

        # An item's body: the whole row, hard-wrapped, never at a word boundary
        # ({ApprovalView::BODY}'s ruling -- ONE wrapping mode, so what is under
        # the summary is the same row drawn the same way rather than a second
        # rendering of it; see {Row#whole} for the invariant that buys, and for
        # the stronger 'the summary is a cut prefix' claim it does NOT buy).
        # `/m` so a newline would be CARRIED rather than dropped, which is the
        # safe direction: {Row#prose} scrubs the question, and a newline that
        # reached a line would be refused downstream rather than silently
        # halving it. {Fold}'s own regex.
        BODY = Fold::BODY

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

        # {Tools::AskHuman::ASKED_BY}, named here for {RECIPIENT}'s reason. The
        # asker's NAME, which fills the sender column when the record carries it:
        # `from` is the asker chain's correlation -- its ROOT digest -- and an
        # `:inherit` child is `parent.fork`, so a child and its parent share a
        # root PERMANENTLY and rendered one indistinguishable sender here.
        ASKED_BY = "asked_by"

        # `asked_at` is OBSERVATION time by necessity -- events are
        # content-addressed and carry no wall clock -- which is exactly what an
        # inbox's "age" means. `body` is kept whole rather than reduced to the
        # summary line, because the `<CR>` gesture rebuilds the SET a human
        # answers from exactly the record that produced the row.
        Item = Data.define(:from, :question, :asked_at, :body)
        private_constant :Item

        # How many renderings stay resolvable, handed to {ListView} rather than
        # spelled inside it: a MEMORY bound, not a rule about correctness, which
        # is the difference the stamp makes. "The render queue drains everything
        # in one tick, so the screen is the newest rendering or the one before
        # it" is FALSE -- {RenderQueue} drains once per RPC tick, so a burst
        # posts arbitrarily many renderings between drains and the screen can be
        # k of them behind. So this number only says how far behind the screen
        # may be before a keypress must be pressed again.
        #
        # lain://approval holds EIGHT, and the two are deliberately not
        # reconciled: nothing known says why that surface remembers half as
        # many, and inventing a reason is worse than carrying a parameter.
        HELD = 16

        # Its own file: once an item could span lines, "what
        # a listed set looks like on screen" stopped being one interpolation and
        # became a rule -- summary, cut, wrap, and the invariant that ties them.
        private_constant :Row

        # The set the `<CR>` gesture opened, or the reason none did. This object
        # touches neither nvim nor stdio, so "report the failure" can only mean
        # "hand it back".
        Opened = Data.define(:digest, :report) do
          def opened? = !digest.nil?
        end

        # The question surface nobody wired: it answers the one message this view
        # sends it, so no path below asks whether a surface exists -- and it
        # refuses, because an inbox with nowhere to open a set must say so rather
        # than report an open that never happened.
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
          @renderings = ListView.new(held: HELD)
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
        # HOLDING. The row carries no digest, so a line number is the only thing
        # a gesture can carry back -- but a line alone names a POSITION, and this
        # view's positions are not stable: a retirement removes a row and every
        # row below it moves up while the render that removes it is still queued
        # for nvim. So the editor sends back the GENERATION this view stamped
        # that buffer with, and a rendering this view no longer holds answers
        # nothing rather than the nearest one it happens to have.
        #
        # @param line [Integer] 1-based, as nvim's cursor reports it
        # @param generation [Integer] the stamp on the buffer the human is
        #   looking at (b:lain_view_generation, stamped by the runtime's 45_views.lua)
        # @return [String, nil] that set's Q digest; nil when the line names no
        #   set (line 0, past the end, or the empty-state placeholder) or when
        #   the rendering it names is not one still held here
        def digest_at(line, generation:) = @slot.synchronize { @renderings.at(line, generation:).owner }

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

        # The :LainReply gesture's Ruby end: which set the cursor's row names,
        # resolved against the rendering the human is looking at and NOT opened
        # -- see {Gestures#answering}, which is where the difference between
        # answering a row and opening it is argued.
        #
        # @param line [Integer] 1-based cursor line
        # @param generation [Integer] the stamp on the buffer the human is
        #   looking at
        # @return [Opened]
        def answering(line, generation:) = @slot.synchronize { @gestures.answering(line, generation) }

        # The ADVANCE: the human just submitted a document, so open the next set
        # they have to answer. No line and no rendering, because this gesture is
        # not a cursor. It cannot be the `submit` callable and it cannot be
        # {QuestionView#wrote}: that lock is not reentrant, and this ends in
        # {QuestionView#open}.
        #
        # It opens the first set NOT already answered, which has to be a standing
        # record rather than "the one just submitted": an item leaves this view
        # only when a committed turn CITES it, so every set answered in a burst is
        # still listed, not merely the last.
        #
        # @return [Opened]
        def open_next = @slot.synchronize { @gestures.open_next }

        # A listed set has been answered, by whichever surface took it.
        #
        # REMEMBERED rather than retired, because retiring it here would break the
        # pinned consumption rule ({StatusFeed} parity: a reply is a :message and
        # clears nothing). The row stays; what changes is that neither gesture
        # will hand the human a blank document over an answer they already gave.
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

        # The consuming edges ride committed turns, and what the tee carries for
        # a commit is a {Telemetry::TurnUsage} naming the head -- so the cited
        # digests are read off the head's chain in the shared Store, under the
        # never-raise rule: a head this store cannot resolve is a miss, not a
        # drain-thread death.
        #
        # MATCHED BY CLASS, never by a duck: a two-method duck is not the test
        # {Lain::StatusFeed#turn_usage?} applies to the same record, and the gap
        # is silent in the direction that matters -- the next {Lain::Telemetry}
        # record carrying both `#usage` and `#digest` would retire HERE and not
        # there, leaving the HUD's count and this buffer disagreeing with the
        # parity spec between them still green. The two checks are written out
        # twice rather than shared, because a frontend view reaching into the
        # status sink for a predicate is the worse coupling, and the parity spec
        # carries a tripwire that fails the day a second dual-field record
        # exists.
        #
        # A SPAWNED chain's turn brings its edges under its own name, as a
        # {Lain::Telemetry::QuestionsConsumed}, whose doc holds why it is narrow.
        # It needs no chain walk and so no rescue: a second, narrower never-raise
        # promise here is how the two surfaces start disagreeing. Shaped like
        # {Lain::StatusFeed#observe_consumption} for that same reason.
        #
        # THE RULE IS THE SAME; THE RECOVERABILITY IS NOT. A dropped TurnUsage
        # SELF-HEALS -- the next commit re-walks the chain and re-retires
        # everything ever cited -- and a dropped QuestionsConsumed cannot: it
        # names one turn's edges and no later record names them again. THIS view
        # is the surface that can lose one: it rides a bounded
        # {Channel::DropOldest} while {Lain::StatusFeed} sits in the same tee and
        # never drops, and nothing resyncs off a {Telemetry::Dropped} today. A
        # loss here lists a question forever against a count reading zero --
        # permanent, silent, known and deferred.
        def consume(event)
          return retire(cited_by_chain(event.digest)) if event.is_a?(Lain::Telemetry::TurnUsage)
          return retire(event.digests) if event.is_a?(Lain::Telemetry::QuestionsConsumed)

          false
        end

        # {Lain::StatusFeed::Inbox#retire}'s counterpart, and every carrier above
        # ends here for that reason -- one expression, so no carrier can retire
        # on terms the other surface does not share.
        #
        # @return [Boolean] whether the listed set actually moved
        def retire(digests)
          digests.inject(false) do |moved, digest|
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

        # THE RESCUE IS AS WIDE AS "a miss, not a drain-thread death".
        # `MissingObject` alone covers only the head this store does not HOLD; a
        # head it holds that names something other than a turn walks into
        # `NoMethodError: undefined method 'parent' for an instance of
        # Event::Payload`, and every message ever written puts such a digest in
        # the same store. {Lain::StatusFeed::Inbox}'s identical walk must stay as
        # wide: a rescue that differs between them is a difference the parity
        # spec cannot see.
        def cited_by_chain(head_digest)
          Timeline.new(head_digest:, store: @store).to_a.flat_map(&:causal_parents)
        rescue StandardError
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
        # disagree with the rendering the first time either changed. {ListView}
        # holds one entry per LINE, so an item may draw as many lines as its
        # question needs and every one of them names the set that drew it.
        def render
          return placeholder if @pending.empty?

          now = @clock.call
          drawn = @pending.map { |digest, item| [digest, lines_for(item, now)] }
          @renderings.remember(owners: owners_in(drawn))
          drawn.flat_map(&:last) + trailer_for(drawn)
        end

        def owners_in(drawn)
          drawn.flat_map { |digest, lines| Array.new(lines.size, digest) }.freeze
        end

        # THE TRAILER RULE, structural rather than decoration: `10_folds.lua`
        # closes every fold at rest and then RE-OPENS the one holding the
        # buffer's LAST line, so a list whose last line belongs to the last item
        # hands the human that item open every time (measured on
        # lain://approval, which gets its trailer free from the keys it drew). A
        # line below the rows that starts a record of its own absorbs that
        # re-open, and this one does: the runtime's test is "not indented", and
        # neither the blank nor the keys are.
        #
        # Only where something FOLDS: a list of one-line items has no fold to
        # protect, so it renders down to the bytes as it always did.
        def trailer_for(drawn) = drawn.any? { |_, lines| lines.size > 1 } ? TRAILER : []

        # REMEMBERED like any other and not a reset: a human still holding the
        # rendering it replaced has to keep getting the truth about the row they
        # can see -- that its set retired -- rather than being told the buffer
        # they are looking at never existed.
        def placeholder
          @renderings.remember(owners: [].freeze)
          EMPTY.dup
        end

        # ONE ITEM, drawn by {Row}, with the INSTANT resolved on the way in so
        # nothing below this line can read a clock of its own -- and so every
        # row of one render ages against one moment.
        #
        # A ROW MAY SPAN LINES, which only holds because {ListView} addresses
        # by IDENTITY -- one entry per line, built by {#render}'s own pass. An
        # index that addressed by POSITION would send `<CR>` to a set the human
        # did not choose the moment a row grew.
        #
        # EVERY field a row draws off the record -- the question AND the sender --
        # is scrubbed by {Tools::AskHuman::InboxRow}, so nothing this view posts
        # can carry a newline into a line. {RenderQueue#checked_lines} stays a
        # BACKSTOP rather than the guard, and one scrubbed field beside an
        # unscrubbed one would read as a rule when it is an oversight.
        def lines_for(item, now) = Row.new(item, now:).lines
      end
    end
  end
end

# LAST, and the twin of the require at the top: {Gestures} names {InboxView}'s
# own NAME and {Opened} in its body, so it can only be read once that body has
# run -- where {Row} had to be read BEFORE it, to be made private there.
require_relative "inbox_view/gestures"
