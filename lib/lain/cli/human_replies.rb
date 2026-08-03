# frozen_string_literal: true

module Lain
  module CLI
    # The human-reply surfaces (I6), lifted out of Repl the way Wiring lifted
    # chat assembly: answering ask_human is its own responsibility -- the
    # arrival note, the `/inbox` drain, and the editor's :LainReply leg -- and
    # the Metrics trip said so.
    #
    # Every answer NAMES the set it answers (T11). This class holds the run's
    # {Tools::AskHuman::Directory}, not one asker, and routes by the digest the
    # arrival carried: which asker holds the named set is the directory's
    # question, and answering it from "the asker this class happens to hold"
    # is how a child's question becomes unanswerable while the parent has
    # nothing pending. The digest is also what RETIRES the item -- the item an
    # answer belongs to need not be the one at the head of the list.
    class HumanReplies
      # I6: one pending human question as the drain surface lists it -- who is
      # stuck (the asker's chain correlation), since when, the question, and
      # (T11) the name an answer must cite to reach it.
      InboxItem = Struct.new(:question, :from, :digest, :asked_at, keyword_init: true) do
        # The arrival, built from the Q event that has just been written --
        # {Wiring::Askers#announce}'s one call, and the only moment BOTH
        # attributions are true. Read at drain time instead, `from` is
        # whoever asked most recently and the digest is not recoverable at
        # all.
        # `agent` wins over the event's own `from` because `from` is the chain's
        # ROOT digest, and an `:inherit` child forks its parent -- so the two
        # share a root and are permanently indistinguishable at every surface
        # that renders the sender. `:inherit` is the DEFAULT for a @role spawn,
        # so that is the common case, not an edge one. The asker's name is the
        # honest identifier and was already carried this far for the desktop
        # notification; it just stopped there.
        def self.asked(question, event, agent: nil)
          named = Blankness.blank?(agent) ? event.from : agent
          new(question:, from: named, digest: event.digest, asked_at: Time.now)
        end
      end

      # No item to answer: an editor reply that named nothing, with nothing
      # listed to mean. It answers the one message a caller asks of an item,
      # with a name no registered asker can hold -- so the refusal comes back
      # from the directory, in the words a human at a reply prompt needs,
      # rather than from a nil check here.
      module Unlisted
        def self.digest = nil
      end

      # How long the editor consumer parks between empty polls. The rail is a
      # Thread::Queue popped non-blockingly (a blocking pop would freeze the
      # reactor thread), so the tick is what keeps the fiber cheap.
      IDLE_TICK = 0.1

      # The editor that is not there ({Sink::Null}'s shape): nothing ever
      # arrives on its rail and a refusal has nowhere to render. It exists so
      # that neither the consumer loop nor the refusal path asks whether an
      # editor was bound -- the question is answered once, in {#bind_editor}.
      # `attached?` is the one distinction still worth drawing: a fiber polling
      # a rail nothing can ever reach is pure cost, so it is never spawned.
      module NoEditor
        def self.pop(*) = nil
        def self.review_refused(_message) = nil
        def self.attached? = false
      end

      # `ask_human:` is the ask_human REPLY SEAM -- whatever answers
      # `#reply(answer, digest)` for the set a digest names. Production hands
      # over the run's {Tools::AskHuman::Directory} (many askers, one routing
      # table); a single-asker caller may hand over a lone
      # {Tools::AskHuman}, which answers the same message with the same two
      # refusals. Which object it is has stopped mattering here, which is the
      # point: this class no longer knows or cares WHICH agent is stuck.
      def initialize(tty:, conductor:, ask_human:, questions:)
        @tty = tty
        @ask_human = ask_human
        @questions = questions
        @editor = NoEditor
        @reviews = {}
        @inbox = Pending.new
        @reply = Reply.new(tty:, conductor:, inbox: @inbox)
      end

      # The editor's command rail -- :LainReply and :LainReviewDone -- bound
      # before converse runs so #editor_reply_loop knows whether to spawn its
      # consumer fiber. The frontend hands over its own inbox adapter, or nil
      # when no editor is attached; that is the ONE nil check in this class,
      # and it lives here so no other line has to repeat it.
      def bind_editor(editor) = @editor = editor || NoEditor

      # Hold a review open for the editor's `done` gesture to settle. Keyed on
      # the PAIR the wire carries -- a bare generation cannot say which epic it
      # means, and two epics both hand out 1 (see {Epic::Review}).
      #
      # The generation goes through {Epic::WireInteger} on BOTH sides of this
      # lookup, because a key read two ways is a key that misses: `.to_i` turns
      # `"7abc"` and `7.9` into 7 and `nil` into 0, so a shallow reading here
      # would name somebody else's review rather than refuse.
      def bind_review(review, token:)
        @reviews[review_key(token.epic_slug, token.generation)] = [review, token.path]
      end

      # A human question is waiting for an answer: an item mid-drain (@inbox) or
      # one a subagent enqueued while the human sat idle at `you>`, which no
      # answer_loop fiber is watching between asks. T21's standing-goal driver
      # reads this to hold off re-prompting while the fleet is unquiet -- the
      # inbox half of that guard (the parked-approval half lives in Wiring).
      def pending? = !@inbox.empty? || !@questions.empty?

      # `/inbox` at `you>` (T13): the SAME TTY drain UX #answer_loop's
      # read_drained_answer calls at `human>`, over whatever has piled up in
      # `@questions` since the last time a fiber was actually watching it.
      # #answer_loop's fiber only lives DURING a respond() call (Repl#respond
      # starts it alongside the ask, per {#surfaces}); the OM-6 supervisor's
      # fleet outlives any one ask, so a subagent's `announce` can enqueue a
      # question while the human sits idle at `you>` with nothing draining
      # it. This is that second watcher, run on demand instead of a second
      # background fiber.
      #
      # Lists every item (gathered non-blockingly first, so a `you>`-time
      # `/inbox` shows the WHOLE backlog, not just the head), reads exactly
      # ONE answer ({Reply}'s own contract), and resolves it through the SAME
      # reply seam the human> path uses -- never a second answer path. The
      # listing offers no selection, so what one typed answer answers here is
      # the OLDEST item listed: nothing is parked on this read, so the first
      # line the human read is the only thing it can mean. {Reply} hands that
      # item back beside the answer, so the set that gets the answer, the
      # document that was printed, and the line that gets retired are one
      # question rather than three lookups that can disagree.
      #
      # A blank answer must resolve NOTHING and retire NOTHING, or the item
      # leaves the human's only view of a still-pending question. The drain
      # guards that at the source (a line of nothing but whitespace is never
      # an answer, see {Frontend::TTY::Inbox#settled}); the `strip.empty?`
      # check keeps the property local to the resolve as well.
      #
      # @return [String] the answer as it will be delivered -- for a question
      #   carrying a set that is the answer set's rendering, not the line the
      #   human typed -- or "" (nothing pending, or they typed nothing)
      def drain_at_prompt
        @inbox.gather(@questions)
        answer, answered = @reply.at_prompt
        resolve_reply(answer, answered.digest) unless answer.strip.empty?
        answer
      end

      # The concurrent reply surfaces for one ask: the TTY drain loop, and --
      # only when an editor is attached -- the :LainReply consumer. The caller
      # (Repl#respond) stops them in its ensure. Only the surfaces that EXIST:
      # "no editor is attached" is a fact this class already answers with an
      # object ({NoEditor}), so handing back a nil beside it would be the same
      # fact said a second way, in the form every caller then has to check.
      def surfaces(task) = [answer_loop(task), editor_reply_loop(task)].compact

      private

      # Parks on dequeue (a real scheduler yield -- woken per arrival, never
      # polling) and serves them one at a time.
      def answer_loop(task)
        task.async { loop { serve_question(@questions.dequeue) } }
      end

      # One arrival, from the note to the answer. A question ARRIVES as a
      # one-line note; the reply read stays fiber-parked (the ask cannot
      # complete without it), but the surface is the drain. `/inbox` at the
      # reply prompt lists the pending items before answering; any other line
      # answers directly (the inline path stays the no-inbox fallback), and it
      # answers THIS item -- the one whose note the human is looking at --
      # never whichever is at the head of the list.
      #
      # A blank line here IS an answer, and deliberately not what the same
      # keystroke means at `you>`: this prompt exists because a run is PARKED
      # on this set, so declining to answer still has to reach the model, and
      # `""` is what carries that (`Tool::Result.ok(nil)` would raise). At
      # `you>` nothing waits on the drain's read, so Enter there means "I
      # looked, not now" and resolves nothing. The `/inbox` detour inside the
      # read does not move the human to that other prompt -- the set is still
      # parked on this fiber -- so Enter still answers it.
      #
      # NOTHING here may kill this fiber, for {#serve_editor_command}'s reason
      # and a sharper one: this is the TTY answer path, which ruling 7 keeps
      # live whether or not an editor is attached, and it is ONE fiber for the
      # whole run. The read reaches Reline and a real terminal; the delivery
      # reaches the Store and the journal. Either raising un-guarded ended the
      # loop permanently and silently -- arrivals still landing on `@questions`
      # with nothing draining them, and a human watching a run that stopped
      # asking. `StandardError`, so an `Async::Stop` climbing out of a
      # cancelled read keeps climbing.
      #
      # The line is retired on EVERY exit, and unconditionally, because every
      # exit means it is dead: answered, withdrawn, raised, or unwound. Testing
      # the read's own unwind instead covered exactly one of those shapes --
      # and missed the one that matters, a set withdrawn WHILE the human types,
      # which left a line that lists forever and can only ever refuse. The
      # digest is this item's own, so this can never retire somebody else's.
      #
      # A REFUSED answer is the one exit that does not belong on that list --
      # the question is still outstanding and the human can retype -- and it
      # never reaches here: {Reply} refuses and re-reads, so what comes back
      # is always something the record can carry. Retiring on a refusal parked
      # the agent forever AND deleted the only line that could unpark it.
      def serve_question(item)
        @inbox << item
        @tty.render_arrival(item.question, from: item.from)
        answer, answered = @reply.for(item)
        resolve_reply(answer, answered.digest)
      rescue StandardError => e
        @tty.render_error(e.message)
      ensure
        @inbox.retire(item.digest)
      end

      # The TTY's answer: the refusal is rendered where the human typed. A
      # digest no asker holds is the live outcome of a stale line (a run
      # stopped between the note and the answer), and the directory's own
      # sentence says the line was stale rather than that the answer was
      # wrong -- so it is passed through, not reworded.
      def resolve_reply(answer, digest)
        deliver(answer, digest)
      rescue Lain::Tools::AskHuman::NoPendingQuestion => e
        @tty.render_error(e.message)
      end

      # The ONE answer path both surfaces use. AlreadyResolved: the other
      # surface beat this one -- normal, per the queue's own doctrine -- so
      # the duplicate is dropped and the item retired all the same, because
      # the set it named IS answered.
      def deliver(answer, digest)
        @ask_human.reply(answer, digest)
        @inbox.retire(digest)
      rescue Lain::Promise::AlreadyResolved
        @inbox.retire(digest)
      end

      # The editor reply leg (I6): the :LainReply command lands on the frontend's
      # rail and this fiber resolves the pending ask from it. Spawned only for
      # an editor that exists -- {NoEditor} answers everything else, so nothing
      # downstream branches on whether one is attached.
      def editor_reply_loop(task)
        task.async { loop { serve_editor_command } } if @editor.attached?
      end

      # ONE editor command, and its own method because NOTHING a command does
      # may kill this fiber. It is the sole consumer of EVERY editor verb, so a
      # `review_done` that raises -- the reviewed file gone, an annotation the
      # wire dropped a key from, a settle that refuses -- would take
      # :LainReply down with it and the editor would go quiet with no sign why.
      # The refusal renders back in the editor, which is where the gesture came
      # from: a `done` that vanishes is the one outcome this surface must never
      # produce. Verbs nothing here claims are ignored (they rode their own
      # path to the frontend).
      #
      # There is no `pending?` pre-guard any more, and its absence is the fix:
      # it asked the object this class holds whether IT had something pending,
      # which under digest-addressed routing is not the question. "Is this
      # digest answerable" is the directory's to answer, and it answers it by
      # replying or refusing -- so a child's question stays answerable from the
      # editor while the parent holds nothing, and a race the TTY already won
      # comes back as AlreadyResolved, which {#deliver} drops.
      def serve_editor_command
        verb, args = pop_command
        deliver(args.first.to_s, @inbox.oldest.digest) if verb == "reply"
        answer_document(args) if verb == "question_answered"
        settle_review(args) if verb == "review_done"
        sleep(IDLE_TICK) if verb.nil?
      rescue Lain::Promise::AlreadyResolved
        nil
      rescue StandardError => e
        @editor.review_refused(e.message)
      end

      # The written question document ({Neovim::QuestionView}): the wire's
      # `["question_answered", [digest, answer_set]]`. The digest is the
      # buffer's own stamp, so this answer names its set rather than inheriting
      # whatever the inbox lists first, and the set RENDERS to the String a
      # {Tool::Result} carries -- the tool's contract, not this seam's choice.
      def answer_document(args)
        digest, answers = args
        deliver(answers.render, digest)
      end

      # The wire's `["review_done", [generation, epic_slug, annotations]]` --
      # ONE array of arguments, like every other verb on this rail, because the
      # pop above destructures `verb, args`. Annotations arrive String-keyed:
      # they crossed msgpack from lua and nothing here re-keys them, so the
      # journal records what the editor actually sent.
      def settle_review(args)
        generation, epic_slug, annotations = args
        key = review_key(epic_slug, generation)
        review, path = @reviews.fetch(key) do
          raise Lain::Epic::Review::NotOpen,
                "review generation #{generation} is not open for epic #{epic_slug.inspect}"
        end
        review.settle(generation, disk: File.binread(path), annotations: annotations || [])
        @reviews.delete(key)
      end

      # The identity BOTH sides of the lookup must read the same way: the
      # epic's slug, and the generation through the ONE wire reader
      # ({Epic::WireInteger}). It refuses `"7abc"`, `7.9`, `0` and negatives
      # instead of coercing them, so a malformed `done` is answered rather than
      # silently keyed onto somebody else's review; the refusal reaches the
      # human because {#serve_editor_command} turns any raise into an editor
      # refusal.
      def review_key(epic_slug, generation)
        [epic_slug.to_s, Lain::Epic::WireInteger.read(generation, field: "generation")]
      end

      def pop_command
        @editor.pop(true)
      rescue ThreadError
        nil
      end
    end

    # Reopened rather than nested in the class body above -- `tty.rb`'s idiom,
    # for the same reason: each collaborator is its own responsibility, and the
    # split keeps each body inside Metrics/ClassLength instead of loosening it.
    class HumanReplies
      # The lines a human can see, and the digest each one is answered by.
      # Split out because "which items are listed, and which one does a
      # nameless answer mean" is a responsibility of its own -- {HumanReplies}
      # was carrying it beside routing an answer to the asker that asked, and
      # the review panel and Metrics named the same seam.
      #
      # An Array with an opinion, not a wrapper: every method here is one of
      # the four rules the list actually has.
      class Pending
        include Enumerable

        def initialize = @items = []

        def each(&block) = @items.each(&block)
        def <<(item) = @items << item
        def empty? = @items.empty?

        # Non-blocking: every arrival sitting on the queue right now, without
        # parking a fiber on an empty one. `Enumerator.produce` calling
        # `dequeue(timeout: 0)` (nil on empty, per Async::Queue) stops pulling
        # the instant `take_while` sees the first nil -- an infinite producer
        # is safe because nothing forces it past that point. Each item arrives
        # carrying its own attribution, so nothing here asks an asker who
        # asked.
        def gather(queue)
          @items.concat(Enumerator.produce { queue.dequeue(timeout: 0) }.take_while { |item| !item.nil? })
        end

        # By NAME, never by position: the item an answer belongs to need not be
        # the one at the head, and retiring the head instead drops a question
        # nobody answered out of the human's only view of it.
        def retire(digest) = @items.delete_if { |item| item.digest == digest }

        # What an answer that names no set of its own means: the oldest item
        # listed -- the first line the drain printed, and what the editor's
        # digest-less :LainReply is replying to. {Unlisted} when nothing is
        # listed, so the refusal is the directory's rather than a nil's.
        def oldest = @items.first || Unlisted
      end

      # One human answer, read -- and the pairing of that answer with the set
      # it answers. Holds the terminal it happens on, the conductor that owns
      # stdin while it does, and the list the `/inbox` detour lists.
      #
      # Its own object because "read until the human types something the
      # record can carry" is not {HumanReplies}' business of routing an answer
      # to an asker: the detour, the refusal-and-retry, and the pairing all
      # belong to the READ, and the panel's note that the pair should be built
      # where the knowledge is points at exactly this seam.
      class Reply
        def initialize(tty:, conductor:, inbox:)
          @tty = tty
          @conductor = conductor
          @inbox = inbox
        end

        # The reply prompt of a PARKED set. `/inbox` detours to the drain for
        # THIS item -- the set the run is parked on, whose note the human is
        # looking at -- so the document they read and the set their reply
        # answers are one question. It used to drain for whatever was oldest
        # and hand the answer back to be resolved against this item, which was
        # invisible while an answer was an opaque line and is not any more:
        # the prose answer NAMES the questions it answers, so the wrong set
        # received a reply naming another set's ids and the set the human
        # actually read stayed pending.
        #
        # Any other line answers this item directly, which is the no-inbox
        # fallback and the common path.
        #
        # @return [Array(String, InboxItem)] the answer, and the item it answers
        def for(item) = accepted { read(item) }

        # `/inbox` at `you>`: nothing is parked on this read, so one typed
        # answer answers the oldest item listed.
        def at_prompt = accepted { drained(answering: @inbox.oldest) }

        private

        # The read routes through the conductor's #read_reply (not the tty
        # directly) so the conductor KNOWS Reline owns stdin for the span and
        # suppresses its countdown ticker's render + key-read. `.to_s` is
        # load-bearing: EOF returns nil, and an empty answer is honest where
        # `Tool::Result.ok(nil)` would raise.
        # `legible` runs BEFORE the `/inbox` test, not after: `String#strip` on
        # invalid bytes raises Encoding::CompatibilityError, which is not the
        # ArgumentError the refusal path rescues, so it would climb past every
        # guard here to `#serve_question`'s ensure -- retiring the line while
        # leaving the promise pending, which is the exact end state `legible`
        # exists to prevent, reached one line above it.
        def read(item)
          line = legible(@conductor.read_reply(@tty, "human> ").to_s)
          return [line, item] unless line.strip == "/inbox"

          drained(answering: item)
        end

        # The drain answers the item it was NAMED, and that item is what the
        # answer is paired with here -- the caller's own object, never one
        # shipped out to the frontend and back.
        def drained(answering:)
          answer = ""
          reader = ->(prompt) { @conductor.read_reply(@tty, prompt) }
          @tty.drain_inbox(@inbox, answering:, reader:) { |typed| answer = typed }
          [answer, answering]
        end

        # Read until the human types something the record can carry. A refusal
        # is NOT a dead question -- the set is still pending and a shorter or
        # legible reply still answers it -- so the reason is rendered where
        # they typed it and the prompt comes round again. Every other exit
        # from a served question means the line is dead, which is what lets
        # {HumanReplies#serve_question}'s `ensure` retire unconditionally.
        #
        # The drain does this for itself ({Frontend::TTY::Inbox#accepted}), so
        # in practice this catches the INLINE prompt -- where a line that
        # cannot be written used to reach the Store, raise there, and take the
        # `ensure` with it.
        def accepted(&read) = Enumerator.produce { refusable(&read) }.lazy.compact.first

        def refusable
          yield
        rescue ArgumentError => e
          @tty.render_error(e.message)
          nil
        end

        # What the Store can hold, checked where the human can still retype
        # it: invalid UTF-8 used to reach the event write and raise there,
        # which is the same dead line by a longer route.
        def legible(line) = Question::Rules.prose(line, "a typed reply")
      end
    end
  end
end
