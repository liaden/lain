# frozen_string_literal: true

module Lain
  module CLI
    # The human-reply surfaces (I6), lifted out of Repl the way Wiring lifted
    # chat assembly: answering ask_human is its own responsibility -- the
    # arrival note, the `/inbox` drain, and the editor's :LainReply leg -- and
    # the Metrics trip said so. The single pending question is the invariant the
    # drain keeps: one question at a time, one AskHuman, one reply resolves it.
    class HumanReplies
      # I6: one pending human question as the drain surface lists it -- who is
      # stuck (the asker's chain correlation), since when, and the question.
      InboxItem = Struct.new(:question, :from, :asked_at, keyword_init: true)

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

      def initialize(tty:, conductor:, ask_human:, questions:)
        @tty = tty
        @conductor = conductor
        @ask_human = ask_human
        @questions = questions
        @editor = NoEditor
        @reviews = {}
        @inbox = []
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
      # Lists every item (drained non-blockingly first, so a `you>`-time
      # `/inbox` shows the WHOLE backlog, not just the head), reads exactly
      # ONE answer (`Inbox#drain`'s own contract), and resolves it through
      # the SAME `@ask_human` `#reply` the human> path uses -- never a
      # second answer path. A blank answer must resolve NOTHING and retire
      # NOTHING: `resolve_reply` shifts the item in its ensure regardless of
      # whether `@ask_human.reply` moved the promise, so resolving on a blank
      # would drop the item from the human's only view of a still-pending
      # question. `Inbox#drain` already guards this today (it yields only a
      # non-empty answer, so `answer` stays nil on a blank line); the
      # `strip.empty?` check keeps that property local and also treats a
      # whitespace-only line as no-answer, so the item stays queued for the
      # next drain instead of being retired without a real reply.
      #
      # @return [String] the answer read, or "" (nothing pending, or the
      #   human typed nothing)
      def drain_at_prompt
        @inbox.concat(drained_questions)
        answer = nil
        @tty.drain_inbox(@inbox, reader: ->(prompt) { @conductor.read_reply(@tty, prompt) }) { |a| answer = a }
        resolve_reply(answer) unless answer.to_s.strip.empty?
        answer.to_s
      end

      # The concurrent reply surfaces for one ask: the TTY drain loop, and --
      # only when an editor is attached -- the :LainReply consumer. The caller
      # (Repl#respond) stops them in its ensure.
      def surfaces(task) = [answer_loop(task), editor_reply_loop(task)]

      private

      # A question ARRIVES as a one-line note; the reply read stays fiber-parked
      # (the ask cannot complete without it -- the single-question invariant is
      # untouched), but the surface is the drain. `/inbox` at the reply prompt
      # lists the pending items before answering; any other line answers
      # directly (the inline path stays the no-inbox fallback). Parks on dequeue
      # (a real scheduler yield -- woken per question, never polling).
      def answer_loop(task)
        task.async do
          loop do
            question = @questions.dequeue
            @inbox << InboxItem.new(question:, from: @ask_human.last_question&.from, asked_at: Time.now)
            @tty.render_arrival(question)
            resolve_reply(read_drained_answer)
          end
        end
      end

      # The reply read routes through the conductor's #read_reply (not the tty
      # directly) so the conductor KNOWS Reline owns stdin for the span and
      # suppresses its countdown ticker's render + key-read. `.to_s` is
      # load-bearing on both reads: EOF returns nil, and an empty answer is
      # honest where Tool::Result.ok(nil) would raise.
      def read_drained_answer
        line = @conductor.read_reply(@tty, "human> ").to_s
        return line unless line.strip == "/inbox"

        answer = nil
        @tty.drain_inbox(@inbox, reader: ->(prompt) { @conductor.read_reply(@tty, prompt) }) { |a| answer = a }
        answer.to_s
      end

      # Non-blocking: every question sitting in `@questions` right now,
      # without parking a fiber on an empty one. `Enumerator.produce` calling
      # `dequeue(timeout: 0)` (nil on empty, per Async::Queue) stops pulling
      # the instant `take_while` sees the first nil -- an infinite producer
      # is safe here because nothing forces it past that point.
      def drained_questions
        Enumerator.produce { @questions.dequeue(timeout: 0) }
                  .take_while { |question| !question.nil? }
                  .map { |question| InboxItem.new(question:, from: @ask_human.last_question&.from, asked_at: Time.now) }
      end

      # AlreadyResolved: the editor's :LainReply beat this prompt -- drop the
      # duplicate rather than killing the loop. The shift retires the item this
      # answer resolved regardless of which surface won.
      def resolve_reply(answer)
        @ask_human.reply(answer)
      rescue Lain::Promise::AlreadyResolved
        nil
      ensure
        @inbox.shift
      end

      # The editor reply leg (I6): the :LainReply command lands on the frontend's
      # rail and this fiber resolves the pending ask from it. Spawned only for
      # an editor that exists -- {NoEditor} answers everything else, so nothing
      # downstream branches on whether one is attached.
      def editor_reply_loop(task)
        task.async { loop { serve_editor_command } } if @editor.attached?
      end

      # ONE editor command, and its own method because NOTHING a command does
      # may kill this fiber. It is the sole consumer of BOTH editor verbs, so a
      # `review_done` that raises -- the reviewed file gone, an annotation the
      # wire dropped a key from, a settle that refuses -- would take
      # :LainReply down with it and the editor would go quiet with no sign why.
      # The refusal renders back in the editor, which is where the gesture came
      # from: a `done` that vanishes is the one outcome this surface must never
      # produce. `pending?` guards the TTY answer that already won -- the raced
      # loser is dropped. Verbs nothing here claims are ignored (they rode
      # their own path to the frontend).
      def serve_editor_command
        verb, args = pop_command
        @ask_human.reply(args.first.to_s) if verb == "reply" && @ask_human.pending?
        settle_review(args) if verb == "review_done"
        sleep(IDLE_TICK) if verb.nil?
      rescue Lain::Promise::AlreadyResolved
        nil
      rescue StandardError => e
        @editor.review_refused(e.message)
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
  end
end
