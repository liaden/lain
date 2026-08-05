# frozen_string_literal: true

require "forwardable"
require "neovim"
require "socket"

module Lain
  module Frontend
    class Neovim
      # A second lain attaching to an editor a live one already owns, refused by
      # the injected runtime before one module of it loads (runtime.lua's head
      # states the whole check, and why it asks about LIVENESS rather than
      # presence).
      #
      # A {Lain::Error} so exe/lain presents it as a notice rather than a
      # backtrace: it is the one attach failure a human causes deliberately, by
      # pointing a second `--nvim` at the editor their chat is already in, and
      # what they need back is a sentence naming a socket and an alternative.
      #
      # It carries the OWNER's channel id, which is the one fact separating
      # "another lain is in there" from every other reason an attach fails -- and
      # is what a human can check in the editor itself against
      # `:echo luaeval('__lain.channel')`.
      class SocketOwned < Lain::Error
        # @param socket_path [String] the socket the attach was refused at
        # @param channel [Integer] the live RPC channel already serving it
        def initialize(socket_path, channel)
          super("the nvim listening at #{socket_path} is already attached to a running lain (RPC channel " \
                "#{channel}), and a second attach would take that session's :LainReply, its review writes and " \
                "its rendered buffers away from it with nothing said on either side. Quit that lain first, or " \
                "start a second nvim with its own --listen socket and point --nvim at that one.")
        end
      end

      # The outbound half of {RpcThread}'s work, split into its own object: the
      # backlog of not-yet-sent render commands and ITS backpressure (the
      # T6-inherited fix). {RpcThread} owns attach, the select loop, and
      # inbound dispatch; this owns nothing nvim-shaped except turning one
      # queued command into the right `nvim_exec_lua` call -- two
      # responsibilities that were, before the split, one class doing both.
      class RenderQueue
        # Append already-rendered plain lines to the journal. Guarded on
        # `_G.__lain` so a render that races a not-yet-injected runtime is a
        # harmless no-op rather than an error notification.
        APPEND = "local lines = ...; if _G.__lain then _G.__lain.render(lines) end"

        # Whole-buffer replace for a named state view (4-2.2). Same
        # not-yet-injected guard as {APPEND}. The third argument is OPTIONAL and
        # is the rendering stamp (T16): the one view that carries one is
        # lain://inbox, whose gesture has to name the rendering it came from,
        # and every other view calls this with two arguments exactly as before.
        SET_VIEW = "local name, lines, gen = ...; if _G.__lain then _G.__lain.set_view(name, lines, gen) end"

        # Whole-buffer replace for the ONE editable view, lain://request (4-2.3).
        # Distinct from {SET_VIEW} only in the lua entry point it calls (which
        # skips the nomodifiable flip); same not-yet-injected guard.
        SET_REQUEST = "local name, lines = ...; if _G.__lain then _G.__lain.set_request(name, lines) end"

        # Open lain://compose on the human's draft (T15). A third entry point
        # rather than a flag on {SET_REQUEST}: that buffer is `nofile` and
        # never written, this one is `acwrite`, named, and SHOWN -- the two
        # have nothing in common but the word "editable".
        SET_COMPOSE = "local name, lines, gen = ...; if _G.__lain then _G.__lain.set_compose(name, lines, gen) end"

        # Open lain://question on a pending set's rendered document (T12).
        # {SET_COMPOSE}'s shape with the set's content digest in place of the
        # counter -- one more entry point rather than a flag, because that
        # buffer folds per question, indents to the grammar's two spaces, and
        # its write can be REFUSED; none of that is compose's.
        SET_QUESTION = "local name, lines, digest = ...; " \
                       "if _G.__lain then _G.__lain.set_question(name, lines, digest) end"

        OPEN_REVIEW = "local path, gen, slug = ...; if _G.__lain then _G.__lain.open_review(path, gen, slug) end"

        REVIEW_REFUSED = "local message = ...; if _G.__lain then _G.__lain.review_refused(message) end"

        # Whole-buffer replace for the changeset review's sidebar (T14). No
        # buffer NAME argument, which is the one difference from {SET_VIEW}:
        # that entry point serves five buffers and has to be told which, while
        # the sidebar is a singleton in the review's own tabpage, so the lua half
        # names its own. The stamp is REQUIRED here rather than optional as
        # {SET_VIEW}'s is -- a sidebar row moves the moment the scope toggles,
        # which is exactly the aliasing protocol 8 replaced the line count to
        # fix.
        SET_REVIEW = "local lines, gen = ...; if _G.__lain then _G.__lain.set_review(lines, gen) end"

        # Open one changed file as the diff PAIR (T15): the new side is the real
        # file on disk, the old side a scratch buffer whose content rides in
        # this argument list. Ruby runs git, never the editor -- `old_lines` is
        # `git show <base>:<path>` already read, because the changeset source is
        # a Ruby port and an injected chunk shelling out would put half the
        # review model in the editor.
        #
        # `revisions` is a map rather than two more positionals: the pair is two
        # commit-ish Strings that look alike, adjacent, and mean opposite sides,
        # and named keys are what a lua table gives for free on the far side of
        # msgpack. They are here at all because only Ruby knows them, and T16
        # stamps each buffer with its own so a note records which diff it was
        # authored against.
        OPEN_CHANGESET = "local path, old_lines, line, revisions = ...; " \
                         "if _G.__lain then _G.__lain.open_changeset(path, old_lines, line, revisions) end"

        # Show one anchor's conversation in the thread pane (T18), keyed by the
        # ANCHOR ID and not by a line: the pane's buffer is swapped as the cursor
        # moves, and a line only names a position in the rendering that drew it,
        # while an id is a stamp Ruby minted and can hand back unchanged.
        SET_THREAD = "local anchor_id, lines = ...; if _G.__lain then _G.__lain.set_thread(anchor_id, lines) end"

        # One queued command: `args` is exactly what the entry point named by
        # `lua` takes, already in order -- `[lines]` for the journal append,
        # `[name, lines]` for a view replace, `[name, lines, generation]` for
        # the compose open. Holding the argument LIST rather than named fields
        # is what lets a third entry point with a third arity share one queue
        # and one sender.
        Command = Data.define(:args, :lua)
        private_constant :Command

        # Default cap on outstanding commands (journal appends AND view
        # replacements share this one queue). T6-inherited fix: the queue was an
        # unbounded Thread::Queue, so a producer outpacing nvim could pile up an
        # unbounded backlog -- an adversarial probe hit ~800K entries, and
        # draining it (which runs BEFORE the RPC thread's select gets a turn)
        # took 6.4s, starving inbound acks. A SizedQueue fixes both at once:
        # {#post_render}/{#post_view} now BLOCK the producer once the queue is
        # full, so the backlog literally cannot exceed this cap, and {#drain}'s
        # per-tick batch is capped the same way for free.
        DEFAULT_CAPACITY = 1024

        def initialize(capacity: DEFAULT_CAPACITY)
          @queue = Thread::SizedQueue.new(capacity)
        end

        # Queue an append. Safe from any thread. BLOCKS the caller once the
        # queue is full, and raises ClosedQueueError once {#close} has run --
        # {Neovim#post} rescues that (see its comment).
        # @param lines [Array<String>]
        def post_render(lines)
          @queue.push(Command.new(args: [lines], lua: APPEND))
        end

        # Queue a whole-buffer replace for a named buffer. `editable:` picks the
        # lua entry point: the read-only state views (4-2.2) get {SET_VIEW}; the
        # one editable view, lain://request (4-2.3), gets {SET_REQUEST}, which
        # skips the nomodifiable flip. Same queue, backpressure, and death
        # behavior either way -- one render pipeline, not two.
        # @param name [String] the lain:// buffer name
        # @param lines [Array<String>]
        # @param editable [Boolean]
        # @param generation [Integer, nil] stamps the buffer (T16) so a gesture
        #   from it can say WHICH rendering the human is looking at -- today
        #   lain://inbox alone. Its absence is ARITY, not a nil argument: a nil
        #   crosses msgpack and arrives in lua as `vim.NIL`, which is TRUTHY
        #   there. Built by branch and never by `compact`, which cannot tell
        #   "no stamp" from "no lines" -- it would send `[name, generation]`
        #   and lua would bind the stamp as the buffer's lines.
        def post_view(name, lines, editable: false, generation: nil)
          args = generation.nil? ? [name, lines] : [name, lines, generation]
          @queue.push(Command.new(args:, lua: editable ? SET_REQUEST : SET_VIEW))
        end

        # The ONE non-blocking post (T15). Every other producer is a background
        # thread that can afford to be back-pressured; this one is queued from
        # Reline's INPUT LOOP, inside keypress dispatch, where a blocked push
        # would freeze the prompt's rendering with the human given no feedback
        # at all. A full queue means nvim has stopped draining, which is the
        # same fact as "no editor took the draft" -- so it raises ThreadError
        # here and {RpcThread#open_compose} turns that into the honest answer.
        # @param name [String] the lain:// buffer name
        # @param lines [Array<String>]
        # @param generation [Integer] stamped onto the buffer so the editor's
        #   answer says WHICH compose it is answering
        def post_compose(name, lines, generation)
          @queue.push(Command.new(args: [name, lines, generation], lua: SET_COMPOSE), true)
        end

        # Non-blocking like {#post_compose}, and for a sharper reason: this one
        # is posted from inside {QuestionView}'s lock, so a blocking push
        # against a full queue would hold that lock -- and the same lock is what
        # a write in the editor takes.
        # @param name [String] the lain:// buffer name
        # @param lines [Array<String>]
        # @param digest [String] the set's content digest, stamped onto the
        #   buffer so every write and abandon says WHICH set it answers
        def post_question(name, lines, digest)
          @queue.push(Command.new(args: [name, lines, digest], lua: SET_QUESTION), true)
        end

        def post_review(path, generation, epic_slug)
          @queue.push(Command.new(args: [path, generation, epic_slug], lua: OPEN_REVIEW), true)
        end

        def post_review_refusal(message)
          @queue.push(Command.new(args: [message], lua: REVIEW_REFUSED), true)
        end

        # The three changeset-review posts (T11), non-blocking for
        # {#post_question}'s reason rather than {#post_render}'s: every one of
        # them is queued from the editor-command consumer's own fiber, serving a
        # gesture the human just made, so a blocking push against a full queue
        # would park the surface that answers every OTHER verb on that rail --
        # including the refusal this one owes them.
        def post_review_sidebar(lines, generation)
          @queue.push(Command.new(args: [lines, generation], lua: SET_REVIEW), true)
        end

        def post_changeset(path, old_lines, line, revisions)
          @queue.push(Command.new(args: [path, old_lines, line, revisions], lua: OPEN_CHANGESET), true)
        end

        def post_thread(anchor_id, lines)
          @queue.push(Command.new(args: [anchor_id, lines], lua: SET_THREAD), true)
        end

        # Send everything currently queued, one nvim_exec_lua notify per
        # command; the caller flushes the connection once, after this returns.
        def drain(client)
          @queue.size.times { send_command(client, @queue.pop) }
        end

        # Release any producer blocked in {#post_render}/{#post_view} with a
        # ClosedQueueError, the same shape {Lain::Channel#close} uses to
        # release its own blocked producers. MUST run once nobody will ever
        # call {#drain} again (RPC-thread death, or normal teardown after the
        # sole producer thread has already stopped) -- see RpcThread's callers.
        def close
          @queue.close unless @queue.closed?
        end

        private

        def send_command(client, command)
          client.session.notify("nvim_exec_lua", command.lua, command.args)
        end
      end

      # The way IN to the editor, for every producer that is not the RPC thread
      # itself: queue the work, wake the loop, and answer whether it landed.
      # {RenderQueue} owns the backlog and its backpressure; this owns the
      # PAIR -- a post that is not followed by a wake is a render that sits
      # until the next backstop tick -- and the one policy that pair needs,
      # which is what a refused post answers.
      #
      # It exists because {RpcThread} had grown five copies of it: two blocking
      # posts and three non-blocking opens, each re-stating the queue call, the
      # wake, and (three times, in two disagreeing ways) what a dead or full
      # queue means. The RPC thread's own responsibility is attach, the select
      # loop, and inbound dispatch; being the door every renderer knocks on is
      # a second one, and this is it.
      class RenderInlet
        # The two surfaces with no view object of their own to keep their
        # sentence in. {Compose::DETACHED} and {QuestionView::DETACHED} live
        # with the objects that answer them; a review has no such half, so its
        # words live here beside the door that speaks them.
        REVIEW_DETACHED = "opening a review in the editor needs an attached editor"

        # The changeset review's three (T11), here for {REVIEW_DETACHED}'s
        # reason -- the objects that will own these surfaces arrive three waves
        # later, and the sentence has to exist the moment the door does. Three
        # sentences and not one shared one, because each names the surface the
        # human was actually using: being told "opening a review needs an
        # attached editor" while trying to read a note is the exact defect the
        # refusal parameter was added to end.
        SIDEBAR_DETACHED = "rendering a changeset review needs an attached editor"
        CHANGESET_DETACHED = "opening a changed file for review needs an attached editor"
        THREAD_DETACHED = "showing a review thread needs an attached editor"

        # The one refusal nobody reads: this leg exists to carry a notice INTO
        # the editor, so its failure is "the notice did not land" and there is
        # no further surface to send it to. Named rather than nil so the four
        # answers are four facts.
        UNREPORTED = "the editor did not take this notice"

        # The backlog is BUILT here rather than injected: {RpcThread} holding
        # both the queue and the door to it was how the five copies got there
        # in the first place. The loop reaches it through {#drain} and
        # {#close}, which is all the loop ever needed from it.
        #
        # @param waker [#call] wakes the select loop; never blocks
        # @param capacity [Integer] see {RenderQueue::DEFAULT_CAPACITY}
        def initialize(waker:, capacity: RenderQueue::DEFAULT_CAPACITY)
          @queue = RenderQueue.new(capacity:)
          @waker = waker
        end

        # The loop's own two messages: send everything queued, and release any
        # blocked producer once nobody will ever drain again (see
        # {RenderQueue#close} for why that MUST happen on death, not only on
        # teardown).
        def drain(client) = @queue.drain(client)
        def close = @queue.close

        # The BLOCKING posts: a background producer outpacing nvim is
        # back-pressured by the queue, and a queue closed by RPC-thread death
        # raises ClosedQueueError through to the caller ({Neovim#post} rescues
        # it, having its own reason to treat the last render as a lost race).
        def post_render(lines) = deliver { @queue.post_render(lines) }

        def post_view(name, lines, editable: false, generation: nil)
          deliver { @queue.post_view(name, lines, editable:, generation:) }
        end

        # The NON-BLOCKING opens. All seven are called from a path that cannot
        # afford to park -- Reline's input loop, the reply consumer's fiber, or
        # (the question) somebody else's lock -- so a full queue refuses instead
        # of blocking, and a refusal is the answer rather than an exception.
        #
        # ONE refusal MECHANISM for all seven, because from the caller's side
        # there is one fact: no editor is taking this. A dead thread (closed
        # queue) and an editor that stopped draining (full queue) are
        # indistinguishable from here, and so is never having attached.
        #
        # The SENTENCE is the caller's, and the argument is REQUIRED so it
        # cannot be forgotten. Every refusal here once read "composing needs an
        # attached editor", which is untrue of a human answering a question; a
        # default kept that defect alive one caller over the moment the
        # parameter was added, so there is no default.
        def open_compose(lines, generation)
          refusable(Compose::DETACHED) { @queue.post_compose(Compose::BUFFER, lines, generation) }
        end

        def open_question(lines, digest)
          refusable(QuestionView::DETACHED) { @queue.post_question(QuestionView::BUFFER, lines, digest) }
        end

        def open_review(path, generation, epic_slug)
          refusable(REVIEW_DETACHED) { @queue.post_review(path, generation, epic_slug) }
        end

        def review_refused(message) = refusable(UNREPORTED) { @queue.post_review_refusal(message) }

        # The changeset review's three (T11). Each answers a refusal rather than
        # raising for the reason above AND one of its own: {Review::Surface} is
        # a port whose adapters DECLINE in words, so a detached editor has to be
        # a value the adapter can hand back, never an exception it has to catch.
        def set_review(lines, generation)
          refusable(SIDEBAR_DETACHED) { @queue.post_review_sidebar(lines, generation) }
        end

        def open_changeset(path, old_lines, line, revisions)
          refusable(CHANGESET_DETACHED) { @queue.post_changeset(path, old_lines, line, revisions) }
        end

        def set_thread(anchor_id, lines) = refusable(THREAD_DETACHED) { @queue.post_thread(anchor_id, lines) }

        private

        def deliver
          yield
          @waker.call
          nil
        end

        def refusable(refusal, &block)
          deliver(&block)
        rescue ClosedQueueError, ThreadError
          refusal
        end
      end

      # The wire shape of the review writes whose answer IS the editor's
      # verdict, read at the boundary and BEFORE any listener runs -- which is
      # what makes "a malformed annotation is not recorded" a fact about the
      # order things happen in rather than a hope about the listener.
      #
      # It is not a second copy of {Review::AnnotationPlaced}'s guard, and the
      # difference is the whole reason it exists. That record judges what the
      # JOURNAL stores; this judges what the EDITOR authored, and it has to
      # judge it HERE, because a refusal is only worth anything while the
      # human's words are still in the buffer.
      #
      # ⚠️ THIS COMMENT ONCE SAID that three of the record's members -- the
      # anchor's id, the revision it was authored against, and whether it
      # drifted -- were "Ruby's own measurements that no editor ever sends". Two
      # thirds of that is now false, and the correction is the point rather than
      # a tidy-up. Only the anchor's `id` is minted here.
      #
      # `revision` is the EDITOR's, off T15's `b:lain_review_revision` stamp, and
      # it has to be: {Review::AnnotationPlaced} carries a revision precisely so
      # that an annotation authored against one diff and submitted against
      # another is DETECTABLE, and that only works if the diff the human was
      # looking at is on the record rather than implied by whatever is on screen
      # at submit time. Resolved here it would be the second thing, which is the
      # live defect in tuicr that member exists to close.
      #
      # `drifted` is the EDITOR's for a harder reason: drift is the anchor text
      # against the line the number NOW names, and that line lives in the buffer
      # the human is looking at -- not in the diff a session holds, not on disk,
      # nowhere Ruby can reach without keeping a copy free to disagree with what
      # is on screen. For a 'fileformat=dos' file it certainly would disagree:
      # nvim strips the carriage returns the buffer never shows while git's bytes
      # carry them, so a Ruby-side comparison reports drift on every line of the
      # file. The measurement is taken where the buffer is.
      #
      # Both were in {KEYS}' blind spot, and a blind spot here is SILENT: this
      # boundary hands on exactly {KEYS} (see {normalized}), so a member the
      # editor sent and this list did not name was dropped on the floor with no
      # refusal and no warning. That is what a missing key costs, from the other
      # direction.
      #
      # THE DROPPED KEY IS THE FAILURE THIS EXISTS FOR, and it is not
      # hypothetical: a nil value removes its key from a lua table entirely
      # (`runtime/65_review.lua` says so, having been bitten), and a hole
      # reaching a listener raises on the RPC thread -- which {RpcThread#answer}
      # answers and then RE-RAISES, ending the session over one bookkeeping
      # slip. A refusal costs the human a retype; a raise costs them the editor.
      #
      # The closed sets are CITED from {Lain::Review}, never restated:
      # `review/vocabulary.rb` exists precisely so a second declaration cannot
      # quietly disagree with the first.
      class ReviewWrite
        # Every key the editor must carry for Ruby to resolve an anchor and a
        # note out of it. `anchor_text` is checked for the KEY and never for
        # content: a blank line in a diff is a real anchorable position -- an
        # added empty line is a change a human may have an opinion about -- which
        # is the same distinction {Review::AnnotationPlaced} draws.
        KEYS = %w[path side line anchor_text text kind revision drifted].freeze

        # The two members the editor authors as free text, against the closed
        # sets they must land in.
        CLOSED = { "side" => :SIDES, "kind" => :ANNOTATION_KINDS }.freeze

        # The three nobody downstream can reconstruct: the file a note is on, the
        # words in it, and the revision it was authored against. All
        # blank-checked; `anchor_text` deliberately is not (see {KEYS}).
        NAMED = {
          "path" => "an annotation must name the file it is on",
          "text" => "an annotation with nothing in it records no opinion",
          "revision" => "an annotation that names no revision names no diff, so nothing can tell later " \
                        "whether it was authored against the diff it was submitted against"
        }.freeze

        # THE ARGUMENTS THEMSELVES ARE A SHAPE, and checking it is not
        # paranoia. `runtime/65_review.lua:75-79` records a verb sending FLAT
        # POSITIONALS and everything after the first being dropped on the floor;
        # T14, T15 and T18 write the next three lua halves against this
        # contract. `args.first` on a bare String answers a CHARACTER and on an
        # Integer raises NoMethodError -- inside the one guard whose entire
        # purpose is that the wire can never raise, which {RpcThread#answer}
        # then answers and re-raises, ending the session over a lua typo. A
        # flat Hash survived only because `Hash#first` happens to exist, which
        # is luck rather than defence.
        def self.flat(args)
          "a review write's arguments must arrive as ONE array holding the payload, which is the shape every " \
            "verb on this rail uses -- flat positionals silently drop everything after the first. Got " \
            "#{args.inspect}"
        end
        private_class_method :flat

        # @param args [Array, nil] the verb's ONE array of arguments; the note is
        #   its sole member, String-keyed as it crossed msgpack
        # @yieldparam note [Hash] the note, NORMALIZED (see {normalized})
        # @return [String, nil] the refusal the editor must fail its write with,
        #   or whatever the block answered
        def self.annotation(args)
          return flat(args) unless args.is_a?(Array)

          note = args.first
          refused(note) || yield(normalized(note))
        end

        # The batch `:LainNoteDone` settles (T16): one gesture carrying every note
        # the human placed, across both sides and every file they visited, IN
        # PLACEMENT ORDER -- which is the output, since nothing else records
        # which note they wrote first.
        #
        # ATOMIC AT THIS BOUNDARY, AND ONLY AT THIS BOUNDARY. Be exact about the
        # scope, because the natural summary ("the batch is atomic") is false one
        # step further on.
        #
        # What holds: EVERY note is judged before ANY is delivered, so a payload
        # this object refuses -- a bad kind, a dropped key, an impossible line,
        # anywhere in the batch -- delivers nothing at all. That ordering is the
        # whole difference between this and a loop over {annotation}, and it
        # matters because half a review recorded with a refusal covering the rest
        # is the one outcome a human cannot act on: they cannot tell which half
        # to retype.
        #
        # What does NOT hold: a LISTENER that takes the first note and refuses
        # the second leaves the first delivered. This method stops at that
        # refusal and answers it, `48_annotate.lua` keeps every note (its
        # `forget` sits past the `pcall`, deliberately), and the human's retry
        # therefore delivers the first note a SECOND time. Nothing here can
        # prevent that -- undoing a delivery is the consumer's to offer.
        #
        # It is unreachable today only because both bound reviews refuse
        # UNIFORMLY ({Neovim::NoReviewWrites} answers every note the same
        # sentence), so the first note refuses and nothing lands. That is a
        # property of today's consumers, not of this code, so it is written down
        # rather than assumed: a consumer bound here must either refuse uniformly
        # or take the batch whole.
        #
        # Delivered note by note to the SAME hand-off {annotation} uses, rather
        # than as a batch to a listener method of its own. A batch-shaped method
        # would have to be added to {Listener}, {Listener::Null},
        # {Neovim::FrontendListener} and {Neovim::NoReviewWrites} before anything
        # could receive it -- four sites, all of them dead until someone
        # implements the fifth. This reaches the bound review through wiring that
        # already exists, and it is per-note downstream anyway. The batch is not
        # lost by it: one write, one verdict, and the deliveries happen in the
        # order the payload carried. That trade holds precisely as long as the
        # paragraph above does.
        #
        # @param args [Array, nil] the verb's ONE array of arguments; the batch is
        #   its sole member, an Array of notes
        # @yieldparam note [Hash] each note, NORMALIZED, in placement order
        # @return [String, nil] the first refusal, or nil once every note is taken
        def self.notes(args)
          return flat(args) unless args.is_a?(Array)

          batch = args.first
          return unbatched(batch) unless batch.is_a?(Array)

          refused_batch(batch) || batch.lazy.map { |note| yield(normalized(note)) }.find(&:itself)
        end

        # The flat-payload refusal one level in, and it earns its own message.
        # {flat} catches `rpcrequest(..., verb, payload)` where the ARGUMENTS are
        # not an array; this catches `rpcrequest(..., verb, note)` where they are,
        # but hold a bare note instead of the batch -- the shape a lua half gets
        # by dropping one pair of braces, which reads as a single-note write and
        # would otherwise be half-accepted.
        def self.unbatched(batch)
          "a settled review's payload must be the ARRAY of notes, even when there is one of them or none: " \
            "one gesture carries every note the human placed, and the order it carries them in is the only " \
            "record of which they wrote first. Got #{batch.inspect}"
        end
        private_class_method :unbatched

        # Lazy so a malformed note stops the scan, and `first` so the human is
        # told ONE thing to go fix rather than a list.
        def self.refused_batch(batch)
          batch.lazy.filter_map { |note| refused(note) }.first
        end
        private_class_method :refused_batch

        # @param args [Array, nil] the verb's one array of arguments, holding the
        #   verdict alone
        # @return [String, nil] as {annotation}
        def self.verdict(args)
          return flat(args) unless args.is_a?(Array)

          given = Lain::Review::Wire.token(args.first)
          return yield(given) if Lain::Review::VERDICTS.include?(given)

          "this review's verdict must be #{Lain::Review::VERDICTS.join("/")} -- the vocabulary is settled in " \
            "Lain::Review::VERDICTS, not by what an editor sends -- got #{args.first.inspect}"
        end

        # The note as the rest of lain will see it: tokens interned and stripped
        # of the whitespace a wire adds, text interned and NEVER stripped (an
        # anchored line's indentation is precisely the evidence a drift check
        # compares). Normalizing HERE is what makes
        # {Review::AnnotationPlaced}'s own normalization idempotent rather than
        # the only thing standing between a `" new "` off the wire and a side
        # nothing recognises -- and it is what the verdict verb has always
        # done, so the two verbs now answer alike.
        #
        # Exactly {KEYS}, never the note as it arrived: an extra key is either
        # noise or a version skew, and passing one through would let a later
        # reader act on a field this boundary never judged.
        def self.normalized(note)
          { "path" => Lain::Review::Wire.token(note["path"]),
            "side" => Lain::Review::Wire.token(note["side"]),
            "line" => note["line"],
            "anchor_text" => Lain::Review::Wire.text(note["anchor_text"]),
            "text" => Lain::Review::Wire.text(note["text"]),
            "kind" => Lain::Review::Wire.token(note["kind"]),
            "revision" => Lain::Review::Wire.token(note["revision"]),
            # NOT normalized, and there is nothing to normalize: it is a boolean,
            # already refused by {unmeasured} unless it is exactly one.
            #
            # What `Wire.token` would do to it is ASYMMETRIC, and the asymmetry
            # is the whole hazard. It is `value && -value.to_s.strip`, so `false`
            # SHORT-CIRCUITS on the `&&` and comes back untouched, while `true`
            # becomes the String `"true"` -- which {Review::AnnotationPlaced}'s
            # `inclusion: [true, false]` refuses, and which no identity test
            # matches. Tokenizing here would therefore leave the answer MOST
            # notes give perfectly intact and corrupt only the DRIFTED ones:
            # nothing would look wrong until a note actually drifted, which is
            # the first moment anybody needs this field to be right.
            "drifted" => note["drifted"] }
        end
        private_class_method :normalized

        # @return [String, nil] the first thing wrong with the note, or nil
        def self.refused(note)
          return "a review annotation must arrive as a table of #{KEYS.join(", ")}, got #{note.inspect}" unless
            note.is_a?(Hash)

          dropped(note) || unknown(note) || impossible_line(note) || unmeasured(note) || blank(note)
        end
        private_class_method :refused

        # `drifted` is a MEASUREMENT, taken in the editor because that is the only
        # place the line it compares against exists (see the class comment).
        #
        # REFUSED, NEVER COERCED, and the difference is the whole reason this is a
        # method rather than a truthiness test at the call site.
        # {Review::AnnotationPlaced} gives `drifted` no default precisely so a
        # caller that never compared cannot journal "did not drift" -- a reading
        # no later audit can tell from a real one. A truthiness test here would
        # hand that default straight back: a dropped key is nil is false, which is
        # the answer most notes give and so the one nobody would ever question.
        #
        # {dropped} already catches the key going missing; this catches it
        # arriving as something that is not a measurement -- a `"false"` off a
        # wire that stringified it, most of all, since that is TRUE to anything
        # testing it loosely.
        def self.unmeasured(note)
          return nil if [true, false].include?(note["drifted"])

          "this annotation's drifted must be true or false -- it is the editor's measurement of whether the " \
            "line still says what the note was anchored to, and a note nobody measured must not be recorded " \
            "as one that did not drift. Got #{note["drifted"].inspect}"
        end
        private_class_method :unmeasured

        def self.dropped(note)
          missing = KEYS.reject { |key| note.key?(key) }
          return nil if missing.empty?

          "this annotation reached lain without #{missing.join(", ")}, so nothing was recorded and your text " \
            "is untouched"
        end
        private_class_method :dropped

        # Names the value it JUDGED, in `inspect` form, for {Review::Wire.refusal}'s
        # reason: "must be one of old/new" without saying what arrived sends a
        # reader looking for a value they did not send.
        def self.unknown(note)
          CLOSED.filter_map do |field, set|
            members = Lain::Review.const_get(set)
            unless members.include?(Lain::Review::Wire.token(note[field]))
              "this annotation's #{field} must be one of #{members.join("/")}, got #{note[field].inspect}"
            end
          end.first
        end
        private_class_method :unknown

        # `line` is the one member with a DOMAIN rather than a vocabulary, and
        # the domain is {Review::Anchor}'s -- ASKED here, never restated, so
        # there is one definition of a position that cannot exist. 0 is the
        # value that actually hurts: T2's hunk arithmetic makes `lines[-1]` out
        # of it and answers "not drifted" for a position nobody named.
        #
        # It has to be asked HERE because downstream says the same thing by
        # RAISING -- `WireInteger.read` on `"abc"` or `0` is an ArgumentError,
        # and an ArgumentError out of a listener is answered and then re-raised,
        # ending the session. Same rule, one boundary earlier, where it can
        # still be a refusal the human can act on.
        def self.impossible_line(note)
          Lain::Review::Anchor.line!(note["line"])
          nil
        rescue Lain::Review::Anchor::InvalidLine => e
          "this annotation's #{e.message}"
        end
        private_class_method :impossible_line

        # The members nobody downstream can reconstruct. {Blankness}, not
        # `strip`, because a lone U+00A0 satisfies `strip` and says nothing.
        def self.blank(note)
          NAMED.filter_map do |field, claim|
            "#{claim}, so nothing was submitted and your text is untouched" if Blankness.blank?(note[field])
          end.first
        end
        private_class_method :blank
      end

      # Which of the frontend's OWN reactions an inbound editor command
      # triggers. Split out of {RpcThread} when the compose round trip made it
      # the third verb it had to know about: routing is a table of verbs, the
      # RPC thread is a socket and a select loop, and the two only ever met
      # because both were in the same class.
      #
      # An ACKED command lands in {RpcThread#command_inbox} regardless of what
      # happens here (a future agent-side consumer may want it), and its route
      # runs AFTER the ack, so a slow hand-off never delays the editor. A verb
      # no route claims falls through silently -- the editor's commands are not
      # this object's to validate.
      #
      # An ANSWERED command is the other kind, and there are three (T12, T11).
      # Its route's RETURN VALUE is what the editor gets, so it must run BEFORE
      # any ack -- a question `:w` is refused when the document does not parse,
      # and a refusal that arrived after a `true` would be a buffer marked saved
      # over text the grammar rejected. Two tables rather than a flag, because
      # the two kinds differ in every respect that matters: when the route runs,
      # what the editor is told, and whether the inbox ever sees it.
      #
      # The three are exactly the gestures lain can REFUSE. A review's five
      # verbs split on that one question and on nothing else: opening a row,
      # marking a hunk and asking a docent are hand-offs nothing here can turn
      # down, so they take the acked path to the command inbox like `reply` and
      # `open` before them, while an annotation and a verdict are WRITES whose
      # `:w` has to fail with the human's text still in front of them.
      class Router
        # Each route is handed the WHOLE command and destructures it itself,
        # because the verbs genuinely differ in what they carry: resend sends
        # lines, a compose write sends lines plus the generation it answers, an
        # abandon sends only that generation.
        #
        # @param listener [RpcThread::Listener] duck: #resend(lines),
        #   #compose_written(lines, generation), #compose_abandoned(generation),
        #   #question_written(lines, digest), #question_abandoned(digest),
        #   #review_annotated(note), #review_verdict_given(verdict).
        #   {RpcThread} is the only caller and always resolves one first (real
        #   or {RpcThread::Listener::Null}), so there is no default here.
        def initialize(listener:)
          @routes = acked(listener)
          @answers = answered(listener)
        end

        # @param arguments [Array] the command as the editor sent it: the verb,
        #   then whatever that verb carries
        def call(arguments) = @routes[arguments.first]&.call(arguments)

        def answers?(verb) = @answers.key?(verb)

        # @return [String, nil] the failure the editor must fail its write with,
        #   or nil once the command has been taken
        def answer(arguments) = @answers.fetch(arguments.first).call(arguments)

        private

        def acked(listener)
          {
            "resend" => ->(args) { listener.resend(args[1] || []) },
            "compose" => ->(args) { listener.compose_written(args[1] || [], args[2]) },
            "compose_abandon" => ->(args) { listener.compose_abandoned(args[1]) },
            "question_abandon" => ->(args) { listener.question_abandoned(args[1]) }
          }.freeze
        end

        # A question's payload is LINES, which no boundary object judges -- the
        # grammar does, later, and its refusal is the view's. Every review write
        # goes through {ReviewWrite} instead, which is a real seam and not merely
        # a way to keep this method short: see {review_writes}.
        def answered(listener)
          { "question" => ->(args) { listener.question_written(args[1] || [], args[2]) } }
            .merge(review_writes(listener)).freeze
        end

        # The review writes, which share one thing the question verb does not:
        # each reads its payload through {ReviewWrite} FIRST, so a malformed
        # write never reaches the listener at all and "the annotation is not
        # recorded" is the shape of the code rather than a promise about it.
        #
        # `review_notes` is T16's `:LainNoteDone` -- the whole settled batch,
        # answered once. It is kept BESIDE `review_annotate` rather than
        # replacing it (T22's prefill may want the per-note form), and the two
        # land on the SAME hand-off, so a review binds one object and answers
        # both rails.
        def review_writes(listener)
          # Named once because it IS one hand-off: a note reaching lain alone and
          # a note reaching it inside a settled batch are the same note, and a
          # review that answered them differently would be answering the gesture
          # rather than the note.
          annotated = ->(note) { listener.review_annotated(note) }
          { "review_annotate" => ->(args) { ReviewWrite.annotation(args[1], &annotated) },
            "review_notes" => ->(args) { ReviewWrite.notes(args[1], &annotated) },
            "review_verdict" => lambda { |args|
              ReviewWrite.verdict(args[1]) { |verdict| listener.review_verdict_given(verdict) }
            } }
        end
      end

      # The single thread that owns the nvim RPC session -- exactly one, because the
      # neovim gem's {::Neovim::Session} is single-threaded by construction
      # (`main_thread_only` raises off-thread). It attaches over a unix socket,
      # injects the runtime once ({RuntimeLoader}), then runs ONE select loop that both serves
      # inbound requests from the editor and drains queued render work outbound --
      # the two directions the gem forces onto one thread (ROADMAP § Interface,
      # verified in planning/rpc_direction_probe.rb).
      #
      # The load-bearing gem traps this is built around:
      #
      # * Every touch of the session happens HERE. Other threads hand render work
      #   in through {#post_render} (a queue plus a wake pipe) and drain inbound
      #   commands from {#command_inbox}; they never call nvim themselves.
      # * The gem flushes writes only on the loop's NEXT read. This loop reads only
      #   when the socket is readable (it must also stay free to render), so it
      #   cannot lean on that -- it flushes the connection by hand after every
      #   write. That is why it constructs the {::Neovim::Connection} itself and
      #   keeps the handle rather than going through {::Neovim.attach_unix}.
      # * Renders go out as NOTIFICATIONS, not requests: a request would nest a
      #   read (waiting its response) that could swallow an inbound request into the
      #   session's pending queue. A notify plus a hand flush keeps reads confined
      #   to {#serve_inbound}, so the session's pending queue stays empty.
      # * Inbound requests are enqueue-and-acked in microseconds -- a slow response
      #   freezes the EDITOR -- so agent work never runs inline here.
      class RpcThread
        extend Forwardable

        # The four hand-offs this thread makes back to its owner: RPC-thread
        # death, an edited lain://request, and lain://compose being written or
        # abandoned. One object with four named methods rather than four
        # positional callbacks -- a caller states its reaction to each as a
        # method instead of a hand-defaulted lambda, and gets {Null} for free
        # when it wants none of them (the {Sink::Null} shape).
        #
        # `compose_written`/`compose_abandoned` are deliberately two methods,
        # not one taking a verb argument: they are two different things that
        # happened -- a write and an abandon carry different data (lines
        # plus a generation, vs. just a generation) -- and a caller forced to
        # branch on a symbol would only be re-deriving what {Router} already
        # knows from the wire.
        class Listener
          # RPC-thread death, after {RpcThread#start} has returned. An attach
          # failure rides {#start}'s own return instead (see
          # {RpcThread#record_death}), so this never fires for one.
          def died
            raise NotImplementedError, "#{self.class} must implement #died"
          end

          # @param lines [Array<String>] the edited lain://request lines (4-2.3)
          def resend(lines)
            raise NotImplementedError, "#{self.class} must implement #resend"
          end

          # @param lines [Array<String>] the edited lain://compose lines (T15)
          # @param generation [Integer] which compose the editor is answering
          def compose_written(lines, generation)
            raise NotImplementedError, "#{self.class} must implement #compose_written"
          end

          # @param generation [Integer] which compose was unloaded unwritten
          def compose_abandoned(generation)
            raise NotImplementedError, "#{self.class} must implement #compose_abandoned"
          end

          # The ONE hand-off whose RETURN VALUE the editor waits on (T12): the
          # human wrote lain://question, and this answers whether the document
          # parsed. It runs before the ack and inside nvim's own `:w`, so it
          # must not block for the usual reason AND must not raise -- a raise
          # here would kill the session over a mistyped line, which is why
          # {QuestionView#wrote} returns its failure instead.
          #
          # @param lines [Array<String>] the buffer as the human left it
          # @param digest [String] the set this buffer was opened for
          # @return [String, nil] the failure naming the offending line, or nil
          def question_written(lines, digest)
            raise NotImplementedError, "#{self.class} must implement #question_written"
          end

          # @param digest [String] the set whose buffer was unloaded unwritten
          def question_abandoned(digest)
            raise NotImplementedError, "#{self.class} must implement #question_abandoned"
          end

          # The changeset review's two ANSWERING hand-offs (T11), under
          # {#question_written}'s whole contract: each runs before the ack and
          # inside nvim's own `:w`, so neither may block and neither may raise --
          # the refusal is a value. The note has already been read for SHAPE by
          # {ReviewWrite}; what is left to judge is whether this review can take
          # it, which only the session that owns the changeset knows.
          #
          # @param note [Hash] the annotation as it crossed the wire, String-keyed
          # @return [String, nil] the failure the write must fail with, or nil
          def review_annotated(note)
            raise NotImplementedError, "#{self.class} must implement #review_annotated"
          end

          # Answered rather than acked because a verdict can be INADMISSIBLE --
          # an approve standing over unreviewed hunks is the policy's call -- and
          # a refusal that arrived after a `true` would be a review recorded as
          # closed over a judgement nothing accepted.
          #
          # @param verdict [String] one of {Lain::Review::VERDICTS}
          # @return [String, nil] the failure the write must fail with, or nil
          def review_verdict_given(verdict)
            raise NotImplementedError, "#{self.class} must implement #review_verdict_given"
          end

          # The no-op Listener, mirroring {Sink::Null}: satisfies the same duck
          # so an {RpcThread} (or {Router}) built with none of these reactions
          # wired never needs an `if listener` guard. The default for both.
          class Null < Listener
            # The ONE hand-off a Null must not answer with silence. nil means
            # "taken" to the editor, which clears 'modified' and reports the
            # human's text saved -- and `bufhidden = "hide"` means a
            # lain://question buffer OUTLIVES the attach that made it, so a
            # write really can arrive at a frontend wiring no view. Every other
            # answer here is a no-op because nothing downstream reads it.
            UNANSWERABLE = "this editor has no question surface wired, so there is no set to answer -- " \
                           "nothing was submitted and your text is untouched"

            # {UNANSWERABLE}'s reason for the review pair (T11), and it reaches
            # further: a `nofile` review buffer outlives its attach just as a
            # question buffer does, and both review writes ANSWER -- so nil here
            # would clear 'modified' and report a note recorded by a frontend
            # with nowhere on earth to put it. One sentence for the two because
            # it is one fact: nothing here holds a review.
            UNREVIEWABLE = "this editor has no review surface wired, so there is nothing to record it against -- " \
                           "nothing was submitted and your text is untouched"

            def died = nil
            def resend(_lines) = nil
            def compose_written(_lines, _generation) = nil
            def compose_abandoned(_generation) = nil
            def question_written(_lines, _digest) = UNANSWERABLE
            def question_abandoned(_digest) = nil
            def review_annotated(_note) = UNREVIEWABLE
            def review_verdict_given(_verdict) = UNREVIEWABLE
          end
        end

        # The injected chunk is assembled from runtime.lua plus runtime/*.lua --
        # see {RuntimeLoader} for why it is concatenated rather than required.
        RUNTIME = RuntimeLoader.new.freeze

        # How long the readable-wait may block before re-checking the stop flag and
        # the render queue. The wake pipe is the real signal (posts and stop both
        # write it), so this is a pure liveness net bounding recovery from a lost
        # wakeup. It cannot serve a message the msgpack unpacker has already
        # buffered -- a timeout tick performs no read; what prevents buffered-
        # message starvation is nvim itself, which serializes blocking rpcrequests
        # (an unanswered one blocks the editor from sending another).
        BACKSTOP_SECONDS = 0.05

        # @param socket_path [String] a listening nvim's unix socket
        # @param version [String] the gem version, surfaced by :LainVersion
        # @param protocol [String] the runtime.lua handshake token (see {PROTOCOL})
        # @param listener [Listener] this thread's four hand-offs, bundled into
        #   one object (see {Listener}'s own comment for why). Every method
        #   MUST NOT block this thread: each runs inline after the microsecond
        #   ack, so a listener that needs to do real work hands off to a
        #   worker via a non-blocking queue (never straight onto a bounded
        #   Channel, which could wedge this thread against a full render
        #   queue). Defaults to {Listener::Null}, so a caller that wants none
        #   of the four reactions wires nothing.
        # @param render_capacity [Integer] see {RenderQueue::DEFAULT_CAPACITY};
        #   overridable so a spec can saturate the queue at a scale that runs fast
        def initialize(socket_path:, version: Lain::VERSION, protocol: PROTOCOL,
                       listener: Listener::Null.new,
                       render_capacity: RenderQueue::DEFAULT_CAPACITY)
          @socket_path = socket_path
          @version = version
          @protocol = protocol
          @listener = listener
          @router = Router.new(listener:)
          @command_inbox = Thread::Queue.new
          @wake_read, @wake_write = IO.pipe
          @inlet = RenderInlet.new(waker: method(:wake), capacity: render_capacity)
          @ready = Thread::Queue.new
          @stopped = @announced = false
        end

        # The exception that killed the serving loop after {#start}, or nil while
        # it lives. {Neovim#run} re-raises it so editor death is loud.
        # @return [StandardError, nil]
        attr_reader :failure

        # Commands the editor invoked and this thread enqueue-and-acked, for an
        # agent-side consumer to drain. A queue, never the session.
        # @return [Thread::Queue]
        attr_reader :command_inbox

        # Start the thread and block until it has attached and injected the runtime
        # (or re-raise whatever attach failed with, on the caller's thread).
        # @return [self]
        def start
          @thread = Thread.new { life }
          outcome = @ready.pop
          raise outcome if outcome.is_a?(Exception)

          self
        end

        # Every way IN to the editor, delegated whole to the object that owns
        # the queue-and-wake pair ({RenderInlet}, which documents each). Safe
        # from any thread: they touch only the {RenderQueue} and the wake pipe,
        # never nvim.
        def_delegators :@inlet, :post_render, :post_view, :open_compose, :open_question, :open_review,
                       :review_refused, :set_review, :open_changeset, :set_thread

        # Stop the loop, wake it out of its select, join, and close the fds this
        # thread owns. Idempotent enough for a defensive double call.
        # @return [void]
        def stop
          @stopped = true
          wake
          @thread&.join
          @inlet.close
          [@socket, @wake_read, @wake_write].each { |io| io.close unless io.nil? || io.closed? }
        end

        private

        # The wake pipe is a SIGNAL, not a queue: one unread byte already means
        # "work pending", so a full pipe needs no further write -- and MUST not
        # get one, or a producer would block against a loop that has died (the
        # teardown-hang bug: nvim dies -> loop exits -> nobody drains the pipe ->
        # a blocking write here wedges the drainer, and run's join never returns).
        def wake
          @wake_write.write_nonblock(".")
        rescue IO::WaitWritable, IOError, Errno::EPIPE
          # Full pipe: the loop is already signalled, the byte would be redundant.
          # Closed pipe: the loop is gone and there is nobody left to wake.
        end

        def life
          attach
          @announced = true
          @ready.push(:ready)
          serve until @stopped
        rescue StandardError => e
          record_death(e)
        end

        # Before {#start} has returned, the error rides @ready and re-raises on
        # the caller's thread. After, @ready has no reader ever again -- record
        # the failure where {#failure} exposes it and tell the owner, or the
        # death would be silent and the frontend a zombie.
        #
        # Closing the {RenderQueue} HERE (not only in {#stop}) is what keeps a
        # bounded queue from re-creating the teardown-hang bug the wake pipe
        # already dodges: once this loop is dead, nobody will ever {RenderQueue#drain}
        # again, so a producer mid-post against a full queue would block
        # forever without this (see {RenderQueue#close}).
        def record_death(error)
          @failure = error
          @inlet.close
          @announced ? @listener.died : @ready.push(error)
        end

        # Build the client by hand rather than via {::Neovim.attach_unix} so we keep
        # the socket (to `IO.select` on) and the connection (to flush by hand). This
        # is the public seam {::Neovim.attach} itself uses -- one blocking
        # `nvim_get_api_info` request that self-flushes -- minus the optional
        # client-info notify we do not need.
        #
        # THE INJECTION ANSWERS, and a non-nil answer is a refusal: the runtime
        # declines to load into an editor a live lain already owns (see
        # {SocketOwned}, and runtime.lua's head for the check). It is the chunk's
        # return value rather than a probe of our own because the decision has to
        # be taken INSIDE the injection -- anything asked beforehand is a
        # check-then-act with a whole round trip in the gap, and the thing it
        # would race is a second lain doing the same.
        #
        # The raise lands on this thread inside {#life}, so it rides
        # {#record_death}'s pre-announcement path and re-raises on the caller's
        # thread out of {#start} -- the same way a missing socket already does.
        def attach
          @socket = Socket.unix(@socket_path)
          @connection = ::Neovim::Connection.new(@socket, @socket)
          @client = ::Neovim::Client.from_event_loop(::Neovim::EventLoop.new(@connection))
          refusal = @client.exec_lua(RUNTIME.source, [@version, @protocol, @client.channel_id])
          raise SocketOwned.new(@socket_path, refusal["channel"]) unless refusal.nil?
        end

        def serve
          drain_renders
          ready, = IO.select([@socket, @wake_read], nil, nil, BACKSTOP_SECONDS)
          react(ready) if ready
        end

        def react(ready)
          clear_wake if ready.include?(@wake_read)
          serve_inbound if ready.include?(@socket)
        end

        def drain_renders
          @inlet.drain(@client)
          @connection.flush
        end

        def clear_wake
          @wake_read.read_nonblock(4096)
        rescue IO::WaitReadable
          # Spurious wakeup -- the pipe had nothing buffered. Nothing to do.
        end

        def serve_inbound
          message = @client.session.next
          dispatch(message) if message.respond_to?(:sync?) && message.sync?
        end

        # Every editor command reaches this thread as an ordinary `lain_command`
        # rpcREQUEST -- the compose and question round trips' return legs
        # included -- so nothing here handles notifications and this thread's
        # single-owner discipline is untouched. What differs is WHEN the route
        # runs relative to the ack, and {Router} owns that distinction.
        def dispatch(request)
          return respond(request.id, nil, "lain: unknown request #{request.method_name}") unless
            request.method_name == "lain_command"

          @router.answers?(request.arguments.first) ? answer(request) : acknowledge(request)
        end

        # The ordinary path: enqueue-and-ack in microseconds, react afterwards,
        # so a slow hand-off never freezes the editor.
        def acknowledge(request)
          @command_inbox.push(request.arguments)
          respond(request.id, true)
          @router.call(request.arguments)
        end

        # The answered path (T12), and the ONLY place a route runs before the
        # ack. A question `:w` is the one editor gesture lain can refuse, so its
        # answer IS the response: a failure comes back as the request's error,
        # which is what makes the write fail and leaves the buffer modified with
        # the human's text. It stays OUT of the command inbox on purpose -- what
        # a consumer wants is the parsed answer set, which the view hands on
        # itself once the document is taken, not the raw lines it refused.
        #
        # THE RESCUE IS THE ORDERING'S PRICE. {#acknowledge} is structurally
        # immune to a raising listener -- the editor already has its answer --
        # and inverting that order inherits the obligation to answer anyway.
        # Measured without it: a listener raising NoMethodError left nvim
        # blocked in `vim.rpcrequest` for over 20 seconds, main loop frozen and
        # the human unable to type, unblocking only when the whole session tore
        # down. {Listener#question_written}'s doc has always said "must not
        # raise"; a comment is not a guard, least of all on the one path where a
        # Ruby exception freezes the editor.
        #
        # It answers a REFUSAL naming the internal error rather than an ack: a
        # frozen editor and a silently-swallowed bug are both worse than a
        # visible failure, and an ack here would clear 'modified' over text
        # nothing consumed. The raise then continues, so the death is still
        # recorded and still loud ({#record_death}).
        # `StandardError` ALONE WAS NOT THE WHOLE OBLIGATION, and the gap was
        # the one class most likely to arrive: `NotImplementedError` is a
        # `ScriptError`, so a listener that has not implemented a hand-off --
        # which is exactly what {Listener}'s abstract base raises, on three
        # methods now -- walked straight past this rescue and the editor was
        # never answered AT ALL. That is the >20-second frozen nvim measured
        # below, reached by the one exception the guard could not see.
        # `ScriptError` rather than `NotImplementedError` because `LoadError`
        # from an autoload inside a listener freezes the editor identically,
        # and `Exception` is still refused: `Interrupt` and `SignalException`
        # must keep climbing.
        def answer(request)
          failure = @router.answer(request.arguments)
          failure.nil? ? respond(request.id, true) : respond(request.id, nil, failure)
        rescue StandardError, ScriptError => e
          respond(request.id, nil, "lain: #{e.class} answering this write, so nothing was submitted and your " \
                                   "text is untouched (#{e.message})")
          raise
        end

        # Answer an inbound request, then flush by hand -- the gem otherwise defers
        # the write to the next read, which this loop may not reach until more
        # editor traffic arrives, freezing the editor on its rpcrequest.
        def respond(id, value, error = nil)
          @client.session.respond(id, value, error)
          @connection.flush
        end
      end
    end
  end
end
