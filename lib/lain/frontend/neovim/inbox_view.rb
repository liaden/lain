# frozen_string_literal: true

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
      # thread; {#open} and {#digest_at} run on whichever thread serves the
      # editor's commands (the reply consumer's fiber, on the reactor). They
      # share `@pending` -- mutated by an arrival or a retirement, ITERATED by
      # the render that indexes it -- and the rendering index that gesture then
      # resolves through, so all four methods take one `Mutex`. It is
      # {QuestionView}'s `@slot` for {QuestionView}'s reason: a check-then-act
      # across this seam does not fail loudly, it opens the wrong thing.
      #
      # Nothing under the lock can park. The one call it spans into another
      # object is `@questions.open`, which is the editor's NON-BLOCKING path --
      # {QuestionView} holds its own lock across the same post -- and nothing on
      # the far side of it ever calls back here, so the two locks are only ever
      # taken in one order.
      class InboxView
        NAME = "lain://inbox"
        EMPTY = ["(no questions pending)"].freeze

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

        # Four ways a keypress names no openable set, and four sentences because
        # four different things happened: the buffer the human is holding is not
        # one this view can still identify; the line names no set in it (the
        # placeholder, or past the end); it names one that has since been
        # answered or withdrawn; or the record on it is no question set at all.
        UNSHOWN = "#{NAME} is showing %<lines>d lines, which is not a rendering this view still holds -- " \
                  "it has re-rendered since, so line %<line>d could name two different sets and this " \
                  "will not guess between them".freeze
        NO_SET = "no question set on #{NAME} line %d".freeze
        RETIRED = "the question set on #{NAME} line %d is no longer pending -- it was answered or " \
                  "withdrawn since that line was rendered".freeze
        UNREADABLE = "the question set on #{NAME} line %d cannot be read -- %s".freeze

        # One listed question: who asked, what, when this view first saw it, and
        # the record's own body. `asked_at` is OBSERVATION time by necessity --
        # events are content-addressed and carry no wall clock -- which is
        # exactly what an inbox's "age" means: how long the item has sat here
        # unanswered. `body` is kept whole rather than reduced to the summary
        # line, because the `<CR>` gesture rebuilds the SET a human answers from
        # exactly the record that produced the row.
        Item = Data.define(:from, :question, :asked_at, :body)
        private_constant :Item

        # What this view has handed out, and which of it the editor can still be
        # holding. Separate from {InboxView} because reconciling "what I drew"
        # with "what you are looking at" is its own rule, and the gesture is only
        # safe while that rule is stated in one place.
        class Renderings
          # One rendering, as a gesture has to read it back: how many LINES the
          # editor holds, and which set sits on each of them. Deliberately two
          # fields and not one list -- the empty-state placeholder is ONE line
          # naming NO set -- and collapsing them is how `<CR>` on
          # "(no questions pending)" would resolve against a one-item rendering
          # of the same height.
          Rendering = Data.define(:height, :digests) do
            def shows?(lines) = height == lines

            # The 1-based/0-based seam, guarded here rather than at each caller:
            # line 0 would index -1, which is the LAST set -- a cursor nvim never
            # reports would silently open the newest one.
            def at(line) = line.positive? ? digests[line - 1] : nil
          end
          private_constant :Rendering

          # How many stay resolvable, and the bound is the render pipeline's own
          # shape rather than a number: {Neovim#post} hands each rendering to the
          # render queue and WAKES the RPC thread, which drains everything queued
          # in one tick and in order -- so what is on a human's screen is the
          # rendering just handed out or the one it replaced. A buffer older than
          # that is refused ({UNSHOWN}), never guessed at.
          HELD = 2

          def initialize = @held = [].freeze

          # Newest first, bounded -- so a rendering stays resolvable exactly as
          # long as it can still be the one on screen, and the retired digest on
          # it stays reachable until the render that removes its row has landed.
          def remember(height:, digests:)
            @held = [Rendering.new(height:, digests:), *@held].first(HELD).freeze
          end

          # WHICH rendering the editor is holding, among those still resolvable:
          # the one whose height it reports. nil when none has that height (it
          # holds something already forgotten), and nil when TWO do and they name
          # different sets on that line -- both are "I cannot say which rendering
          # you are looking at", and the whole point of the height riding along
          # is to stop this guessing.
          #
          # Two renderings of one height that AGREE on the line are not ambiguous
          # at all: whichever the human holds, the answer is the same set.
          def shown(line, showing)
            candidates = @held.select { |rendering| rendering.shows?(showing) }
            # `size == 1`, never `one?`: Enumerable#one? counts TRUTHY elements,
            # so `[digest, nil].uniq.one?` is true and a pair that DISAGREES --
            # one naming a set, one naming none -- would read as unanimous. That
            # is the empty-state placeholder and a one-item list, both one line
            # high, which is exactly the collision the height is here to catch.
            candidates.first if candidates.map { |rendering| rendering.at(line) }.uniq.size == 1
          end
        end
        private_constant :Renderings

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
          @renderings = Renderings.new
          @slot = Mutex.new
        end

        # The at-rest projection (see {Neovim#prime_views}): the inbox exists
        # from attach, saying it is empty rather than reading as broken.
        # @return [Hash{String=>Array<String>}]
        def initial
          @slot.synchronize { { NAME => placeholder } }
        end

        # Which set this view rendered on `line` OF THE RENDERING THE EDITOR IS
        # HOLDING -- {Buffers::TimelineView#digest_at}'s twin, plus the argument
        # that view does not need. The row carries no digest, so a line number
        # is the only thing a gesture can carry back; but a line number alone
        # names a POSITION, and this view's positions are not stable -- a
        # retirement removes a row and every row below it moves up, while the
        # render that removes it is still queued for nvim.
        #
        # So the editor says which rendering its position is IN, using the only
        # fact it has about that: how many lines it is holding. A rendering the
        # editor cannot be shown to hold answers nothing, rather than the
        # nearest rendering this view happens to have.
        #
        # @param line [Integer] 1-based, as nvim's cursor reports it
        # @param showing [Integer] lines in the buffer the human is looking at
        # @return [String, nil] that set's Q digest; nil when the line names no
        #   set (line 0, past the end, or the empty-state placeholder) or when
        #   no rendering still held here can be the one on screen
        def digest_at(line, showing:) = @slot.synchronize { shown(line, showing)&.at(line) }

        # The `<CR>`/`r` gesture from lain://inbox (runtime.lua's :LainOpen):
        # open the question set the cursor sits on. The LINE rides -- :LainPin's
        # recorded rule, never a digest -- and it is resolved through the index
        # built by the very render that produced that row, so what opens is what
        # the human is looking at.
        #
        # @param line [Integer] 1-based cursor line
        # @param showing [Integer] lines in the buffer the human is looking at
        # @return [Opened]
        def open(line, showing:) = @slot.synchronize { resolved(line, showing) }

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

        def shown(line, showing) = @renderings.shown(line, showing)

        # The gesture, once the buffer it came from is identified.
        def resolved(line, showing)
          rendering = shown(line, showing)
          return unopened(format(UNSHOWN, lines: showing, line:)) if rendering.nil?

          listed(rendering.at(line), line)
        end

        # One listed set, opened -- or the reason a digest the rendering named
        # is not one this view can still open. The rebuild is
        # {Question::Set.from_body}, which reads only the keys it owns, so the
        # same body that rendered the one-line summary rebuilds exactly the set
        # that was asked. A body that is no set at all (a bare `{"question" =>
        # ...}` from before sets existed) is REPORTED rather than raised: this
        # answers a keystroke, and a gesture that cannot be honoured owes the
        # human a sentence, not an exception on somebody else's thread.
        def listed(digest, line)
          return unopened(format(NO_SET, line)) if digest.nil?

          item = @pending[digest]
          return unopened(format(RETIRED, line)) if item.nil?

          refusal = @questions.open(Question::Set.from_body(item.body), digest)
          refusal.nil? ? Opened.new(digest:, report: "opened #{digest}") : unopened(refusal)
        rescue ArgumentError => e
          unopened(format(UNREADABLE, line, e.message))
        end

        def unopened(report) = Opened.new(digest: nil, report:)

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

        # The lines and the line -> digest index are ONE pass' two outputs, read
        # off the same ordered map key for value: a Hash answers `keys` and
        # `values` in one insertion order, so the digest at index i belongs to
        # the item rendered on line i + 1. An index built by a SECOND walk would
        # disagree with the rendering the first time either changed.
        def render
          return placeholder if @pending.empty?

          @renderings.remember(height: @pending.size, digests: @pending.keys.freeze)
          @pending.values.map { |item| line_for(item) }
        end

        # The rendering that names no set. It is REMEMBERED like any other and
        # not a reset: its one line is the placeholder, and a human still
        # holding the rendering it replaced has to keep getting the truth about
        # the row they can see (that its set retired) rather than being told the
        # buffer they are looking at never existed.
        def placeholder
          @renderings.remember(height: EMPTY.size, digests: [].freeze)
          EMPTY.dup
        end

        # Sender and age lead, mirroring the TTY drain's listing: a glance
        # answers "who is stuck, and for how long" before the question reads.
        def line_for(item)
          "#{item.from.to_s[0, 19]}  #{age_of(item.asked_at)}  #{item.question}"
        end

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
