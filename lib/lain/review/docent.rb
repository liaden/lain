# frozen_string_literal: true

require "async"

module Lain
  module Review
    # A question about ONE hunk, answered by a fresh role-scoped child and
    # rendered back into the thread pane T18 owns.
    #
    # == The answerer is a ROLE, and that is the whole design
    #
    # Nothing here is an agent. {Answerer} is one line over {Skill::RoleSpawn},
    # and every collaborator that decides WHO answers -- the seam, the role name,
    # the runner the answer is computed on -- is injected. So a bench arm swaps
    # the answerer for a different role, a recorded oracle, or a second harness
    # without touching this class, which is what "swappable, observable,
    # comparable" has to mean at the level of one object. The DEFAULT is a fresh
    # subagent per question, given the hunk, both revisions of the enclosing
    # context, and whatever dossier the caller supplies.
    #
    # An arm that is swappable and not IDENTIFIABLE is not comparable, so the
    # answerer NAMES ITSELF on the record: {#initialize} asks its answerer for
    # `#role` and journals that, never {ROLE}. Journaling the constant made two
    # genuinely different arms produce byte-identical records and filed a bare
    # lambda under the shipped role's name -- the one field an arm comparison
    # queries, answering one bucket for every arm. {ANONYMOUS_ARM} is what an
    # arm that cannot name itself is recorded as, and {Brief#key} is the rest of
    # the same fact: two records carry the same `brief_key` exactly when the two
    # arms were handed byte-identical prompts.
    #
    # It is unbiased by authorship because it is told nothing about who wrote the
    # change: {Brief} is the whole of what the child sees. There is a
    # second-order property in that which is worth stating out loud -- if the
    # docent cannot answer "why this way" from the hand-back it was given, THAT
    # IS A FINDING ABOUT THE HAND-BACK, not a defect here. {Brief::NO_DOSSIER} is
    # in the prompt for exactly that reason: an empty dossier says so rather than
    # rendering as nothing, so a docent answering badly on no evidence is
    # distinguishable from one answering badly on good evidence.
    #
    # A child spawned `:fresh` gets a NEW Timeline root whose `meta["spawned_from"]`
    # names the parent's head ({Tool::SpawnPolicy::PrefixStrategy::Fresh}). It
    # inherits none of the parent's prompt, which is the spawn contract and is
    # also why this object never reaches for a timeline: everything the child
    # needs is in the brief or it is not needed.
    #
    # == Nothing here may block the editor, and the fiber it rides on says why
    #
    # `review_ask` arrives on {CLI::HumanReplies#editor_reply_loop}, which is the
    # SOLE consumer of every editor verb -- `reply`, `review_done`, every
    # gesture. An answer is a provider round trip, so computing one inside {#ask}
    # would stall :LainReply and every review gesture for seconds. {#ask}
    # therefore renders a pending marker, hands the work to {Reactor}, and
    # returns; the answer arrives later on T18's own outbound render path. Every
    # failure the answer can produce is contained inside that task, so a docent
    # that raises costs one thread's answer and never the fiber.
    #
    # == A repeated question is not a repeated spawn
    #
    # `review_ask` carries no stamp, and T18's editor half re-sends the
    # identical payload when a human hits `:w` twice: its write autocommand
    # fires on an unmodified `acwrite` buffer, and the send does not advance the
    # buffer's record of what has already been rendered. A duplicate is
    # therefore ORDINARY, not exotic -- and a duplicate here is a duplicate
    # subagent, a duplicate provider call, real money, and two answers in one
    # pane.
    #
    # So the guard is here rather than only in lua, and it is keyed on
    # `(anchor id, question text)`: the ask is a pure function of the anchor's
    # hunk, the fixed dossier and the words, over a FRESH root that inherits
    # nothing -- so an identical question on an identical thread is the same ask
    # by construction, not merely a similar one. The guard holds while the first
    # answer is still outstanding, which is the window a re-send actually arrives
    # in ({Exchanges#asked?} reads pending exchanges, not journaled answers).
    #
    # A human who genuinely wants a second opinion asks it in different words,
    # which is the same escape any idempotency key leaves; the refusal names the
    # duplicate rather than silently doing nothing.
    #
    # The guard holds a question only while an exchange is STANDING -- pending
    # or answered ({Exchange#standing?}). A question the docent refused or a
    # session ended under is askable again, because the soundness argument above
    # is an argument about an ANSWER: nothing in the pane answers a question a
    # provider fell over on, and a retry after a transient failure is a
    # genuinely different ask rather than a repeat of one that never happened.
    #
    # == Why one file, and where its seams are
    #
    # Four concerns live here -- the service, {Threads}, {Conversation}/{Exchanges},
    # {Brief} -- plus the journal records, which elsewhere in `Review` live in
    # `records.rb`. That is a DELETABILITY choice and not an oversight: every
    # one of them exists only because a docent does, they have no reader outside
    # this file, and the chunk's deletion map is "this file and one line in each
    # of five others". Splitting them would spread that map across six files
    # whose only tie is this one. The seams are real all the same, and are
    # named: not one line of {Threads} knows what an answerer is, and {Brief} is
    # a pure value with one rendering.
    class Docent
      # No reactor is running, so there is nowhere to compute an answer that is
      # not the caller's own fiber -- and the caller's own fiber is the one thing
      # that must not block. Named rather than allowed to surface as a
      # NoMethodError on nil.
      class NoReactor < Error; end

      # The catalog role a default {Answerer} spawns. Injected at every level, so
      # a bench arm names another without editing this file.
      ROLE = :diff_docent

      # What an answerer that cannot say which arm it is gets recorded as. A
      # bare lambda is a legitimate arm -- the specs are full of them, and so is
      # a recorded oracle -- but it has not earned {ROLE}'s name, and a bench
      # query that silently bucketed every unnamed arm under the shipped role
      # would answer its own question wrong.
      ANONYMOUS_ARM = :anonymous_arm

      # A FRESH root, never `:inherit`. The child must not read the parent's
      # conversation: an answer conditioned on what the parent has already said
      # about the change is not an unbiased reading of the hunk, and the card's
      # own escalation trigger is a docent that needs the parent's timeline.
      MODE = :fresh

      # Who says what, in the thread pane. Three speakers and no more: the
      # human, the docent, and lain refusing on the docent's behalf.
      SPEAKER_HUMAN = "you"
      SPEAKER_DOCENT = "docent"
      SPEAKER_LAIN = "lain"

      # What stands in for the answer while a child is thinking. It is a RENDERED
      # message rather than a spinner or an empty pane, for the reason T18's own
      # empty-thread placeholder gives: a pane that shows nothing reads as a
      # rendering glitch, and this one has to say that a question was taken.
      PENDING = "(thinking -- the answer will replace this line)"

      # What a question the session ended under is settled to. An answer nobody
      # is left to compute is not an answer, and saying so is what stops a
      # replayed thread reading as permanently thinking.
      ABANDONED = "the session ended before this was answered"

      # An id no thread is open at. It names BOTH ways that happens, because they
      # are indistinguishable from the editor's side and call for the same fix:
      # `open` was never called for that anchor, or it was and no hunk of this
      # changeset covers the line.
      NO_THREAD = "no thread at anchor %s -- open one on a hunk of this changeset first"

      # A `:w` on a thread whose typed region is whitespace. lua refuses this
      # first (its own `typed` answers nil), so reaching here means some other
      # caller did it -- answered rather than raised, because this rail refuses
      # in words.
      BLANK = "a docent needs a question -- type one under the conversation and submit"

      # The duplicate refusal. It quotes the question back, because the human's
      # screen shows the thread and not the wire, and "already asked" without the
      # words reads as a bug in the pane.
      DUPLICATE = "the answer to this is in the pane; reword to ask again. asked: %p"

      # A question that reached a docent and came back with no answer. The
      # failure rides verbatim: the docent's own words are the finding.
      FAILED = "the docent could not answer this: %s"

      # ...unless there are no words at all, and there are two ways to have
      # none: an empty answer, and a failure that failed to say why. Both used
      # to reach the human as the WIRE GUARD's own sentence -- `answer must
      # carry what the docent said, got ""` -- which is true, and is addressed
      # to a programmer.
      SAID_NOTHING = "the docent came back with nothing to say"

      # What a taken question reports. Never rendered by {CLI::HumanReplies::Gestures}
      # (it reads `#report` only on a refusal), but a bench arm and a text
      # surface both want a sentence for the success too.
      TAKEN = "asked the docent %p"

      # What an exchange can be, and it is CLOSED. `standing` is the pair the
      # duplicate guard reads: pending or answered.
      STATES = %i[pending answered refused abandoned].freeze
      STANDING = %i[pending answered].freeze

      # One question and whatever has come back for it: the answer, the refusal,
      # or {PENDING} while a child is still reading. `speaker` and `text` are
      # what the pane renders BENEATH the question, so settling a question is one
      # replacement rather than a delete and an append.
      #
      # `state` is which of {STATES} it is, NAMED rather than inferred. Both
      # queries over it -- "has this thread already asked that" and "is this one
      # still outstanding" -- were once readings of the rendered WORDS, so an
      # empty {PENDING} or a refusal worded like an answer moved them, and
      # neither question is about what the pane says.
      Exchange = Data.define(:question, :speaker, :text, :state) do
        def pending? = state == :pending

        # Whether this exchange still speaks for its question. A refused or
        # abandoned one does not: nothing in the pane answers it, so asking
        # again is a new ask and not a duplicate.
        def standing? = STANDING.include?(state)
      end

      # What {#ask} answers, and the duck {CLI::HumanReplies::Gestures} asks of
      # it: `#asked?` decides whether the human is owed a sentence, and `#report`
      # is that sentence. `task` is the handle on the work -- nil when nothing
      # was scheduled -- and it is here so a bench arm (and this card's specs)
      # can await a docent deterministically instead of polling a pane.
      Asked = Data.define(:report, :asked, :task) do
        def asked? = asked
      end

      # The answerer nobody wired. It refuses IN WORDS rather than raising, which
      # is the convention of every rail this object touches, and it is the
      # default so no path below asks whether an answerer exists.
      module Unanswerable
        NOT_WIRED = "no docent is wired to this review, so the question reached nobody and nothing was spent " \
                    "on it"

        def self.call(_brief) = Tool::Result.error(NOT_WIRED)
      end

      # The default answerer: ONE fresh role-scoped child per question.
      #
      # This is the whole of the "it is a role, not an agent" claim, and it is
      # deliberately this small. {Skill::RoleSpawn} already fetches the role,
      # attenuates the union, renders the persona and runs the child to a single
      # result, so what is left here is naming which role and which prefix arm --
      # both injected, so swapping the arm is construction and not a code change.
      class Answerer
        # @param spawn [#call] `(role_name, context_mode, prompt) -> Tool::Result`
        #   -- {Skill::RoleSpawn} in production
        # @param role [Symbol] a {Role::Catalog} name
        # @param mode [Symbol] a {Tool::SpawnPolicy::PrefixStrategy} arm; see {MODE}
        def initialize(spawn:, role: ROLE, mode: MODE)
          @spawn = spawn
          @role = role
          @mode = mode
          freeze
        end

        # Which arm this is, for the record. {Docent} asks rather than assuming:
        # an arm that answers this and an arm that does not are both legitimate,
        # and only one of them can be told apart from {ROLE} afterwards.
        attr_reader :role

        def call(brief) = @spawn.call(@role, @mode, brief)
      end

      # Where an answer is computed: a TRANSIENT task on the reactor already
      # running under the caller ({Oracle::Eager#fire}'s shape, for its reason).
      #
      # Transient, so an answer in flight never holds a session open at shutdown
      # -- a docent's answer is worth having and is never worth waiting for. In a
      # real run the reactor is the Repl's and outlives every thread pane, so the
      # only tasks a stop can reap are ones nobody is left to read.
      #
      # It REFUSES rather than falling back to running the block inline: an
      # inline fallback would silently reintroduce the multi-second editor freeze
      # this whole object exists to avoid, on whichever call site forgot its
      # reactor, and it would look like a working docent.
      #
      # `Async::Task#async` is GREEDY -- it runs the block inline on the CALLING
      # fiber until the block's first suspension -- so scheduling alone does not
      # get the work off the editor's fiber. What does is the handover at the
      # top of {Delivery#call}; this module only decides WHERE the block runs,
      # and a bench arm swapping it for a runner of its own inherits that
      # guarantee rather than having to repeat it.
      module Reactor
        NO_REACTOR = "a docent answers on its own fiber, and there is no reactor on this one -- ask from " \
                     "inside a Sync/Async block"

        def self.call(&block)
          task = Async::Task.current?
          raise NoReactor, NO_REACTOR if task.nil?

          task.async(transient: true, &block)
        end
      end

      # @param changeset [Review::Changeset] the diff every question is about;
      #   read for its hunks and its two revisions, never held open past a render
      # @param view [#show] T18's thread pane: takes `(anchor, entries)` and
      #   answers the notice saying why the render did not land, or nil. A DUCK
      #   and never a named type, for {Entry}'s reason.
      # @param answerer [#call] `(brief) -> Tool::Result`; see {Answerer}
      # @param journal [#<<] where the exchange is recorded, so {#replay}
      #   can rebuild it without a provider
      # @param dossier [Hash{String=>String}] the task card, the hand-back, the
      #   panel's findings -- title to body, rendered in the order given
      # @param runner [#call] where the answer is computed; see {Reactor}
      # @param role [Symbol, nil] the name this arm goes on the record under,
      #   for an answerer that cannot name itself. nil asks the answerer
      #   (see {Answerer#role}) and falls back to {ANONYMOUS_ARM}.
      def initialize(changeset:, view:, answerer: Unanswerable, journal: Channel::Null.instance,
                     dossier: {}, runner: Reactor, role: nil)
        @changeset = changeset
        @view = view
        @answerer = answerer
        @journal = journal
        @dossier = dossier.to_h.freeze
        @runner = runner
        @role = role || arm_role(answerer)
        @threads = Threads.new(changeset)
      end

      # Open (or reopen) the conversation at `anchor` and render it into the
      # pane. Idempotent: a second open of one anchor renders the SAME
      # conversation rather than starting a new one, because the human's
      # half-answered thread is not the editor's to discard.
      #
      # @param anchor [Review::Anchor]
      # @return [Conversation, nil] nil when no hunk of this changeset covers the
      #   anchor, which is the one case there is nothing to open
      def open(anchor)
        conversation = @threads.hold(anchor)
        render(conversation) unless conversation.nil?
        conversation
      end

      # Take one question and return -- see the class doc on why returning is the
      # requirement rather than an optimisation.
      #
      # The rescue here is the LOOKUP's, and nothing more: everything that
      # mutates a thread is inside {#take}, which owns its own rescue and takes
      # the question back through {#undo}. That division is the point -- this
      # one may safely refuse in words because nothing has happened yet.
      #
      # @param anchor_id [String] the id the editor cited back; opaque there,
      #   minted here
      # @param question [String] the human's own words
      # @return [Asked]
      def ask(anchor_id, question)
        text = question.to_s.strip
        conversation = @threads[anchor_id]
        declined = declined(conversation, anchor_id, text)
        declined.nil? ? take(conversation, text) : refused(declined)
      rescue StandardError, ScriptError => e
        refused(format(FAILED, e.message))
      end

      # Fold journaled exchanges back into threads nobody has opened yet, so the
      # next {#open} of an anchor renders what the recorded run rendered -- with
      # no provider call, because everything an answer consisted of is on the
      # record.
      #
      # Replay equals live BY CONSTRUCTION rather than by two implementations
      # agreeing: a folded record calls the same {Exchanges} methods the live
      # path calls, in journal order.
      #
      # A record it cannot read is SKIPPED, never raised on. That is
      # {Session::Replay#fold}'s hard-won rule: a fold aborts where it raises, so
      # one malformed line would make every later thread permanently
      # un-rebuildable.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records
      # @return [self]
      def replay(entries)
        @threads.replay(entries)
        self
      end

      # @param anchor_id [String]
      # @return [Conversation, nil] the open thread, for a caller rendering one
      #   without reopening it
      def conversation(anchor_id) = @threads[anchor_id]

      private

      # The arm's name for the record: the answerer's own if it has one, and
      # {ANONYMOUS_ARM} otherwise -- never {ROLE}, which would file every
      # unnamed arm under the shipped role and make the bench's own comparison
      # query answer one bucket.
      def arm_role(answerer) = answerer.respond_to?(:role) ? answerer.role : ANONYMOUS_ARM

      # The three ways a question is not asked, in the order that names the most
      # specific fact first. nil is "nothing declined it", which is the only
      # value {#ask} treats as permission.
      def declined(conversation, anchor_id, text)
        return format(NO_THREAD, anchor_id.inspect) if conversation.nil?
        return BLANK if text.empty?

        format(DUPLICATE, text) if conversation.asked?(text)
      end

      # The pending marker is rendered BEFORE anything is spent, and a question
      # that did not make it all the way onto a running task is taken back: an
      # answer nobody can see is not worth a provider call, and leaving the
      # question in the thread would make the human's retry look like a
      # duplicate.
      #
      # EVERY failure from `conversation.ask` onward routes through {#undo}, and
      # that is the correction this rescue exists for. It used to sit on {#ask},
      # outside the mutation: a view that raised, or a runner with no reactor
      # under it, refused the human while leaving the question in the thread --
      # a permanent `(thinking...)` marker, and every retry of it refused as a
      # duplicate of a question that was never asked. The question became
      # unaskable forever, in the case ({NoReactor}) this class explicitly
      # designs for.
      def take(conversation, question)
        conversation.ask(question)
        notice = render(conversation)
        return undo(conversation, question, notice) if notice.is_a?(String)

        brief = brief(conversation, question)
        @journal << asked_record(conversation, question, brief)
        schedule(delivery(conversation, question, brief), question)
      rescue StandardError, ScriptError => e
        undo(conversation, question, format(FAILED, e.message))
      end

      def delivery(conversation, question, brief)
        Delivery.new(answerer: @answerer, journal: @journal, view: @view, conversation:, question:, brief:)
      end

      # Separate from {#take} because the ask is already ON THE RECORD by the
      # time a runner can fail, and an ask with no terminal record after it is a
      # question the bench counts as outstanding forever. So the failure is
      # journaled here and the question is taken out of the thread by {#take}'s
      # rescue -- the record says a question was asked and refused, which is
      # what happened, and the pane is left able to ask it again.
      def schedule(delivery, question)
        Asked.new(report: format(TAKEN, question), asked: true, task: @runner.call { delivery.call })
      rescue StandardError, ScriptError => e
        @journal << delivery.refusal_record(e.message)
        raise
      end

      # A question taken back leaves NOTHING behind: the exchange goes and the
      # pane is rendered again without it. Re-rendering matters for the failures
      # that happen AFTER a marker landed -- a marker for a question this object
      # no longer holds is a thread claiming to be thinking about nothing.
      def undo(conversation, question, notice)
        conversation.drop(question)
        render(conversation)
        refused(notice)
      end

      def refused(report) = Asked.new(report:, asked: false, task: nil)

      def brief(conversation, question)
        Brief.of(conversation, changeset: @changeset, dossier: @dossier, question:)
      end

      def render(conversation) = @view.show(conversation.anchor, conversation.entries)

      def asked_record(conversation, question, brief)
        anchor = conversation.anchor
        DocentAsked.new(anchor_id: anchor.id, path: anchor.path, side: anchor.side, line: anchor.line,
                        hunk_key: conversation.hunk.content_key, role: @role, brief_key: brief.key, question:)
      end
    end

    class Docent
      # ONE question's answer, from the moment it is scheduled to the moment it
      # is on the record: the call to the arm, everything a failure can be, and
      # the settle-render-journal that lands whichever came back.
      #
      # Its own object because it runs somewhere ELSE. {Docent#take} returns on
      # the fiber serving the editor; this runs on the answering task, and the
      # two obey different failure rules -- the service may refuse in words
      # because there is a caller to tell, and this may not, because by the time
      # it fails there is nobody left holding a return value. So every ending
      # here is a record and a rendered thread, and the one thing it hands back
      # up is {#refusal_record}, for a caller whose task never started. Metrics
      # said an object was missing and this is the object; it is also the exact
      # boundary a review panel found the rescues on the wrong side of.
      class Delivery
        # @param answerer [#call] `(String) -> Tool::Result`; the swappable arm
        # @param journal [#<<]
        # @param view [#show] the thread pane; see {Docent#initialize}
        # @param conversation [Conversation] the thread the question was put in
        # @param question [String] the human's own words
        # @param brief [Brief] built at ask time, so the ask record can address
        #   the exact bytes this arm is handed
        def initialize(answerer:, journal:, view:, conversation:, question:, brief:)
          @answerer = answerer
          @journal = journal
          @view = view
          @conversation = conversation
          @question = question
          @brief = brief
        end

        # Everything a failure can be, contained HERE: a raise, a
        # `NotImplementedError` (a ScriptError, not a StandardError -- the shape
        # that walked past this guard's sibling on the editor rail), and a
        # result that reports its own failure without raising at all. All three
        # land in the thread as a refusal in lain's voice.
        #
        # {Async::Stop} is deliberately NOT among them: a cancelled task must
        # stay cancelled, so it climbs past the rescue and is caught by the
        # ensure only as the fact that nothing answered ({#abandon}).
        def call
          handed_over
          answer
        rescue StandardError, ScriptError => e
          refuse(e.message)
        ensure
          abandon
        end

        # The terminal record on its own, for the one caller that has no task to
        # run this on: a scheduling failure ({Docent#schedule}) has the ask
        # already journaled and the question about to be taken back out of the
        # thread, so what it needs is the record and nothing else.
        def refusal_record(reason)
          DocentRefused.new(anchor_id: @conversation.anchor.id, question: @question, reason:)
        end

        private

        # The handover, and the reason it is a line of its own:
        # `Async::Task#async` runs its block inline on the CALLING fiber until
        # the first suspension, so without this the arm's whole synchronous
        # prologue (for the default one: role fetch, persona render, subagent
        # construction, context build) runs on the fiber serving the editor, and
        # {Docent#ask} returns only as fast as the arm's first socket read.
        # Measured against an arm that never suspends: 0.351s on that fiber.
        #
        # It is here rather than in {Reactor} for two reasons: a bench arm
        # swapping the runner inherits the guarantee instead of having to repeat
        # it, and the raise from a stop then lands INSIDE this object's ensure,
        # so a session ending while a question is merely scheduled unwinds
        # through the same abandonment path as one ending mid-answer. `&.`
        # because a runner may compute the answer somewhere that is not a
        # reactor at all, which is its business -- and `current?`, never
        # `current`, which RAISES where there is no task.
        def handed_over = Async::Task.current?&.yield

        def answer
          result = @answerer.call(@brief.to_s)
          words = said(result)
          return refuse(SAID_NOTHING) if words.strip.empty?
          return refuse(words) if result.error?

          record(words)
        end

        # Journaled AFTER the render, which is the order the record has to be
        # written in. Journaling first and then failing to render put a
        # `docent_answered` and a `docent_refused` on ONE question -- an answer
        # rate counted over the two types double-counts that arm in both buckets
        # -- and a replay, last writer wins, then rendered only the refusal, so
        # an answer that was on the record could not be got back out of it.
        def record(text)
          settle(SPEAKER_DOCENT, text, :answered)
          render
          @journal << DocentAnswered.new(anchor_id: @conversation.anchor.id, question: @question, answer: text)
        end

        def refuse(reason)
          @journal << refusal_record(reason)
          settle(SPEAKER_LAIN, format(FAILED, reason), :refused)
          render
        end

        # A question whose task never finished: the reactor was stopped, the
        # session ended, and {Async::Stop} climbed past every rescue as it must.
        # Without this the record holds an ask that never terminates -- a fresh
        # docent replaying it renders a thread that is permanently thinking, and
        # refuses the human's re-ask as a duplicate of it.
        #
        # In memory and on the record ONLY: this runs while a stopped task is
        # unwinding, and a render is a round trip that would suspend a fiber
        # which may not suspend again. The next {Docent#open} renders it.
        def abandon
          return unless @conversation.pending?(@question)

          @journal << DocentAbandoned.new(anchor_id: @conversation.anchor.id, question: @question)
          settle(SPEAKER_LAIN, ABANDONED, :abandoned)
        end

        def settle(speaker, text, state) = @conversation.settle(@question, speaker:, text:, state:)

        def render = @view.show(@conversation.anchor, @conversation.entries)

        # A `tool_result`'s content is a String or an Array of provider blocks
        # ({Tool::Result}'s own contract), and only the text of it is a thing a
        # human reads in a thread pane.
        def said(result)
          content = result.content
          return content if content.is_a?(String)

          content.filter_map { |block| block["text"] || block[:text] }.join("\n")
        end
      end
    end

    class Docent
      # Which conversation an anchor or an id names, and what has been said in
      # it. Its own object because that is a different question from "ask a role
      # and render what comes back" -- and Metrics said so, which here was
      # naming a real seam rather than a size: everything below is a lookup over
      # a diff and a journal, and not one line of it knows what an answerer is.
      class Threads
        def initialize(changeset)
          @changeset = changeset
          @open = {}
          @replayed = {}
        end

        # @param anchor [Review::Anchor]
        # @return [Conversation, nil] nil when no hunk of this changeset covers
        #   the anchor, which is the one case there is nothing to hold
        def hold(anchor)
          @open[anchor.id.to_s] ||= begin
            hunk = hunk_at(anchor)
            Conversation.new(anchor:, hunk:, exchanges: replayed(anchor)) unless hunk.nil?
          end
        end

        def [](anchor_id) = @open[anchor_id.to_s]

        # @param entries [Enumerable<Hash, String>] journal lines or records
        # @return [self]
        def replay(entries)
          Journal.records(entries).each { |record| fold(record) }
          self
        end

        private

        def replayed(anchor) = @replayed.delete(anchor.id.to_s) || Exchanges.new

        # Which hunk encloses the anchor. The side-specific path is what an
        # anchor carries -- an old-side anchor on a renamed file names the OLD
        # path -- so indexing on the file's identity path would report every such
        # anchor as sitting in no hunk.
        #
        # {Submit::Placer} builds the same index for a different question, and
        # the six lines are duplicated rather than shared ON PURPOSE: both units
        # are deletable, and a shared span helper would make deleting either take
        # the other with it. The honest fix is `Hunk#span(side)` on the value
        # itself, which is a change to a file neither owns.
        def hunk_at(anchor)
          @changeset.files.lazy.filter_map { |file| enclosing(file, anchor) }.first
        end

        def enclosing(file, anchor)
          path = anchor.side == :old ? file.old_path : file.new_path
          file.hunks.find { |hunk| span(hunk, anchor.side).cover?(anchor.line) } if path == anchor.path
        end

        def span(hunk, side)
          start, count = side == :old ? [hunk.old_start, hunk.old_count] : [hunk.new_start, hunk.new_count]
          start...(start + count)
        end

        # Three independent type tests rather than a `case`, {Session::Replay#fold}'s
        # shape: a record that is none of the three is IGNORED here rather than
        # raised on, because a fold aborts where it raises and one malformed line
        # would leave every later thread permanently un-rebuildable.
        #
        # The refusal is re-WRAPPED in {FAILED} rather than journaled wrapped,
        # for the reason {DocentRefused}'s own doc gives: the record carries the
        # docent's words and the docent owns the sentence around them. So replay
        # reproduces the pane by running the same formatting the live path ran,
        # not by storing its output.
        def fold(record)
          type = record["type"].to_s
          exchanges(record).ask(record["question"].to_s) if type == DocentAsked::JOURNAL_TYPE
          fold_settled(record, SPEAKER_DOCENT, record["answer"].to_s, :answered) if answered?(type)
          fold_settled(record, SPEAKER_LAIN, format(FAILED, record["reason"]), :refused) if refused?(type)
          fold_settled(record, SPEAKER_LAIN, ABANDONED, :abandoned) if abandoned?(type)
        end

        def answered?(type) = type == DocentAnswered::JOURNAL_TYPE
        def refused?(type) = type == DocentRefused::JOURNAL_TYPE
        def abandoned?(type) = type == DocentAbandoned::JOURNAL_TYPE

        def fold_settled(record, speaker, text, state)
          exchanges(record).settle(record["question"].to_s, speaker:, text:, state:)
        end

        # Replayed exchanges wait in their own map rather than becoming
        # {Conversation}s: a conversation is keyed to an ANCHOR and a HUNK, and
        # the journal records neither the anchor's text nor its revision.
        # Fabricating one from the record would put an anchor on the wire that
        # nothing authored; the real one arrives at {Docent#open}, which is also
        # the only moment anybody needs it.
        def exchanges(record) = @replayed[record["anchor_id"].to_s] ||= Exchanges.new
      end
    end

    class Docent
      # One anchor's conversation: where it hangs, the hunk it is about, and what
      # has been said. Reopened rather than nested above so this file reads
      # top-down -- the service, then the things it holds.
      #
      # It is a JOIN and its own forwarding, deliberately: {Exchanges} is what
      # replay rebuilds at a moment when there is no anchor and no hunk to
      # attach it to, so the two cannot be one object -- and every caller here
      # wants "the thread at this anchor", never a pair. The forwarding is the
      # price of that, and it is the whole of this class.
      class Conversation
        def initialize(anchor:, hunk:, exchanges: Exchanges.new)
          @anchor = anchor
          @hunk = hunk
          @exchanges = exchanges
        end

        attr_reader :anchor, :hunk

        def entries = @exchanges.entries
        def asked?(question) = @exchanges.asked?(question)
        def pending?(question) = @exchanges.pending?(question)
        def ask(question) = @exchanges.ask(question)
        def drop(question) = @exchanges.drop(question)

        def settle(question, speaker:, text:, state:)
          @exchanges.settle(question, speaker:, text:, state:)
        end
      end

      # What has been said in one thread, apart from where it hangs. Its own
      # object because it is exactly what {Docent#replay} rebuilds from a
      # journal, at a moment when there is no anchor and no hunk to attach it to.
      #
      # An Array with an opinion ({CLI::HumanReplies::Pending}'s shape): every
      # method here is one of the four rules a conversation has.
      class Exchanges
        include Enumerable

        def initialize = @exchanges = []

        def each(&block) = @exchanges.each(&block)

        # Whether this thread has already put that question AND still stands
        # behind it. It reads PENDING exchanges, which is the half that matters:
        # the duplicate `:w` arrives while the first answer is still
        # outstanding, so a check against answered questions alone would let
        # both spawns through.
        #
        # It does NOT read refused or abandoned ones ({Exchange#standing?}), and
        # that is the other half: the duplicate refusal says the answer is in
        # the pane, and after a provider fell over the pane holds no answer.
        # Re-asking then is a genuinely different ask, and it was refused
        # forever.
        def asked?(question) = standing(question).any?

        # Whether that question is still outstanding -- asked, and nothing has
        # come back for it. {Docent#abandon} reads it while a stopped task
        # unwinds, to tell "nobody answered this" from "this was answered".
        def pending?(question) = standing(question).any?(&:pending?)

        def ask(question)
          @exchanges << Exchange.new(question:, speaker: SPEAKER_DOCENT, text: PENDING, state: :pending)
          self
        end

        # Replace one question's pending marker in place, so two questions in
        # flight on one thread settle in the order they were ASKED rather than
        # the order they came back -- a pane whose messages reorder under the
        # reader is worse than one that waits.
        #
        # The LAST exchange with those words, and one thread can now hold two of
        # them: a question that was refused stays in the pane and may be asked
        # again ({Exchange#standing?}). Matching the FIRST settled the old
        # refusal a second time and left the live question pending forever, then
        # journaled it as abandoned at shutdown on top of its own answer.
        # Matching only a PENDING one cannot settle a refusal over an answer
        # whose render failed, which is the one case a settled exchange is
        # settled twice.
        def settle(question, speaker:, text:, state:)
          at = latest_at(question)
          @exchanges[at] = Exchange.new(question:, speaker:, text:, state:) unless at.nil?
          self
        end

        # Take a question back, for the one caller that has to: a render that did
        # not land means nobody can see the marker, and a question the human
        # cannot see is a question they will ask again. The LAST one, for
        # {#settle}'s reason -- an earlier refusal of the same words is part of
        # the thread's history and not this ask's to erase.
        def drop(question)
          at = latest_at(question)
          @exchanges.delete_at(at) unless at.nil?
          self
        end

        # @return [Array<Surface::Message>] oldest first, the human's words then
        #   whatever came back under them. The PORT's value and not one of this
        #   file's own: it is what the pane on the other side of the seam
        #   renders, and it belongs to neither of them (see {Surface::Message}).
        def entries
          flat_map do |exchange|
            [Surface::Message.new(speaker: SPEAKER_HUMAN, text: exchange.question),
             Surface::Message.new(speaker: exchange.speaker, text: exchange.text)]
          end
        end

        private

        # Every exchange for that question that still speaks for it. The two
        # public predicates above are both questions about this list, so they
        # cannot drift apart.
        def standing(question)
          select { |exchange| exchange.question == question && exchange.standing? }
        end

        def latest_at(question) = @exchanges.rindex { |exchange| exchange.question == question }
      end
    end

    class Docent
      Brief = Data.define(:anchor, :hunk, :base_ref, :head_ref, :dossier, :question)

      # Everything the child sees, and nothing else. A pure value with one
      # rendering, which is what makes {#key} mean something: two records
      # carrying one `brief_key` were built from byte-identical prompts, so two
      # arms are comparable byte for byte without the record carrying a copy of
      # the diff, the dossier and both revisions. (The record used to claim that
      # comparability while carrying none of it: a docent handed a 428-line
      # hand-back and one handed an empty dossier journaled identical records,
      # and {NO_DOSSIER} -- the distinction that makes "it could not say why" a
      # finding about the hand-back -- survived in the prompt and was lost in
      # the record.)
      #
      # It carries ONE hunk, never the changeset. A prompt holding the whole diff
      # would satisfy "the answer carries the hunk as context" and answer worse:
      # the docent's question is always about a position, and a neighbouring
      # hunk is a distraction with a plausible shape. The enclosing context is
      # reconstructed from that hunk's own origin markers -- context and `-`
      # lines are the before, context and `+` lines are the after -- so the two
      # revisions cannot disagree with the hunk they came from.
      class Brief
        QUESTION = "# The question"
        WHERE = "# Where it is"
        DIFF = "# The hunk, as the diff shows it"
        BEFORE = "# The enclosing context before, at %s"
        AFTER = "# The enclosing context after, at %s"
        EVIDENCE = "# What lain was told about this change"

        # The address {DocentAsked} carries this brief under, versioned like
        # every other scheme in {Review::Keying} so the layout cannot move
        # without the scheme moving with it.
        KEY_SCHEME = "docent-brief-v1"

        # An empty dossier SAYS it is empty. Rendering nothing would make "the
        # docent could not say why" ambiguous between a thin hand-back and a
        # wiring bug, and the first of those is a finding worth having.
        NO_DOSSIER = "Nothing was supplied -- no task card, no hand-back, no panel findings. Answer from the " \
                     "diff alone, and say plainly that you had nothing else to go on."

        # @param conversation [Conversation] the thread the question was put in;
        #   read for its anchor and its one hunk
        # @param changeset [Review::Changeset] read for its two revisions only --
        #   the diff itself never reaches the child
        # @param dossier [Hash{String=>String}] title to body, in the order given
        # @param question [String] the human's own words
        # @return [Brief]
        def self.of(conversation, changeset:, dossier:, question:)
          new(anchor: conversation.anchor, hunk: conversation.hunk, base_ref: changeset.base_ref,
              head_ref: changeset.head_ref, dossier:, question:)
        end

        def to_s = sections.map { |heading, body| "#{heading}\n\n#{body}" }.join("\n\n")

        # @return [String] the address of the exact bytes the child was handed.
        #   Over the RENDERING and not over the members, because the rendering
        #   is what the arm saw -- a change to how a section is worded is a
        #   different prompt and has to be a different key.
        def key = Keying.digest(KEY_SCHEME, [to_s])

        private

        def sections
          [[QUESTION, question], [WHERE, where], [DIFF, patch],
           [format(BEFORE, base_ref), side("-")], [format(AFTER, head_ref), side("+")],
           *evidence]
        end

        def where
          "#{anchor.path}, #{anchor.side} side, line #{anchor.line}#{in_heading}\n" \
            "base #{base_ref}, head #{head_ref}"
        end

        def in_heading = hunk.heading.empty? ? "" : ", in #{hunk.heading}"

        def patch = [header, *hunk.lines].join("\n")

        def header
          "@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@ #{hunk.heading}".rstrip
        end

        # Origin markers stripped, so each side reads as the code did rather than
        # as a diff of it. A "\ No newline at end of file" line belongs to
        # neither side and is dropped by the same rule that keeps both.
        def side(marker)
          hunk.lines.select { |line| line.start_with?(" ", marker) || line.empty? }
                    .map { |line| line[1..] || "" }.join("\n")
        end

        def evidence
          return [[EVIDENCE, NO_DOSSIER]] if dossier.empty?

          dossier.map { |title, body| ["# #{title}", body.to_s] }
        end
      end
    end

    class Docent
      DocentAsked = Data.define(:anchor_id, :path, :side, :line, :hunk_key, :role, :brief_key, :question) do
        include Telemetry::Journalable
        include Guardable

        guard do
          attribute :anchor_id
          attribute :path
          attribute :side
          attribute :line
          attribute :hunk_key
          attribute :role
          attribute :brief_key
          attribute :question
          validates :anchor_id, presence: { message: Wire.refusal("must name the thread the question was put in") }
          validates :path, presence: { message: Wire.refusal("must name the file the hunk is in") }
          validates :side, inclusion: { in: SIDES, message: Wire.refusal("must be one of #{SIDES.join("/")}") }
          validates :line, numericality: { only_integer: true, greater_than: 0,
                                           message: Wire.refusal("must be the diff line the thread hangs off") }
          validates :hunk_key, presence: { message: Wire.refusal("must address the hunk the question is about") }
          validates :role, presence: { message: Wire.refusal("must name the role that was asked") }
          validates :brief_key, presence: { message: Wire.refusal("must address the prompt the arm was handed") }
          validates :question, presence: { message: Wire.refusal("must carry what the human asked") }
        end

        def initialize(anchor_id:, path:, side:, line:, hunk_key:, role:, brief_key:, question:)
          values = { anchor_id: Wire.token(anchor_id), path: Wire.token(path), side: Wire.token(side),
                     line: Epic::WireInteger.read(line, field: "line"), hunk_key: Wire.token(hunk_key),
                     role: Wire.token(role), brief_key: Wire.token(brief_key), question: Wire.text(question) }
          self.class.check!(**values)

          super(**values)
        end
      end

      # One question, put to one role, about one hunk.
      #
      # `hunk_key` and not the hunk: the key is the identity a mark already
      # survives a regeneration under ({Review::Hunk}), so a later reader can
      # join "what was asked here" against "what was reviewed here" without this
      # record carrying a second copy of the diff.
      #
      # `role` is on the record because the answerer is the swappable arm: an
      # experiment comparing two docents is a query over this field, and a record
      # that named only the question could not answer which arm produced the
      # answer beside it. It is the arm's OWN name ({Docent#arm_role}) and never
      # {ROLE}: journaling the constant made that query answer one bucket for
      # every arm, and did it while every test was green.
      #
      # `brief_key` is the other half of the same comparison -- the address of
      # the exact prompt the arm was handed ({Brief#key}). Two records agreeing
      # on it were built from byte-identical briefs, so a difference in the
      # answers is a difference in the ARM; two disagreeing on it name a
      # different dossier, a different revision pair or a different hunk without
      # the record having to carry any of them.
      class DocentAsked
        # The discriminator {Telemetry::Journalable} derives from this class's
        # own name, pinned so a rename breaks at the constant rather than quietly
        # relabelling records nobody can join anymore.
        JOURNAL_TYPE = "docent_asked"
      end

      DocentAnswered = Data.define(:anchor_id, :question, :answer) do
        include Telemetry::Journalable
        include Guardable

        guard do
          attribute :anchor_id
          attribute :question
          attribute :answer
          validates :anchor_id, presence: { message: Wire.refusal("must name the thread the answer is in") }
          validates :question, presence: { message: Wire.refusal("must carry the question it answers") }
          validates :answer, presence: { message: Wire.refusal("must carry what the docent said") }
        end

        def initialize(anchor_id:, question:, answer:)
          values = { anchor_id: Wire.token(anchor_id), question: Wire.text(question), answer: Wire.text(answer) }
          self.class.check!(**values)

          super(**values)
        end
      end

      # What the docent said, joined to its question by the pair `(anchor_id,
      # question)` -- the same pair the duplicate guard is keyed on, so "the
      # question was asked twice" and "the answer belongs to that question" are
      # one fact rather than two.
      class DocentAnswered
        # See {DocentAsked::JOURNAL_TYPE}.
        JOURNAL_TYPE = "docent_answered"
      end

      DocentRefused = Data.define(:anchor_id, :question, :reason) do
        include Telemetry::Journalable
        include Guardable

        guard do
          attribute :anchor_id
          attribute :question
          attribute :reason
          validates :anchor_id, presence: { message: Wire.refusal("must name the thread the refusal is in") }
          validates :question, presence: { message: Wire.refusal("must carry the question it refuses") }
          validates :reason, presence: { message: Wire.refusal("must say why the docent could not answer") }
        end

        def initialize(anchor_id:, question:, reason:)
          values = { anchor_id: Wire.token(anchor_id), question: Wire.text(question), reason: Wire.text(reason) }
          self.class.check!(**values)

          super(**values)
        end
      end

      # A question that reached a docent and came back with nothing. Journaled as
      # its own type rather than as an answer whose text happens to be an
      # apology: a bench arm's answer rate is a count over these types, and a
      # refusal recorded as an answer would make a broken provider look like a
      # productive docent.
      class DocentRefused
        # See {DocentAsked::JOURNAL_TYPE}.
        JOURNAL_TYPE = "docent_refused"
      end

      DocentAbandoned = Data.define(:anchor_id, :question) do
        include Telemetry::Journalable
        include Guardable

        guard do
          attribute :anchor_id
          attribute :question
          validates :anchor_id, presence: { message: Wire.refusal("must name the thread the question was put in") }
          validates :question, presence: { message: Wire.refusal("must carry the question nobody answered") }
        end

        def initialize(anchor_id:, question:)
          values = { anchor_id: Wire.token(anchor_id), question: Wire.text(question) }
          self.class.check!(**values)

          super(**values)
        end
      end

      # A question nobody was left to answer: the session ended, the reactor
      # stopped, and the task carrying it was reaped mid-flight.
      #
      # Its OWN type and not a {DocentRefused}, for the reason that record's own
      # doc gives one level up: the two buckets an arm is counted in are answers
      # and refusals, and an operator closing the session is neither -- counting
      # it as a refusal would make a shutdown look like a failing arm. It
      # carries no reason, because there is only ever the one.
      #
      # It exists at all because the ALTERNATIVE is worse than an extra type: an
      # ask with nothing after it replays as a thread that is permanently
      # thinking, and refuses the human's re-ask as a duplicate of it.
      class DocentAbandoned
        # See {DocentAsked::JOURNAL_TYPE}.
        JOURNAL_TYPE = "docent_abandoned"
      end
    end
  end
end
