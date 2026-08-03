# frozen_string_literal: true

module Lain
  module Tools
    # Puts a question to the human and returns their answer -- the human as a
    # capability-gated, high-latency agent whose replies are just events in the
    # log (OM-4). The exchange is two :message events in the shared Store: an
    # outbound **Q** to the human's inbox (`to: "human"`) and, when the human
    # answers, an inbound **A** back to the asker. Both are replayable and
    # neither renders into any prompt chain (`render_parent` nil, the Lineage
    # idiom); the model receives the answer through this tool's ordinary
    # `tool_result` (gate 2), so the human's reply reaches the loop the same way
    # any tool's does.
    #
    # == A promise, not a blocking read
    #
    # {#ask} emits Q and hands back a pending {Lain::Promise} WITHOUT awaiting --
    # emitting does not block. Awaiting the promise parks the fiber, not the
    # reactor, so concurrent work proceeds while the answer is outstanding. The
    # tool-dispatch path {#perform} is the SYNC GATE: it emits then awaits, so a
    # single mechanism yields both modes -- await immediately and it is an
    # ordinary synchronous question-answer; await later (a future speculative
    # branch) and the agent continues meanwhile. There is no separate sync API.
    #
    # == The reply seam
    #
    # {#reply} is what the frontend's reply-path calls with the human's typed
    # answer: it writes A to the Store AND resolves the pending promise. Pushing
    # the message is the whole of what the frontend does -- the promise, the
    # process-local coordination that carries the value to the parked fiber, is
    # this tool's own business, never something the frontend reaches into.
    #
    # An answer NAMES the set it answers ({Outstanding}), and both edges written
    # from it -- A's causal parent, and the delivery commit's -- come from that
    # name. "The set asked most recently" is a different thing, and citing it is
    # how an answered question stays in the inbox forever while an unanswered
    # one silently vanishes (see {Pending}).
    #
    # == One call, a whole SET of questions
    #
    # What a call carries is a {Lain::Question::Set}, and that is a cost
    # decision rather than a taxonomy: this tool does not override
    # `parallel_safe?`, so {Agent::ToolRunner} runs it as a barrier. N questions
    # asked one at a time are N barriers -- the human answers, the model
    # round-trips, asks again -- which is N model turns and N context renders
    # for one decision. A set collapses that to one, and the price is that it
    # resolves as a whole.
    #
    # == Injection, and the single-question invariant
    #
    # `parent:` is the live parent-Timeline handle (a Timeline or a `-> Timeline`
    # thunk, since the toolset is built before the Agent) -- the shared Store
    # rides on it (`parent.store`), and the asker's identity is the parent
    # chain's correlation, exactly as Subagent's Lineage derives it. An instance
    # belongs to one agent's toolset, and a synchronous tool dispatch has no
    # interleaving writer, so at most one set awaits a reply at a time (the
    # OM-2-only statefulness Subagent documents) -- and {Outstanding} now
    # ENFORCES that rather than assuming it: a second ask over an unanswered set
    # is refused. An actor mode that asks concurrently must carry its promises
    # on events, not here.
    class AskHuman < Tool
      HUMAN = "human"

      # The id a bare free-text question is asked under. Every question in a set
      # carries one -- it is the join key the answer document renders and the
      # parser reads back -- and a caller who handed over a String never chose
      # one.
      FREE_TEXT_ID = "question"

      # The body key the asker's NAME rides on, and it exists because the
      # ENVELOPE cannot carry it: `from` is the asker chain's correlation --
      # its ROOT digest -- and an `:inherit` child is `parent.fork`, so a child
      # and its parent share a root PERMANENTLY and render one sender at every
      # surface that reads the record. `:inherit` is the default posture for a
      # `@role` spawn, so that is the common case rather than a corner of one.
      #
      # The TTY reads the name off the ARRIVAL
      # ({CLI::HumanReplies::InboxItem.asked}), which is why that surface was
      # closed alone. {Frontend::Neovim::InboxView} never sees an arrival -- it
      # folds the record stream -- so the name has to be IN the record for the
      # two surfaces to name an asker the same way.
      ASKED_BY = "asked_by"

      class NoPendingQuestion < Error; end
      class QuestionOutstanding < Error; end

      # The promise a question set is answered through, wearing the digest of
      # the Q event it answers. That digest is the whole point: `@last_question`
      # says "asked most recently", which is NOT "being answered", and every
      # edge written from it -- the A event's causal parent, and the delivery
      # commit's -- is written against whichever ask happened last. A :turn edge
      # is the ONLY consumption {Event::Projection#pending} counts, so the wrong
      # digest there leaves an answered question in the human's inbox forever
      # while an unanswered one silently vanishes.
      #
      # Still a {Lain::Promise}, so nothing holding this as one (the
      # `#ask`-shaped duck {Approval::Gate} awaits) sees any change.
      class Pending < Promise
        attr_reader :digest

        def initialize(digest)
          super()
          @digest = digest
        end

        def answers?(digest) = @digest == digest

        # What this asker is holding, for a refusal that has to name it.
        def held = "the question set #{@digest}"
      end

      # The at-most-one question set this asker is holding, addressable by name.
      # An instance of the tool belongs to one agent's toolset and is not
      # `parallel_safe?`, so a second set opening while one is unanswered is a
      # coordination bug, not a queue. It is NOT what makes an answer
      # unambiguous -- that is the digest {#reply} now requires; this refusal
      # only keeps one asker from holding two sets it could not tell apart.
      #
      # The two guards are one rule: a promise nobody can address by name is a
      # promise a late answer resolves by accident, which is exactly the
      # cross-resolution two surfaces racing over one asker produce.
      #
      # A guard, not a lock: {#open}'s check and its claim straddle the Q write,
      # which an attached observer's journal can turn into a yield point, so two
      # fibers sharing ONE asker could both pass it. Unreachable today rather
      # than impossible -- one asker is built (`Wiring#wire_agent`) and only the
      # top-level toolset holds it; `research_subagent` and `role_spawn_seam`
      # are handed the `base` set, which excludes it, so no child can ask at all.
      # The card that lets children ask owes them their own askers; a mutex here
      # would not answer it.
      class Outstanding
        # What a human sees when they answer a question this asker no longer
        # holds -- an inbox line that outlived its set. Written to be read at a
        # `human>` prompt: what happened, and that nothing was lost by it.
        WITHDRAWN = "no question is awaiting a reply -- it was answered already, or withdrawn when the run " \
                    "that asked it was stopped. The inbox line offering it is stale: nothing you type here " \
                    "is recorded, and nothing is waiting on it."

        # Nothing outstanding: where an asker starts, and what an abandoned
        # question leaves behind. It answers the same four messages a {Pending}
        # does, so no guard below asks whether one exists.
        module Nothing
          def self.resolved? = true
          def self.digest = nil
          def self.answers?(_digest) = false
          def self.held = "no question set at all"
        end

        def initialize = @pending = Nothing

        def pending? = !@pending.resolved?
        def digest = @pending.digest

        # Open a set for answering, the Q event's digest coming from the block.
        # The guard runs BEFORE the block, so a refused ask writes no Q to the
        # append-only Store and leaves nothing behind for a later reply to cite.
        def open
          raise QuestionOutstanding, still_outstanding if pending?

          @pending = Pending.new(yield)
        end

        # The set `digest` names, ready to take an answer -- or the refusal that
        # says why it cannot. Both refusals happen before the caller's Store
        # write: the refusal happens or the A event lands, never both.
        def answerable!(digest)
          named!(digest)
          raise Promise::AlreadyResolved, "the question set #{digest} was already answered" if @pending.resolved?

          @pending
        end

        # Stop holding a set whose answer can no longer be delivered (the sync
        # gate unwound). Identity, not digest: only the opener may abandon what
        # it opened, and an already-answered set is history worth keeping -- a
        # second reply naming it must still be refused as answered, not as
        # unknown.
        def abandon(pending)
          @pending = Nothing if pending? && @pending.equal?(pending)
        end

        private

        def still_outstanding
          "the question set #{digest} is already awaiting a reply on this asker -- answer it before asking another"
        end

        def named!(digest)
          return if @pending.answers?(digest)

          raise NoPendingQuestion, unnamed(digest)
        end

        # Two mistakes, two sentences, and both are read by a HUMAN at a reply
        # prompt, not only by the model: `/inbox` lists items the drain shifts
        # on its own, so an item can outlive the set it names (a cancelled run
        # withdraws the set; the line stays). "Nothing is pending" is true and
        # useless there -- it reads as a bug in the reply rather than as a stale
        # line -- so the first says what happened and what to do about it. The
        # second names the state this asker IS in, never the ivar behind it,
        # because "holds nil" tells a reader nothing.
        def unnamed(digest)
          return WITHDRAWN if digest.nil?

          "no question set #{digest} is awaiting a reply -- this asker holds #{@pending.held}"
        end
      end

      # One question set, wearing the text a human is shown for it -- and the
      # ONLY way a set reaches {#ask}.
      #
      # A String subclass, which is a shape to justify rather than assume. The
      # arrival seam is {Notifying#ask}, and it hands the notifier ITS OWN
      # argument verbatim: whatever `#ask` was called with is what reaches
      # `Wiring#announce`, which enqueues it for the TTY's arrival line
      # (`"? #{question}"`) AND drops it into a dunstify **argv** element. Both
      # were String-shaped before sets existed -- a Data value renders there as
      # an inspect and puts a non-String in an argv -- so the value handed to
      # `#ask` stays a String, and {#set} is how this tool still gets the whole
      # set off it.
      #
      # Structural rather than a convention: because a bare {Question::Set} is
      # refused, no caller can put a non-String on that seam. Widening the
      # queue to carry the set and its asker belongs to the card that owns
      # BOTH ends of it; that card reads {#set} off this value.
      #
      # == Two renderings, derived once
      #
      # The bytes this value IS are the WHOLE question a human answers, so for
      # a LONE question they are the body VERBATIM -- byte-for-byte what this
      # seam carried before sets existed, and what the dunstify argv shows.
      # Clamping them would be a real regression: the description invites
      # tables and fenced diffs, and a question cut to its first line is one a
      # human cannot answer.
      #
      # {#summary} is the other rendering: one clamped line, and what every
      # ONE-LINE surface shows -- the event body's `"question"` key (which is
      # what {Frontend::Neovim::InboxView} reads, and its `sender  age  text`
      # row is pinned), and, since T14, the TTY's arrival note and `/inbox`
      # row too. Those two read the summary rather than the bytes because a
      # lone question's body is exactly where the bytes are not one line: the
      # verbatim body belongs in the DOCUMENT the drain prints beneath the
      # row, not in the row. Clamped rather than refused, unlike every field
      # {Question} itself bounds -- these bytes were already accepted as a
      # question, and this is a RENDER of them, not a value anybody answers.
      # Both are derived here, once, so the surfaces cannot drift.
      class Announcement < String
        WIDTH = 96
        ELLIPSIS = "..."

        def initialize(set)
          @set = a_set!(set)
          @summary = summarized(set).freeze
          super(set.size == 1 ? set.first.body : @summary)
          freeze
        end

        # `+str` and `String#encode` hand back THIS class with the ivars
        # dropped, while every other copying operation carries them and every
        # non-copying one returns a plain String. So the husk is refused by
        # name here rather than returning a nil that dies two frames later
        # inside {Question::Set}.
        def set = carried!(@set, "question set")
        def summary = carried!(@summary, "summary line")

        private

        # {#ask}'s own refusal sends callers straight to this constructor, so
        # it has to answer a `Question` or a String in the same voice rather
        # than with `undefined method 'first'`.
        def a_set!(set)
          return set if set.is_a?(Question::Set)

          raise ArgumentError, "an announcement carries a Question::Set (got #{set.class}) -- build one " \
                               "with Question::Set.new(questions:) or Question::Set.from_body"
        end

        def carried!(value, what)
          return value unless value.nil?

          raise ArgumentError, "this announcement lost the #{what} it carried -- `+str` and String#encode " \
                               "copy the bytes without the ivars. Announce the original, or wrap the set again."
        end

        def summarized(set)
          lead = headline(set.first.body)
          set.size == 1 ? lead : "#{lead} (+#{set.size - 1} more)"
        end

        # The first line with anything on it. {Blankness} rather than
        # `String#empty?`: a line of U+200B is not empty and is not
        # `[[:space:]]`, and it would render as an invisible inbox row.
        def headline(body)
          line = body.each_line.lazy.map(&:strip).find { |text| !Blankness.blank?(text) }.to_s
          line.length <= WIDTH ? line : "#{line[0, WIDTH - ELLIPSIS.length]}#{ELLIPSIS}"
        end
      end

      # The model-facing input: one free-text question, or a whole set of them.
      # The human, the addressing, and the promise are the mechanism, not
      # something the model negotiates.
      #
      # Two spellings, because they are two different asks. A bare `question` is
      # the free-text case, and it is also what every non-model caller sends
      # (the approval gate asks through an `#ask`-shaped duck with a rendered
      # String); `questions` carries ids, options, and arities. Exactly one per
      # call, checked below rather than in the schema, because `oneOf` is not in
      # the subset a strict tool schema enforces.
      class Input < Tool::Input
        FORMS = "send `question` for one free-text question, or `questions` for a set"

        field :question, :string,
              description: "One free-text question, in markdown, when there is nothing to choose " \
                           "between. Send this or `questions`, never both."
        field :questions, :array,
              description: "Several questions the human answers in ONE reply. Send this or " \
                           "`question`, never both." do
          field :id, :string, required: true,
                              description: "A short, stable id for this question; the answer cites it."
          field :body, :string, required: true,
                                description: "The question itself, in markdown -- a table, a fenced diff " \
                                             "or a list is often what makes a question answerable."
          field :arity, :string,
                description: "Whether one of the options may be chosen or several. Defaults to single, " \
                             "and means nothing when `options` is omitted."
          field :options, :array,
                description: "The closed list this question may be answered from. Optional: leave it " \
                             "off for a free-text answer." do
            field :id, :string, required: true, description: "A short, stable id for this option."
            field :label, :string, required: true,
                                   description: "The one line a human reads beside the checkbox."
          end
          validates :arity, inclusion: { in: Question::ARITIES }, allow_nil: true
        end

        validate :one_form

        private

        # `:base`, because neither field is at fault on its own -- what is wrong
        # is the pair, and a message hung on `question` would send the model to
        # fix the one it did not send.
        #
        # The priced trade: this leaves top-level `required` EMPTY, so the
        # schema permits `{}` and this tool is the only one in the set that
        # does. `oneOf` would say it on the wire, and it is outside the subset
        # a strict tool schema enforces -- so the rule reaches the model one
        # turn later, through a message written to be acted on rather than
        # merely parsed.
        def one_form
          asked = [question, questions].reject(&:blank?)
          return if asked.one?

          errors.add(:base, asked.empty? ? "asks nothing -- #{FORMS}" : "asks two ways -- #{FORMS}, never both")
        end
      end

      input_model Input

      # The most recent exchange, exposed for observability (the study bench reads
      # the orchestration events): the last Q and A :message events. `nil` until
      # the corresponding half happens.
      attr_reader :name, :last_question, :last_answer

      # `observer` rides the ChainWriter this tool builds (T13): Q and A are
      # exactly the events a Timeline walk can never find, so the session
      # scribe attaches here or not at all. Null default, same as Lineage's --
      # nothing about the unobserved path changes.
      #
      # `agent` is who a HUMAN is told is asking, and it is NOT `name`: that one
      # is the TOOL's name, the bytes the model sees in the tools block. This is
      # per-asker (the main chat's, a child's role), it rides the Q event under
      # {ASKED_BY}, and it is the same value {CLI::Wiring::Askers#enrol} already
      # announced to the TTY and the desktop -- passed down here so every
      # surface, including the ones that only ever see the record, reads one
      # name. Absent, the envelope's correlation stands in as it always did.
      def initialize(parent:, name: "ask_human", agent: nil, observer: Event::ChainWriter::Null.new)
        super()
        @parent = parent
        @name = name
        @agent = agent
        @chain_writer = Event::ChainWriter.new(observer:)
        @outstanding = Outstanding.new
      end

      # The description is data, not computation: it is the single
      # highest-leverage lever on tool-call accuracy, and hoisting it out of the
      # method is what keeps a paragraph the model actually needs from arguing
      # with Metrics/MethodLength.
      DESCRIPTION = "Asks the human operator and returns their answer as the result. Use it " \
                    "when a decision needs a human -- a missing detail, a judgement call, " \
                    "an approval -- rather than guessing. The call waits for the reply, " \
                    "which stops the run until the human is back, so ask for everything " \
                    "you need in ONE call rather than calling this again later. Count the " \
                    "decisions you are stuck on first: exactly one, and send `question`; " \
                    "more than one, and send `questions` with an entry per decision. Every " \
                    "question body is markdown, and a table, a fenced diff or a list is " \
                    "often what makes a question answerable. `options` is optional -- give " \
                    "it to close the answer to a fixed list (`arity` says whether one may " \
                    "be chosen or several), leave it off for a free-text answer."

      def description = DESCRIPTION

      # The async-continue seam: emit Q to the human's inbox and return a pending
      # promise. Does not await -- the caller decides when (or whether) to block
      # on the answer.
      #
      # Every value this takes is a String, and {Announcement} is why.
      #
      # The String arm now builds a {Question} where it used to write the bytes
      # straight into the body, so it answers {Question}'s rules and raises
      # where it never used to: an unclosed ``` fence, a body past
      # {Question::MAX_BODY}, a blank body, invalid UTF-8, and nil. That is a
      # contract change to a published duck ({Approval::Gate} and
      # {Gherkin::Approval} both ask through one) and it is documented rather
      # than swallowed -- a rescue here would hand the human a question whose
      # bytes are not the ones the caller wrote, which is the failure this tool
      # exists to prevent. The model-facing path DOES convert them, in
      # {#requested_set}, because a model can act on a legible refusal.
      #
      # @param question [Announcement, String] a set wearing the text a human
      #   is shown, or one free-text question -- a bare String is the set of
      #   one, which is what every `#ask`-shaped duck sends.
      # Asking a second set while one is unanswered is refused ({Outstanding}),
      # and refused before the Q event is written.
      #
      # @raise [ArgumentError] when the String cannot be a {Question} body
      # @raise [QuestionOutstanding] when a set is already awaiting a reply
      # @return [Pending] a {Lain::Promise} wearing the Q event's digest,
      #   resolved by {#reply} with the human's answer
      def ask(question)
        announcement = announcement_for(question)
        @outstanding.open { emit_question(announcement) }
      end

      # Deliver the human's answer to the set it answers: write A back to the
      # asker AND resolve that set's promise.
      #
      # `digest` NAMES the set being answered, so both edges this writes -- A's
      # causal parent here, and the delivery commit's through
      # {#take_answered_questions} -- come from the answer rather than from
      # "whichever set was asked last".
      #
      # `digest` is REQUIRED, and the default it replaced was the transitional
      # one T7 left for its callers to convert (T11 converted them). The
      # default answered "which set is outstanding", which is a different
      # question from "which set was this answer written for": withdraw a set
      # (a stopped run, see {#awaited}), ask another, and an answer typed for
      # the first resolved the second and was cited against it. The live way
      # in was a stale `/inbox` line, which the drain could leave listed after
      # the run that asked it was gone. So a caller that cannot name its set
      # is a caller with a bug, and the arity says so at the door -- before
      # any promise moves and before anything is written.
      #
      # Both guards run BEFORE the Store write: the Store is the append-only
      # record, so a reply this method is about to refuse must leave no A event
      # behind -- the refusal happens or the event lands, never both.
      #
      # @param answer [String] what the human typed
      # @param digest [String] the Q event of the set this answers
      # @raise [NoPendingQuestion] naming the digest, when no set of that name
      #   is awaiting a reply
      # @raise [Promise::AlreadyResolved] when that set was already answered
      # @return [Lain::Event] the A :message event
      def reply(answer, digest)
        pending = @outstanding.answerable!(digest)
        parent = parent_timeline
        @last_answer = write_message(parent, from: HUMAN, to: identity(parent),
                                             body: { "answer" => answer },
                                             causal_parents: [pending.digest])
        pending.resolve(answer)
        @last_answer
      end

      # Whether a question is emitted and still unanswered -- what a frontend
      # polls to decide it must prompt the human.
      def pending? = @outstanding.pending?

      # The delivery-commit consumption seam (I6, ruled): the digests of every
      # question whose answer has passed the sync gate since the last
      # hand-over, then cleared. The Agent's tool_result commit cites these as
      # causal parents -- the :turn edge that is the ONLY consumption
      # {Event::Projection#pending} counts (a reply :message alone never
      # retires its question). Handed over exactly once because the edge
      # belongs to the one commit that delivers the answer; an {#ask}/{#reply}
      # pair that never passed {#perform} contributes nothing, since no
      # tool_result delivers it.
      #
      # @return [Array<String>] the answered questions' digests, in ask order
      def take_answered_questions
        answered = @answered_questions.to_a
        @answered_questions = nil
        answered
      end

      protected

      # The sync gate: emit the question, then await the answer and return it as
      # the tool_result. Awaiting parks this fiber until {#reply} resolves the
      # promise; a reply already in hand returns at once. The await returning
      # means THIS tool_result carries the answer into the conversation, so the
      # digest of THIS set -- read off the promise, never off `@last_question` --
      # is remembered for the delivery commit to cite (see
      # {#take_answered_questions}).
      def perform(input, _invocation)
        pending = ask(Announcement.new(requested_set(input)))
        answer = awaited(pending)
        (@answered_questions ||= []) << pending.digest
        Tool::Result.ok(answer)
      end

      private

      # The await, plus the abandonment an unwind owes this asker: a stop raised
      # while parked here (the Ctrl-C path, or a caller's timeout) means nobody
      # will ever deliver this answer, so the set stops being outstanding and
      # the asker can ask again -- the same shape {Approval::Queue#settle} uses
      # for a requester that vanished. The Q :message stays UNCONSUMED in the
      # record, because a cancelled question is genuinely unanswered.
      def awaited(pending)
        pending.await
      ensure
        @outstanding.abandon(pending)
      end

      # Q, and the digest {Outstanding} names its set by.
      def emit_question(announcement)
        parent = parent_timeline
        @last_question = write_message(parent, from: identity(parent), to: HUMAN,
                                               body: emitted_body(announcement),
                                               causal_parents: [parent.head_digest].compact)
        @last_question.digest
      end

      # The model's input as the value everything below speaks. `from_body` is
      # Question's one documented door in from raw data, and what it refuses --
      # a duplicate id, an unclosed fence, a set past its byte bound -- is an
      # input defect, so it is re-raised as one and reaches the model carrying
      # this tool's name.
      #
      # `to_h.compact` drops the members the model left out, so Question's own
      # permissive defaults (single, no options) apply rather than a nil
      # reaching a rule that would refuse it.
      def requested_set(input)
        return free_text_set(input.question) if input.questions.blank?

        Question::Set.from_body("questions" => input.questions.map { |question| question.to_h.compact })
      rescue ArgumentError => e
        invalid!(e.message)
      end

      # What {#ask} was handed, as the announcement it carries: our own wrapper
      # passes through, and any other String is one free-text question.
      #
      # `is_a?` rather than `respond_to?(:set)`, which is the one place this
      # file does not duck-type: {Announcement} is this class's own currency,
      # not a duck anyone outside implements, and `+str`/`String#encode` return
      # the class with its ivars dropped -- a husk that answers `respond_to?`
      # and holds nil. The type test, plus the reader's own guard, is what
      # makes that fail at the door instead of inside {Question::Set}.
      def announcement_for(question)
        bare_set!(question)
        question.is_a?(Announcement) ? question : Announcement.new(free_text_set(question))
      end

      # Named, because the mistake it catches would otherwise surface as "a
      # question body must be a String or a Symbol", which names neither the
      # fix nor the reason there is one.
      def bare_set!(question)
        return unless question.is_a?(Question::Set)

        raise ArgumentError, "wrap a question set as #{Announcement}.new(set): the value #ask is handed is " \
                             "also the value the arrival seam announces, and that must be a String"
      end

      # One question, no options: the free-text arm, which is a real arm of the
      # design rather than a degenerate set (see {Question#free_text?}).
      def free_text_set(question)
        Question::Set.new(questions: [Question.new(id: FREE_TEXT_ID, body: question)])
      end

      # The set, plus the one-line summary the inbox reads under the key it has
      # always read -- both taken off the announcement, which derived them once
      # -- plus this asker's name, when it has one to give ({ASKED_BY}).
      # {Question::Set#to_body} hands back a fresh copy, so merging here reaches
      # nothing the frozen set holds, and {Question::Set.from_body} reads only
      # the keys it owns, so a richer body still rebuilds exactly the set that
      # was asked. Nothing about the tools block moves: this is the event, not
      # the schema.
      def emitted_body(announcement)
        body = announcement.set.to_body.merge("question" => announcement.summary)
        Blankness.blank?(@agent) ? body : body.merge(ASKED_BY => @agent)
      end

      # A :message event in the shared Store, delegated to the shared
      # {Event::ChainWriter}: a :message Payload out of line, an envelope
      # carrying the attribution and the causal edges, correlated to the
      # asker's chain. Causal-only -- no `render_parent` -- so it never
      # enters a render chain.
      def write_message(parent, from:, to:, body:, causal_parents:)
        @chain_writer.put(parent, kind: :message, from:, to:, causal_parents:, body:)
      end

      # A chain is named by its root event digest (the pinned correlation
      # convention), so the asker is addressable without new id machinery --
      # the same derivation Subagent's Lineage uses.
      def identity(timeline) = Event::ChainWriter.correlation_of(timeline)

      # The parent Timeline, live: a Timeline passes through, a thunk is called
      # (the toolset is built before the Agent, so the exe hands a
      # `-> { agent.timeline }` that reads the head at the instant of the call).
      def parent_timeline
        @parent.respond_to?(:call) ? @parent.call : @parent
      end
    end
  end
end

# Both reopen AskHuman -- Notifying subclasses it -- so they load after the
# class body; this file is the ask_human subtree's index (see CLAUDE.md,
# Requires).
require_relative "ask_human/directory"
require_relative "ask_human/notifying"
