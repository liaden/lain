# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # One anchor's conversation, as the editor's thread pane holds it (T18):
      # the Ruby half renders the exchange into buffer lines and posts it; the
      # editor half (`runtime/51_thread.lua`) shows it in the diff pane the
      # cursor is NOT in, swapping the buffer as the cursor moves.
      #
      # A PROJECTION, not a view with a round trip. {QuestionView} and
      # {Compose} both hold state because their `:w` comes back to them and has
      # to be matched against what they opened; the thread's `:w` is
      # `review_ask`, which {CLI::HumanReplies::Gestures} routes to the review
      # SESSION -- the object that owns the changeset and the anchors. So there
      # is nothing here for a write to answer, and nothing here to keep: this
      # renders and posts, and a spec pins that its only instance variable is
      # the rail out. That is also what {Review::Surface}'s own doc means by "a
      # surface holds NO review state"; T19's adapter reaches this object, so
      # the promise has to be true one layer down too.
      #
      # == The anchor rides whole, not as a bare id
      #
      # {RpcThread::RenderQueue::SET_THREAD} names its first argument
      # `anchor_id`, and T11's reasoning for keying on an id rather than a line
      # is right and is kept: an id is a stamp Ruby minted and can hand back
      # unchanged, while a line only names a position in the rendering that drew
      # it. What that reasoning does not supply is the one fact the pane cannot
      # work without -- WHERE the anchor sits. The pane is cursor-driven: it
      # answers "is there a thread on the line I am on", and no other entry
      # point on this rail carries an anchor's position (T15's `open_changeset`
      # carries the file, never its notes). Ruby is the only side that knows,
      # so the identity that crosses is the id AND the position: `id`, `path`,
      # `side`, `line`. The editor treats the id as opaque and never parses it,
      # which is the half of T11's rule that actually binds.
      #
      # The keys are Strings and `side` is a String, because that is what a lua
      # table on the far side of msgpack reads as -- {Review::Wire}'s rule for
      # the same crossing, one layer up.
      #
      # == The ONE owner of a `set_thread` post
      #
      # {Review::Surface::Neovim} renders `annotate` and `thread` THROUGH this
      # object rather than beside it, and that is a correction rather than a
      # preference. Both used to build their own payload and post it directly:
      # a bare `anchor.id` String, which the editor half refuses by name --
      # over a NOTIFY, so the refusal reached nobody and every annotation in
      # production produced no pane at all while Ruby was answered "it landed".
      # Two objects owning one wire shape is what made that possible, so there
      # is now exactly one, and the surface supplies {Entry} values.
      class ThreadView
        # Every thread buffer's name begins here; the anchor's id completes it.
        # A buffer PER ANCHOR rather than one reused pane buffer, because a
        # half-typed reply belongs to the thread it was typed in and swapping
        # the pane must not lose it.
        BUFFER_PREFIX = "lain://thread/"

        # No editor took the conversation: none is attached, one died, or one
        # stopped draining -- one notice for all three
        # ({QuestionView::DETACHED}'s reason). A LIVE inlet answers
        # {RpcThread::RenderInlet::THREAD_DETACHED} instead, which is the same
        # fact in the sentence that door already owned; this is the one the Null
        # editor below speaks, so an unwired view never reports a thread that
        # never landed.
        DETACHED = "showing a review thread needs an attached editor"

        # A thread nobody has said anything in yet. Rendered rather than left
        # empty, because an empty pane reads as a rendering glitch rather than
        # as an invitation -- {ReviewView::PLACEHOLDERS}' reasoning, and it also
        # names the gesture, since `:w` being the send is not guessable.
        EMPTY = "(nothing asked here yet -- type below this line and :w to ask)"

        # A caller handing over an anchor keyed by nothing. `%p` rather than
        # `%s`, so a blank String and a nil read differently in the sentence
        # that refuses them.
        BLANK_ID = "a thread is keyed by its anchor's id, and %p names nothing -- every question typed " \
                   "into the pane cites that id back, so a blank one would file an answer against " \
                   "whichever thread happened to be open"

        # What opens each message, and it is a CROSS-LANGUAGE vocabulary: the
        # `]]`/`[[` motions in `runtime/51_thread.lua` recognise a message by
        # this shape. A static chunk can derive nothing from Ruby, so the two
        # spellings are pinned by BEHAVIOUR -- `thread_view_spec.rb` renders a
        # real conversation through a real editor and asserts `]]` lands on the
        # second speaker -- which is stronger than two constants a spec compares
        # (41_layout's own note on the only defence such a vocabulary has).
        SPEAKER_PREFIX = "## "

        # WHERE this conversation hangs, as its first line. The pane sits
        # opposite the line the cursor is on, so the position is one glance
        # away rather than obvious -- and the same rendering is what
        # {Review::Surface::Neovim} posts for a note, where naming the file and
        # line is the whole of the context. The spelling is
        # {Review::Surface::Text#thread}'s, so a reader moving between the two
        # surfaces reads the same line.
        HEADER = "-- thread at %s --"

        # One message in the conversation. `speaker` is who said it (the human,
        # the docent T24 spawns, or lain refusing), `text` is what they said,
        # newlines and all -- this object cuts it into buffer lines.
        Entry = Data.define(:speaker, :text)

        # The Null editor, and the default: an unwired view refuses honestly
        # rather than pretending the conversation landed ({QuestionView::Detached}'s
        # duck, one method wide).
        module Detached
          module_function

          def set_thread(_anchor, _lines) = DETACHED
        end

        # @param rpc [#set_thread] the editor's inlet ({RpcThread::RenderInlet}):
        #   takes the anchor's identity and the rendered lines, and answers why
        #   the render did not land
        def initialize(rpc: Detached)
          @rpc = rpc
        end

        # Render one anchor's conversation into the editor's thread pane.
        #
        # It does NOT present: the pane shows this thread when the human's
        # cursor reaches the anchored line, and swapping a pane under somebody
        # reading the other side is the "a render moves nobody" rule
        # (`45_views`, `41_layout`). The one exception is decided in lua rather
        # than here -- a human already standing on the line sees it at once,
        # because the editor re-runs the same decision after every render.
        #
        # @param anchor [#id, #path, #side, #line] the position this
        #   conversation hangs off -- {Review::Anchor} in production
        # @param entries [Enumerable<Entry>] the exchange so far, oldest first
        # @return [String, nil] the notice saying why it is not on screen, or nil
        def show(anchor, entries = [])
          @rpc.set_thread(identity(anchor), lines_of(anchor, entries))
        end

        private

        # The id is the whole of a thread's identity -- every `review_ask` cites
        # it back, and `nil == nil` is exactly how a buffer opened under nothing
        # would answer for a thread nobody holds. Refused at the door, by name,
        # for {QuestionView#named!}'s reason: this is a caller handing over a
        # value it should not have, and the human has done nothing yet.
        def identity(anchor)
          id = anchor.id
          raise ArgumentError, format(BLANK_ID, id) if Blankness.blank?(id)

          { "id" => id.to_s, "path" => anchor.path.to_s, "side" => anchor.side.to_s, "line" => anchor.line }
        end

        # One buffer line per line, terminators removed: `nvim_buf_set_lines`
        # raises on a String holding a newline, so a paragraph has to arrive
        # already cut ({QuestionView#lines_of}'s rule, and `47_diff`'s
        # `checked_lines` is the far side of it).
        #
        # {HEADER} first, then a blank line before each message and none after
        # the last: the human types their next question at the end of the
        # buffer, and a trailing blank would make "what did they add" one line
        # harder to read for no gain. The leading blank the flat_map produces is
        # what separates the first message from the header, so it stays.
        def lines_of(anchor, entries)
          rendered = entries.to_a.flat_map { |entry| ["", "#{SPEAKER_PREFIX}#{entry.speaker}", *body(entry.text)] }
          [format(HEADER, "#{anchor.path}:#{anchor.line}"), *(rendered.empty? ? [EMPTY] : rendered)]
        end

        def body(text) = text.to_s.split("\n")
      end
    end
  end
end
