# frozen_string_literal: true

require "json"

module Lain
  module Frontend
    class Neovim
      # Read-only PROJECTIONS of live harness state onto named nvim buffers --
      # the twin of {Neovim}'s append-only journal, but PULL-shaped: each view is
      # current state, not a log, so an update replaces the whole buffer rather
      # than growing it (see the runtime's `45_views.lua`).
      #
      # Three views, three collaborators, no Agent reference -- 4-2.2's
      # "subscribe, don't reach into Agent": {TimelineView} walks an injected
      # {Store} to answer `lain://timeline` once a
      # {Telemetry::TurnUsage} names the committed turn; the injected
      # {Session}'s own `#reminders` answers `lain://workspace`, re-read on
      # every event and only re-rendered when the text actually moved; and a
      # remembered previous {Telemetry::RequestSent} payload answers
      # `lain://diff`. Buffers never touches nvim itself -- like {Neovim} it
      # turns an event into plain lines and hands them back; {RpcThread} is
      # still the only nvim-touching object.
      class Buffers
        TIMELINE = "lain://timeline"
        WORKSPACE = "lain://workspace"
        DIFF = "lain://diff"

        # Diff context window (git's own default): enough to orient a reader
        # without reprinting a session's whole, ever-growing payload (RequestSent
        # embeds the FULL message history -- see its doc) on every turn.
        CONTEXT_LINES = 3

        # The Null store (house rule: Null Object over nil checks): satisfies
        # the read half of the {Store} duck and resolves NOTHING, so a Buffers
        # nobody wired a store into renders every timeline as unavailable --
        # visibly, through the same {Store::MissingObject} path a real store's
        # genuine miss takes -- instead of what the previous default did.
        # (`store: Store.new` was a real-but-DISCONNECTED store: valid-looking,
        # yet it could never hold the live session's turns, so the first
        # {Telemetry::TurnUsage} crashed the drain thread. A default that can
        # only ever fail should SAY so, not look plausible.)
        class DetachedStore
          # @return [false]
          def key?(_digest)
            false
          end

          # Same message shape as {Store#fetch}'s, so the miss reads
          # identically whichever store declined.
          def fetch(digest)
            raise Store::MissingObject, "no object #{digest.inspect} in store"
          end

          INSTANCE = new.freeze

          # @return [DetachedStore] the shared instance
          def self.instance = INSTANCE
        end

        # lain://timeline as its own view object -- {InboxView}'s shape
        # (`initial` / `update(event)`, plain lines, never nvim), extracted for
        # {InboxView}'s reason: this view stopped being a one-line render the
        # moment it had to answer "which turn is on line N?" for the editor's
        # pin gesture. Rendering a chain, INDEXING it, and pinning off that
        # index are one responsibility, and it is not the same one as diffing
        # request payloads.
        class TimelineView
          NAME = TIMELINE
          EMPTY = ["(no turns yet)"].freeze

          # What a rendered turn line carries once {Session#record_pin} holds its
          # digest ("compaction may not elide this one"). A SUFFIX, deliberately:
          # the runtime anchors BOTH the lainRole syntax match (20_buffers.lua) and
          # lain://timeline's ]]/[[ record boundary at "^%a+:", so a marker in
          # FRONT of the role would silently cost the buffer its highlighting,
          # its motions, and its folds at once.
          #
          # A turn whose own preview happens to END with these bytes renders
          # identically to a pinned one. Cosmetic only, and deliberately not
          # defended against: nothing ever parses the marker back out -- pins are
          # resolved through {#digest_at}'s index, never off the rendered text.
          PIN_MARKER = "  [pinned]"

          # The answer to one pin gesture, as a value: this touches neither nvim
          # nor stdio, so "report the failure" can only mean "hand it back".
          # `digest` is nil exactly when the line named no turn.
          Pin = Data.define(:digest, :report) do
            def pinned? = !digest.nil?
          end

          def initialize(store:, session:)
            @store = store
            @session = session
            clear_line_index
          end

          # The at-rest projection. A RENDER like any other, so it owns the line
          # index like any other: the placeholder describes no turn, and a
          # digest still resolvable behind it would let a pin land on a line the
          # buffer no longer shows.
          # @return [Array<String>]
          def initial
            clear_line_index
            EMPTY.dup
          end

          # A digest the store cannot resolve -- a mis-wired store, or an event
          # from a Timeline this store never held -- must NOT raise out of here:
          # this runs on the frontend's sole drain thread, whose death would
          # silently stop the Channel draining and eventually wedge the agent's
          # producer against a full queue. The miss renders INTO the buffer
          # instead, so it is visible where the human is already looking.
          # @param event [Object] one Channel event
          # @return [Array<String>, nil] full replacement lines, nil for an
          #   event that names no turn
          def update(event)
            return nil unless event.is_a?(Telemetry::TurnUsage)

            render_chain(Timeline.new(head_digest: event.digest, store: @store).to_a)
          rescue Store::MissingObject
            unavailable(event.digest)
          end

          # Which turn this view renders on `line` -- the index the editor's pin
          # gesture resolves its cursor through. Positional guessing is not
          # available: the line carries no digest, and the
          # {Store::MissingObject} rescue collapses the whole chain to a single
          # notice line.
          #
          # @param line [Integer] 1-based, as nvim's cursor reports it
          # @return [String, nil] that turn's digest; nil when the line names no
          #   turn (line 0, past the end, or a collapsed unavailable chain)
          def digest_at(line)
            # The guard is the 1-based/0-based seam, not fussiness: line 0 would
            # index -1, which is the LAST turn -- a cursor nvim never reports
            # would silently pin the head.
            @line_digests[line - 1] if line.positive?
          end

          # The `p` gesture from lain://timeline (the runtime's 75_timeline.lua): pin
          # the turn under the cursor. A line naming no turn must never REACH
          # {Session#record_pin}, which refuses a blank digest loudly -- so this
          # reports instead of pinning, and the marker shows on the next render.
          #
          # @param line [Integer] 1-based cursor line
          # @return [Pin]
          def pin(line)
            digest = digest_at(line)
            return Pin.new(digest: nil, report: "no turn on #{NAME} line #{line}") if digest.nil?

            @session.record_pin(digest)
            Pin.new(digest:, report: "pinned #{digest}")
          end

          private

          # The lines and the line -> digest index are ONE pass' two outputs,
          # both read off the same materialized chain position for position. An
          # index built by a SECOND walk would disagree with the rendering the
          # first time either changed, and a pin resolved against a stale index
          # pins the wrong turn.
          def render_chain(turns)
            @line_digests = turns.map(&:digest).freeze
            turns.map { |turn| turn_line(turn) }
          end

          # The rescue collapses the WHOLE chain to one notice line, so nothing
          # on it is pinnable: the index empties with the lines rather than
          # keeping digests the buffer no longer shows.
          def unavailable(digest)
            clear_line_index
            ["[timeline unavailable: #{digest} not in store]"]
          end

          # The one spelling of "this rendering names no turn", shared by every
          # path that produces such a rendering -- the placeholder, the
          # unavailable notice, and the not-yet-rendered state at construction.
          def clear_line_index
            @line_digests = [].freeze
          end

          def turn_line(turn)
            "#{turn.role}: #{preview(turn.content)}#{pin_marker(turn.digest)}"
          end

          # Membership per line, never {Session#pins} -- that sorts the whole set
          # on every call.
          def pin_marker(digest)
            @session.pinned?(digest) ? PIN_MARKER : ""
          end

          # Text blocks joined, tool_use/tool_result blocks summarized by type --
          # a one-line gist per turn, not a full transcript.
          def preview(content)
            text = Array(content).select { |block| block["type"] == "text" }.map { |block| block["text"] }.join(" ")
            return text unless text.empty?

            kinds = Array(content).filter_map { |block| block["type"] }.uniq
            kinds.empty? ? "(empty)" : "(#{kinds.join(", ")})"
          end
        end

        # @param store [Lain::Store] backs the Timeline a {Telemetry::TurnUsage}'s
        #   digest names -- the SAME store the live session's Timeline commits
        #   into, so its ancestors are actually reachable here. Defaults to
        #   {DetachedStore}, which renders every timeline as unavailable.
        # @param session [Lain::Session] the run's live reminders source
        # @param inbox [InboxView, nil] the fourth view (I6); built over the
        #   same store by default, injectable so a spec pins its clock
        # @param timeline [TimelineView, nil] the chain view and its line ->
        #   digest index (B4); built over the same store by default, injectable
        #   for the same reason `inbox` is
        # @param questions [#open] where a set the human chose in the inbox is
        #   opened for answering ({QuestionView}), threaded through to the view
        #   that resolves the gesture. It was NOT threaded before T16, so
        #   production built its inbox over {InboxView::Unwired} and every
        #   `<CR>` would have been refused however well the consumer was wired
        #   -- invisible to a spec that injects `inbox:` ready-made, which is
        #   how it stayed hidden.
        def initialize(store: DetachedStore.instance, session: Session::Null.instance, inbox: nil, timeline: nil,
                       questions: InboxView::Unwired)
          @inbox = inbox || InboxView.new(store:, questions:)
          @timeline = timeline || TimelineView.new(store:, session:)
          @session = session
          @last_reminders = nil
          @last_payload = nil
        end

        # See {TimelineView#digest_at}. Delegated because {Buffers} is the one
        # façade the frontend holds; the index itself belongs to the view that
        # renders the lines it indexes.
        def digest_at(line) = @timeline.digest_at(line)

        # See {TimelineView#pin}.
        def pin(line) = @timeline.pin(line)

        # See {InboxView#open} -- the `<CR>`/`r` gesture's Ruby end, delegated
        # here for {#pin}'s reason: {Buffers} is the one façade the frontend
        # hands to the editor's command consumer, and each index belongs to the
        # view that renders the lines it indexes.
        def open(line, generation:) = @inbox.open(line, generation:)

        # See {InboxView#open_next} -- the advance after a submitted document.
        def open_next = @inbox.open_next

        # See {InboxView#answered}: one set answered, by whichever surface took
        # it, so neither gesture offers it again while its row waits for the
        # committed turn that clears it.
        def answered(digest) = @inbox.answered(digest)

        # The stamp a view's post carries into the editor (T16), and only ONE
        # view has one: lain://inbox is the only projection whose gesture
        # resolves through a rendering index, so it is the only one that has to
        # be able to say WHICH rendering a buffer is holding. Every other view
        # answers nothing, and {RenderQueue#post_view} then sends the argument
        # not at all rather than sending a nil -- which crosses msgpack as
        # `vim.NIL`, and `vim.NIL` is TRUTHY in lua.
        # @return [Integer, nil]
        def generation_of(name) = name == InboxView::NAME ? @inbox.generation : nil

        # The at-rest projection, posted once at attach: every view exists (and
        # says what it awaits) before the first event, so an idle session's
        # `:buffers` does not read as "broken". Workspace needs no placeholder --
        # reminders are readable before any event, so it renders real state and
        # seeds the change tracking, sparing the first event a no-op re-render.
        # @return [Hash{String=>Array<String>}] buffer name => initial lines
        def initial
          { TimelineView::NAME => @timeline.initial, WORKSPACE => workspace_update,
            DIFF => ["(no requests yet)"] }.compact.merge(@inbox.initial)
        end

        # @param event [Object] one Channel event
        # @return [Hash{String=>Array<String>}] buffer name => full replacement
        #   lines, for every view this event moved -- empty when it moved none
        def updates(event)
          { TimelineView::NAME => @timeline.update(event), WORKSPACE => workspace_update,
            DIFF => diff_update(event), InboxView::NAME => @inbox.update(event) }.compact
        end

        private

        # Recomputed every tick -- cheap, {Session#reminders} already memoizes
        # its own manifest half -- and surfaced only when the rendered text
        # actually moved, so an event the reminders never touch (a bash stdout
        # chunk) never rewrites a buffer nothing changed in.
        def workspace_update
          reminders = @session.reminders
          return nil if reminders == @last_reminders

          @last_reminders = reminders
          reminders.empty? ? ["(no reminders)"] : reminders.flat_map { |block| block.split("\n") }
        end

        def diff_update(event)
          return nil unless event.is_a?(Telemetry::RequestSent)

          lines = unified_diff(payload_lines(@last_payload), payload_lines(event.payload))
          @last_payload = event.payload
          lines
        end

        def payload_lines(payload)
          payload.nil? ? [] : JSON.pretty_generate(payload).split("\n")
        end

        # A "boring diff": trim the common prefix and suffix, show the differing
        # middle in full, and window the (possibly huge, append-only-growing)
        # context down to {CONTEXT_LINES}. No LCS -- Diff::LCS lives in the test
        # group only, and a session's own request history is already
        # prefix/suffix-stable turn to turn, which is exactly what this shape is
        # cheap and correct for.
        def unified_diff(old_lines, new_lines)
          prefix = common_length(old_lines, new_lines)
          old_rest = old_lines.drop(prefix)
          new_rest = new_lines.drop(prefix)
          suffix = common_length(old_rest.reverse, new_rest.reverse)

          [
            *context_window(old_lines.first(prefix), trailing: false),
            *changed_lines(old_rest, new_rest, suffix),
            *context_window(trailing_context(old_rest, suffix), trailing: true)
          ]
        end

        def changed_lines(old_rest, new_rest, suffix)
          [*tagged(without_suffix(old_rest, suffix), "-"), *tagged(without_suffix(new_rest, suffix), "+")]
        end

        def trailing_context(old_rest, suffix)
          suffix.zero? ? [] : old_rest.last(suffix)
        end

        def without_suffix(lines, suffix)
          lines[0...(lines.size - suffix)]
        end

        def tagged(lines, marker)
          lines.map { |line| "#{marker} #{line}" }
        end

        def common_length(mine, theirs)
          mine.zip(theirs).take_while { |a, b| a == b }.size
        end

        def context_window(lines, trailing:)
          return [] if lines.empty?

          shown = trailing ? lines.first(CONTEXT_LINES) : lines.last(CONTEXT_LINES)
          marker = lines.size > shown.size ? ["  ... (#{lines.size - shown.size} unchanged)"] : []
          shown = shown.map { |line| "  #{line}" }
          trailing ? [*shown, *marker] : [*marker, *shown]
        end
      end
    end
  end
end
