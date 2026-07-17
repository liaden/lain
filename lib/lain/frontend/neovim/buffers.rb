# frozen_string_literal: true

require "json"

module Lain
  module Frontend
    class Neovim
      # Read-only PROJECTIONS of live harness state onto named nvim buffers --
      # the twin of {Neovim}'s append-only journal, but PULL-shaped: each view is
      # current state, not a log, so an update replaces the whole buffer rather
      # than growing it (see runtime.lua's `set_view`).
      #
      # Three views, three collaborators, no Agent reference -- 4-2.2's
      # "subscribe, don't reach into Agent": {Timeline#ancestors} (via {#to_a})
      # over an injected {Store} answers `lain://timeline` once a
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

        # @param store [Lain::Store] backs the Timeline a {Telemetry::TurnUsage}'s
        #   digest names -- the SAME store the live session's Timeline commits
        #   into, so its ancestors are actually reachable here. Defaults to
        #   {DetachedStore}, which renders every timeline as unavailable.
        # @param session [Lain::Session] the run's live reminders source
        # @param inbox [InboxView, nil] the fourth view (I6); built over the
        #   same store by default, injectable so a spec pins its clock
        def initialize(store: DetachedStore.instance, session: Session::Null.instance, inbox: nil)
          @store = store
          @session = session
          @inbox = inbox || InboxView.new(store:)
          @last_reminders = nil
          @last_payload = nil
        end

        # The at-rest projection, posted once at attach: every view exists (and
        # says what it awaits) before the first event, so an idle session's
        # `:buffers` does not read as "broken". Workspace needs no placeholder --
        # reminders are readable before any event, so it renders real state and
        # seeds the change tracking, sparing the first event a no-op re-render.
        # @return [Hash{String=>Array<String>}] buffer name => initial lines
        def initial
          { TIMELINE => ["(no turns yet)"], WORKSPACE => workspace_update,
            DIFF => ["(no requests yet)"] }.compact.merge(@inbox.initial)
        end

        # @param event [Object] one Channel event
        # @return [Hash{String=>Array<String>}] buffer name => full replacement
        #   lines, for every view this event moved -- empty when it moved none
        def updates(event)
          { TIMELINE => timeline_update(event), WORKSPACE => workspace_update, DIFF => diff_update(event),
            InboxView::NAME => @inbox.update(event) }.compact
        end

        private

        # A digest the store cannot resolve -- a mis-wired store, or an event
        # from a Timeline this store never held -- must NOT raise out of here:
        # this runs on the frontend's sole drain thread, whose death would
        # silently stop the Channel draining and eventually wedge the agent's
        # producer against a full queue. The miss renders INTO the buffer
        # instead, so it is visible where the human is already looking.
        def timeline_update(event)
          return nil unless event.is_a?(Telemetry::TurnUsage)

          Timeline.new(head_digest: event.digest, store: @store).to_a.map { |turn| turn_line(turn) }
        rescue Store::MissingObject
          ["[timeline unavailable: #{event.digest} not in store]"]
        end

        def turn_line(turn)
          "#{turn.role}: #{preview(turn.content)}"
        end

        # Text blocks joined, tool_use/tool_result blocks summarized by type --
        # a one-line gist per turn, not a full transcript.
        def preview(content)
          text = Array(content).select { |block| block["type"] == "text" }.map { |block| block["text"] }.join(" ")
          return text unless text.empty?

          kinds = Array(content).filter_map { |block| block["type"] }.uniq
          kinds.empty? ? "(empty)" : "(#{kinds.join(", ")})"
        end

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
