# frozen_string_literal: true

module Lain
  module Tools
    # Puts a question to the human and returns their answer -- the human as a
    # capability-gated, high-latency agent whose replies are just events in the
    # log. The exchange is two :message events in the shared Store: an outbound
    # **Q** to the human's inbox and an inbound **A** back to the asker. Neither
    # renders into any prompt chain; the model receives the answer through this
    # tool's ordinary `tool_result`.
    #
    # == A promise, not a blocking read
    #
    # {#ask} emits Q and hands back a pending {Lain::Promise} WITHOUT awaiting.
    # Awaiting parks the fiber, not the reactor, so concurrent work proceeds
    # while the answer is outstanding. {#perform} is the SYNC GATE -- emit then
    # await -- so one mechanism yields both modes and there is no separate sync
    # API.
    #
    # == The reply seam
    #
    # {#reply} writes A to the Store AND resolves the pending promise. Pushing
    # the message is the whole of what the frontend does: the promise is this
    # tool's own business, never something the frontend reaches into.
    #
    # An answer NAMES the set it answers ({Outstanding}), and both edges written
    # from it come from that name. "The set asked most recently" is a different
    # thing, and citing it is how an answered question stays in the inbox
    # forever while an unanswered one silently vanishes (see {Pending}).
    #
    # == One call, a whole SET of questions
    #
    # A cost decision rather than a taxonomy: this tool is not `parallel_safe?`,
    # so {Agent::ToolRunner} runs it as a barrier. N questions asked one at a
    # time are N barriers -- N model turns and N context renders for one
    # decision. A set collapses that to one, and the price is that it resolves
    # as a whole.
    #
    # == An answer that costs more than it is worth
    #
    # A reply lands straight in the asker's context, so an unmeasured one is
    # the largest thing a turn can spend. {ANSWER_BOUND} measures it, and
    # because this is the one tool with somebody there to be asked, an overrun
    # is HANDED BACK rather than refused: the human is shown the measurement
    # and their own words and decides. The handback re-opens the set already in
    # the record instead of asking again -- see {#reopened}.
    #
    # == Injection, and the single-question invariant
    #
    # `parent:` is the live parent-Timeline handle (a Timeline or a thunk, since
    # the toolset is built before the Agent); the shared Store rides on it, and
    # the asker's identity is the parent chain's correlation. An instance
    # belongs to one agent's toolset and a synchronous dispatch has no
    # interleaving writer, so at most one set awaits a reply at a time --
    # {Outstanding} ENFORCES that rather than assuming it. An actor mode that
    # asks concurrently must carry its promises on events, not here.
    class AskHuman < Tool
      # Who a question is addressed to by default. The run's own asker has no
      # parent to name, so this is what `#initialize`'s `to:` defaults to --
      # a child's asker is handed its parent's correlation instead.
      HUMAN = "human"

      # Every question in a set carries an id -- the join key the answer
      # document renders and the parser reads back -- and a caller who handed
      # over a bare String never chose one.
      FREE_TEXT_ID = "question"

      # The body key the asker's NAME rides on, because the ENVELOPE cannot
      # carry it: `from` is the asker chain's ROOT digest, and an `:inherit`
      # child is `parent.fork`, so child and parent share a root PERMANENTLY and
      # render one sender everywhere. `:inherit` is the default for a `@role`
      # spawn, so that is the common case.
      #
      # The TTY reads the name off the ARRIVAL, but
      # {Frontend::Neovim::InboxView} folds the record stream and never sees
      # one -- so the name has to be IN the record for the two surfaces to name
      # an asker the same way.
      ASKED_BY = "asked_by"

      # What a human's own reply may cost the context it lands in, and what an
      # overrun is put back to them as. Its own object because measuring an
      # answer and reading what a human's next line MEANS are one
      # responsibility, and parking on an answer and writing the record is
      # another -- which is all the rest of this class does.
      #
      # A HANDBACK rather than a cap or a refusal, which is {Tool::Bounds}'
      # third shape and the reason it exists: the words are the human's, they
      # are still theirs after a bound has measured them, and this tool is the
      # only one holding a channel back to whoever wrote them. So the question
      # is not "does this fit" but "does this fit, and do you still want it".
      #
      # It does not bind an unattended run at all, and that is worth stating
      # rather than discovering: {Unattended#perform} is a full override that
      # refuses without ever calling {AskHuman#perform}, so nothing there
      # measures anything -- and nothing there can park on a confirm either.
      module Ceiling
        # {Question::Answer::MAX_COMMENT}, and taking it from there rather than
        # picking a number is the argument: the STRUCTURED answer path already
        # refuses past that byte count, so free text was one arm of one tool
        # where a human could put a megabyte into a parent's context with
        # nothing to say so. Read from the constant, the two arms cannot drift.
        BOUND = Tool::Bounds::Handback.new(limit: Question::Answer::MAX_COMMENT)

        # What the human is told overran, in their own terms.
        SUBJECT = "your reply"

        # The whole line a human types to send an oversized reply as it stands.
        CONFIRMATION = "send"

        # {Tool::Bounds::Overrun#actions} are AUDIENCE-BOUND and nothing in the
        # bound can check it: these are read at a `human> ` prompt by the person
        # who typed the reply, never by a model being refused, so they name
        # keystrokes rather than narrower tool calls.
        #
        # Frozen through {Tool::Bounds.offer} rather than by `#freeze`, which
        # would leave the ELEMENTS mutable: `# frozen_string_literal: true` does
        # not reach an INTERPOLATED literal, so the first of these was a mutable
        # String reachable from a constant, and appending to it changed what
        # every later handback said. That is the trap {Tool::Bounds.phrase}'s own
        # comment names, and `spec/value_object_shareability_spec.rb` sweeps
        # value objects rather than constants, so nothing else would have caught
        # it.
        ACTIONS = Tool::Bounds.offer(["type `#{CONFIRMATION}` to send it anyway",
                                      "type a shorter reply instead"])

        # The door {Tool::Bounds::Handback} tells both its consumers to use:
        # one call, `nil` when it fits, no guard to forget.
        #
        # @param answer [String] what the human typed
        # @return [Tool::Bounds::Overrun, nil]
        def self.overrun(answer) = BOUND.measure(subject: SUBJECT, content: answer, actions: ACTIONS)

        # What the human is shown, as the value the arrival seam carries. It
        # names {Tool::Bounds::Overrun#message} and `#content` deliberately and
        # never interpolates the {Tool::Bounds::Overrun} itself, whose
        # `#inspect` is redacted for the Journal's sake.
        def self.handback(over) = Handback.new(over)

        # The whole line, so a reply that merely CONTAINS the word is a reply
        # and never consent. Case and surrounding space are how somebody types,
        # not what they mean.
        def self.confirmed?(answer) = answer.strip.casecmp?(CONFIRMATION)
      end

      # Where an arrival goes when nobody wired one. The seam is outbound-only
      # and String-shaped, exactly as {Notifying}'s is, so a tool built without
      # a queue announces to nothing rather than guarding at the one call site
      # that reaches it.
      module NoArrival
        def self.call(_text) = nil
      end

      # The answer nobody gave, riding the seam an answer rides.
      #
      # A String subclass, for {Announcement}'s reason: the reply seam is
      # String-shaped end to end, so a non-String would either need every
      # participant to learn about it or surface as an inspect where a sentence
      # belongs. As a String it degrades to the refusal sentence, and only
      # {AskHuman} -- which writes the record and builds the tool_result --
      # asks what it is.
      #
      # Both exits read the wording off {REFUSAL} rather than off the instance,
      # so the invariant belongs to the CLASS; `#initialize` still freezes, but
      # that is a courtesy rather than the thing being relied on.
      class Unanswered < String
        # It says WHAT HAPPENED, never WHO LEFT, and that is not stylistic.
        # The nil this is written from cannot tell a vanished stdin from a
        # human pressing Ctrl-D on an empty line at a live prompt -- both are
        # `nil`, and in the second case the human is still sitting there and
        # answers the next question. A sentence claiming the session is
        # unattended is therefore false in its COMMONEST trigger, and false in
        # two places that cannot check it: the model, and `body["unanswered"]`
        # in the journal. So it claims only what is true in every case.
        #
        # {Unattended} may name its door because it knows it: the run was
        # STARTED `--non-interactive`, a fact about the process rather than a
        # guess about a terminal.
        REFUSAL = "the reply prompt for this question reached end-of-file with no answer typed, so " \
                  "ask_human has nobody to put this to and no answer will ever come back. Decide with what " \
                  "you have, or stop and say what you needed."

        # Nobody said it and the record must not imply anybody did -- so a
        # NAME rather than a nil or an omitted record, and a journal reader
        # never guards.
        NOBODY = "nobody"

        def initialize
          super(REFUSAL)
          freeze
        end

        # NOT under `"answer"`: that key is the human's own words to every
        # reader of an A event, and an empty string under it is exactly the
        # utterance nobody made that this record exists instead of.
        #
        # {REFUSAL} rather than `to_s`, and that is the whole invariant:
        # freezing in `#initialize` binds the wording to `.new`, not to the
        # CLASS -- `+U.new`, `#dup`, `Marshal.load` and `.allocate` all yield
        # unfrozen instances that pass the guard, so a mutated one journalled
        # arbitrary bytes under `from: "nobody"`. Read off the constant, no
        # instance can put words in this record's mouth. {AskHuman#perform}
        # reads it for the same reason.
        def recorded = { "unanswered" => REFUSAL }
      end

      class NoPendingQuestion < Error; end
      class QuestionOutstanding < Error; end

      # The promise a question set is answered through, wearing the digest of
      # the Q event it answers. That digest is the whole point: "asked most
      # recently" is NOT "being answered", and a :turn edge is the ONLY
      # consumption {Event::Projection#pending} counts -- so the wrong digest
      # leaves an answered question in the human's inbox forever while an
      # unanswered one silently vanishes.
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
      # A second set opening while one is unanswered is a coordination bug, not
      # a queue. It is NOT what makes an answer unambiguous -- that is the
      # digest {#reply} requires; this only keeps one asker from holding two
      # sets it could not tell apart. A promise nobody can address by name is a
      # promise a late answer resolves by accident.
      #
      # A guard, not a lock: {#open}'s check and its claim straddle the Q write,
      # which an attached observer's journal can turn into a yield point, so two
      # fibers sharing ONE asker could both pass it. Unreachable rather than
      # impossible -- one asker is built per ASKER and no child inherits the
      # PARENT's ({Tools::Subagent::ChildBuilder} enrols each child its own). No
      # two fibers share one asker by any wired path, and a mutex here would not
      # be what made that true.
      class Outstanding
        # An inbox line that outlived its set. Written to be read at a `human>`
        # prompt: what happened, and that nothing was lost by it.
        WITHDRAWN = "no question is awaiting a reply -- it was answered already, or withdrawn when the run " \
                    "that asked it was stopped. The inbox line offering it is stale: nothing you type here " \
                    "is recorded, and nothing is waiting on it."

        # Where an asker starts, and what an abandoned question leaves behind.
        # It answers the same four messages a {Pending} does, so no guard below
        # asks whether one exists.
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
        # append-only Store and leaves nothing for a later reply to cite.
        #
        # The block yields a digest rather than writing one, which is what lets
        # {AskHuman#reopened} re-open the set already in the record when an
        # answer is handed back: a second answerable set, one Q event, one
        # inbox row.
        def open
          raise QuestionOutstanding, still_outstanding if pending?

          @pending = Pending.new(yield)
        end

        # Both refusals happen before the caller's Store write: the refusal
        # happens or the A event lands, never both.
        def answerable!(digest)
          named!(digest)
          raise Promise::AlreadyResolved, "the question set #{digest} was already answered" if @pending.resolved?

          @pending
        end

        # Open a set and hand it to the block, letting go of it again if the
        # block raises. What follows an open is the ARRIVAL that tells a human
        # the set is there, and an arrival that raises with the set already
        # claimed leaves this asker holding a question nobody can answer for
        # the rest of its life -- every later ask refused as outstanding, with
        # no park to run {AskHuman#awaited}'s `ensure`. Reachable because a
        # handback puts an unbounded payload on that seam: an argv too long for
        # `execve` raises there.
        #
        # {Notifying#ask} has the same shape and is not fixed here, being a
        # different file and a pre-existing one -- but it is the same hazard,
        # and whoever closes it should close it through this.
        def opened(digest)
          pending = open { digest }
          yield pending
          pending
        rescue StandardError
          abandon(pending)
          raise
        end

        # Identity, not digest: only the opener may abandon what it opened, and
        # a second reply naming an already-answered set must still be refused as
        # answered rather than as unknown.
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

        # Two mistakes, two sentences, both read by a HUMAN at a reply prompt
        # and not only by the model. An `/inbox` item can outlive the set it
        # names -- a cancelled run withdraws the set and the line stays -- and
        # "nothing is pending" is true and useless there, reading as a bug in
        # the reply rather than as a stale line. The second names the STATE this
        # asker is in, never the ivar, because "holds nil" tells a reader
        # nothing.
        def unnamed(digest)
          return WITHDRAWN if digest.nil?

          "no question set #{digest} is awaiting a reply -- this asker holds #{@pending.held}"
        end
      end

      # The questions whose answers passed the sync gate since the last
      # hand-over, waiting for the one commit that delivers them. Its own
      # object because the nil-then-Array dance it replaces was a guard at
      # every touch: `@answered_questions ||= []` at the push and `.to_a` at
      # the take, both of which read as though a missing list were a state
      # rather than an empty one.
      class Answered
        def initialize = @digests = []

        def push(digest) = @digests << digest

        # Emptied as it is read: the edge belongs to the ONE commit that
        # delivers these answers, so a second reader must find nothing.
        def take = @digests.slice!(0..)
      end

      # The live parent-Timeline handle, and the ONE thing a handle can be
      # asked beyond reading a head: to settle the record the question about to
      # be written will cite.
      #
      # A Q cites the head its asker stood at when it asked, and on reload that
      # citation resolves only if the record ALREADY carries that head. For the
      # chat's own asker it always does -- {CLI::Repl::Ask} catches the record
      # up before it anchors anything, for this reason. For a subagent's it
      # does not: a child's turns reach the record when its ITERATION returns
      # ({Middleware::JournalTurns}), and a question that parks never returns
      # from the one it was asked in, so the cited turn reached the file only
      # if a human happened to answer. Unanswered, the session would not fork
      # and would not resume.
      #
      # So a spawn hands over a handle that promotes the child's committed
      # turns first ({Tools::Subagent::ChildBuilder#build}, the only place that
      # can name a child), and every other caller gets one with nothing to
      # promote.
      class Parent
        # Whoever owns this record catches it up itself, so a question written
        # against this handle already cites a head the record holds. It takes
        # the Timeline it is not going to promote, because a settler that could
        # be handed one and a settler that could not would be two ducks.
        module Null
          def self.call(_timeline) = nil
        end

        # `is_a?` rather than `respond_to?(:settled)`, for {#announcement_for}'s
        # reason: this is this class's own currency, and every other shape --
        # a Timeline, a thunk reading one -- becomes one here.
        def self.over(handle) = handle.is_a?(Parent) ? handle : new(read: handle)

        # Who a question written against this handle is addressed to, absent
        # an explicit override at {AskHuman#initialize}. {HUMAN} by default:
        # a bare Timeline or thunk, wrapped by {.over}, names nobody in
        # particular. {Tools::Subagent::ChildBuilder::Chain#asking_handle}
        # is the one place that builds a handle carrying something else --
        # the correlation of the chain a child was spawned under -- so the
        # address rides the SAME handle the identity and the citation already
        # ride, and every enrolment path that forwards this handle unchanged
        # (an attended run's, an unattended one's, the seam a spawn was never
        # taught about) inherits it without having to learn a new keyword.
        attr_reader :to

        # The rest of the road from {#to} to an actual human mailbox, empty
        # when {#to} already IS one. `to:` alone answers "the record shows the
        # child asked the parent" -- it says nothing about how the parent's
        # OWN mailbox is reached, and a parent is itself a spawned child more
        # often than not. Each entry is one further hop {AskHuman#ask}'s own
        # infrastructure relays through, mechanically, ending in {HUMAN}: the
        # value is an explicit, JOURNALED chain, not anything reasoning about
        # where to send a question.
        attr_reader :escalation

        # @param read [Lain::Timeline, #call] a Timeline, or a thunk reading the
        #   live one, since the toolset is built before the Agent
        # @param settle [#call] takes the Timeline and puts into the record
        #   everything a question written against its head may cite
        # @param to [String] who a question written against this handle is
        #   addressed to; see {#to}
        # @param escalation [Array<String>] the further hops beyond `to:`; see
        #   {#escalation}
        def initialize(read:, settle: Null, to: HUMAN, escalation: [])
          @read = read
          @settle = settle
          @to = to
          # `.dup.freeze` rather than trusting the caller's Array frozen: a
          # `freeze` that left a REACHABLE mutable Array behind would not be
          # the mechanical "no reachable mutable state" this codebase's value
          # objects are held to, and here the mutable state would be WHERE
          # questions get sent -- `handle.escalation << "elsewhere"` must not
          # be a live wire into every future question this handle asks.
          @escalation = escalation.dup.freeze
          freeze
        end

        # The live Timeline: a Timeline passes through, a thunk is called.
        def timeline = @read.respond_to?(:call) ? @read.call : @read

        # The same Timeline, with the record caught up to it first.
        #
        # ONE read, and the settler is HANDED it. "The head cited is the head
        # promoted" is the whole of this class, and a second `timeline` after
        # the settle would make that an agreement between two reads of a live
        # object rather than a property of the code -- true today only because
        # `ask_human` is a barrier and no fiber can commit between them, which
        # is a fact about the caller and not about this.
        def settled = timeline.tap { |live| @settle.call(live) }

        # Relays `message` one hop per {#escalation} entry, each citing the
        # message before it rather than a live agent head -- see
        # {AskHuman#emit_question} for why that is what lets a relay never
        # wait on a parent's own dispatch. The block is handed
        # FROM/TO/BODY/CAUSAL_PARENTS and answers with the {Lain::Event} it
        # put, so this stays what this class already is -- data about where a
        # question goes -- and the ChainWriter stays the caller's own.
        def escalate(message)
          escalation.inject(message) do |previous, to|
            yield(from: previous.to, to:, body: previous.body, causal_parents: [previous.digest])
          end
        end
      end

      # One question set, wearing the text a human is shown for it -- and the
      # ONLY way a set reaches {#ask}.
      #
      # A String subclass, which is a shape to justify rather than assume. The
      # arrival seam hands the notifier ITS OWN argument verbatim, and that
      # value reaches the TTY's arrival line AND a dunstify **argv** element. A
      # Data value renders there as an inspect and puts a non-String in an
      # argv, so what `#ask` is handed stays a String and {#set} is how this
      # tool gets the whole set off it. Structural rather than conventional:
      # because a bare {Question::Set} is refused, no caller can put a
      # non-String on that seam.
      #
      # == Two renderings, derived once
      #
      # The bytes this value IS are the WHOLE question a human answers, so for
      # a LONE question they are the body VERBATIM. Clamping them would be a
      # real regression: the description invites tables and fenced diffs, and a
      # question cut to its first line is one a human cannot answer.
      #
      # {#summary} is the other rendering -- one clamped line, what every
      # ONE-LINE surface shows. Clamped rather than refused, unlike every field
      # {Question} itself bounds: these bytes were already accepted as a
      # question, and this is a RENDER of them, not a value anybody answers.
      # Both derive here, once, so the surfaces cannot drift.
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
        # dropped. The husk is refused by name here rather than returning a nil
        # that dies two frames later inside {Question::Set}.
        def set = carried!(@set, "question set")
        def summary = carried!(@summary, "summary line")

        # The third rendering: the block a surface shows BELOW its one-line
        # row, and the same markdown the editor opens the set in, so the two
        # never drift. Asked for by message rather than assembled by whoever is
        # drawing, because {Handback} answers it too with something that is not
        # a question document at all -- and a surface that type-tested for one
        # of them silently drew nothing for the other.
        def document = Question::Document.unanswered(set)

        private

        # {#ask}'s refusal sends callers straight here, so it has to answer a
        # `Question` or a String in the same voice rather than with `undefined
        # method 'first'`.
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

        # {Blankness} rather than `String#empty?`: a line of U+200B is neither
        # empty nor `[[:space:]]`, and would render as an invisible inbox row.
        def headline(body)
          line = body.each_line.lazy.map(&:strip).find { |text| !Blankness.blank?(text) }.to_s
          line.length <= WIDTH ? line : "#{line[0, WIDTH - ELLIPSIS.length]}#{ELLIPSIS}"
        end
      end

      # What a human is shown when their OWN reply overran, on the seam an
      # arrival rides. A String subclass for {Announcement}'s reason: the value
      # this seam carries is handed to the notifier verbatim, reaching a
      # dunstify argv and a TTY line, so a Data value would render there as an
      # inspect.
      #
      # THREE renderings, derived once, because the surfaces cannot be allowed
      # to drift:
      #
      # * the BYTES are the whole thing -- the measurement, then every byte of
      #   the reply -- which is what the desktop notification carries and what
      #   a caller wanting the payload reads;
      # * {#summary} is the one line every one-line surface shows. Unclamped
      #   and needing no clamp, unlike {Announcement#summary}: it is
      #   {Tool::Bounds::Overrun#message}, composed from a constant subject,
      #   two integers and constant actions, so its width is bounded by the
      #   digits in a byte count. Announced UNSUMMARIZED it printed 5 MiB as a
      #   single terminal line, which is what this rendering exists to prevent.
      # * {#document} is the block `/inbox` draws below its listing -- the
      #   whole thing again, deliberately, because that surface's job is to
      #   show what is about to be confirmed and a preview there would be
      #   truncation wearing a refusal's clothes.
      #
      # Both are DERIVED from the bytes rather than carried in ivars, so the
      # husk `+str` and `String#encode` leave behind -- this class with every
      # ivar dropped, the failure {Announcement#carried!} exists for -- cannot
      # arise here at all.
      class Handback < String
        def initialize(over)
          super("#{over.message}\n\n#{over.content}")
          freeze
        end

        # The first line, which IS the bound's sentence: the bytes are that
        # sentence, a blank line, and the reply.
        def summary = each_line.first.to_s.chomp

        def document = self
      end

      # Two spellings, because they are two different asks. A bare `question`
      # is the free-text case, and also what every non-model caller sends;
      # `questions` carries ids, options and arities. Exactly one per call,
      # checked below rather than in the schema, because `oneOf` is not in the
      # subset a strict tool schema enforces.
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

        # `:base`, because neither field is at fault on its own -- what is
        # wrong is the pair, and a message hung on `question` would send the
        # model to fix the one it did not send.
        #
        # The priced trade: top-level `required` stays EMPTY, so the schema
        # permits `{}` and this tool is the only one that does. The rule
        # therefore reaches the model one turn later, through a message written
        # to be acted on rather than merely parsed.
        def one_form
          asked = [question, questions].reject(&:blank?)
          return if asked.one?

          errors.add(:base, asked.empty? ? "asks nothing -- #{FORMS}" : "asks two ways -- #{FORMS}, never both")
        end
      end

      input_model Input

      # The most recent exchange, for observability. An exchange leaves EITHER
      # an answer or an unanswered record, never both, which is what makes the
      # pair of readers two facts rather than one field with a flag.
      attr_reader :name, :last_question, :last_answer, :last_unanswered

      # `observer` rides the ChainWriter this tool builds: Q and A are exactly
      # the events a Timeline walk can never find, so the session scribe
      # attaches here or not at all.
      #
      # `agent` is who a HUMAN is told is asking, and it is NOT `name` -- that
      # one is the TOOL's name, the bytes the model sees in the tools block.
      # This is per-asker, rides the Q event under {ASKED_BY}, and is the same
      # value the TTY and desktop were already announced, so every surface reads
      # one name. Absent, the envelope's correlation stands in.
      #
      # `notify` is where an arrival goes -- the run's own question queue, or
      # {NoArrival}. It is declared HERE rather than only on {Notifying}
      # because {Notifying} announces every ASK and a handback is not one: the
      # set is already in the record, and re-announcing it is how the human is
      # re-prompted for a reply they were just shown the measurement of.
      # {Notifying} still overwrites it, so an enrolled asker is unchanged.
      #
      # `to` is who the Q is addressed to and who the eventual A is
      # attributed FROM -- one value for both ends, so a reader walks Q to A
      # and finds the same identity closing the loop rather than two
      # different ones straddling one exchange. Unset, it rides the `parent`
      # handle instead of defaulting here a second way -- see {Parent#to} for
      # who inherits what. Passing `to:` explicitly still overrides, for a
      # caller with no handle worth carrying an address on at all.
      def initialize(parent:, name: "ask_human", agent: nil, observer: Event::ChainWriter::Null.new, to: nil,
                     notify: NoArrival)
        super()
        @parent = Parent.over(parent)
        @name = name
        @agent = agent
        @to = to || @parent.to
        @chain_writer = Event::ChainWriter.new(observer:)
        @outstanding = Outstanding.new
        @notify = notify
        @answered = Answered.new
      end

      # Hoisted out of the method so a paragraph the model actually needs is
      # not arguing with Metrics/MethodLength.
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

      # The async-continue seam: emit Q to the human's inbox and return a
      # pending promise. Does not await -- the caller decides when, or whether,
      # to block on the answer. Asking a SECOND set while one is unanswered is
      # refused ({Outstanding}), before the Q event is written.
      #
      # The String arm builds a {Question}, so it answers {Question}'s rules and
      # RAISES on an unclosed fence, an over-long or blank body, invalid UTF-8
      # and nil. That is a contract on a published duck, documented rather than
      # swallowed: a rescue here would hand the human a question whose bytes are
      # not the ones the caller wrote, the failure this tool exists to prevent.
      # The model-facing path converts them instead, in {#requested_set},
      # because a model can act on a legible refusal.
      #
      # @param question [Announcement, String] a set wearing the text a human
      #   is shown, or one free-text question -- a bare String is the set of
      #   one, which is what every `#ask`-shaped duck sends.
      # @return [Pending] a {Lain::Promise} wearing the Q event's digest,
      #   resolved by {#reply} with the human's answer
      # @raise [ArgumentError] when the String cannot be a {Question} body
      # @raise [QuestionOutstanding] when a set is already awaiting a reply
      def ask(question)
        announcement = announcement_for(question)
        @outstanding.open { emit_question(announcement) }
      end

      # Write A back to the asker AND resolve that set's promise.
      #
      # `digest` NAMES the set being answered, so both edges written -- A's
      # causal parent, and the delivery commit's -- come from the answer rather
      # than from "whichever set was asked last". It is REQUIRED because the
      # two are different questions: withdraw a set (a stopped run, see
      # {#awaited}), ask another, and an answer typed for the first resolved the
      # second and was cited against it. The live way in was a stale `/inbox`
      # line the drain left listed after the run that asked it was gone.
      #
      # Both guards run BEFORE the Store write: a reply about to be refused must
      # leave no A event behind in the append-only record.
      #
      # An {Unanswered} is an answer in every way this method cares about -- it
      # names a set, resolves its promise and leaves a record -- and in exactly
      # one way it is not: nobody said it. So it comes down THIS path, and
      # {#recorded_reply} is the single place the difference is drawn.
      #
      # @param answer [String, Unanswered] what the human typed, or the answer
      #   nobody gave
      # @param digest [String] the Q event of the set this answers
      # @return [Lain::Event] the A :message event, or the record that says the
      #   question went unanswered
      # @raise [NoPendingQuestion] naming the digest, when no set of that name
      #   is awaiting a reply
      # @raise [Promise::AlreadyResolved] when that set was already answered
      def reply(answer, digest)
        pending = @outstanding.answerable!(digest)
        recorded = recorded_reply(answer, pending)
        pending.resolve(answer)
        recorded
      end

      # What a frontend polls to decide it must prompt the human.
      def pending? = @outstanding.pending?

      # The digests of every question whose answer has passed the sync gate
      # since the last hand-over, then cleared. The Agent's tool_result commit
      # cites these as causal parents -- the :turn edge that is the ONLY
      # consumption {Event::Projection#pending} counts, since a reply :message
      # alone never retires its question. Handed over exactly once, because the
      # edge belongs to the one commit that delivers the answer.
      #
      # @return [Array<String>] the answered questions' digests, in ask order
      def take_answered_questions = @answered.take

      protected

      # The sync gate: emit, then await and return the answer as the
      # tool_result. The await returning means THIS tool_result carries the
      # answer, so the digest of THIS set -- read off the promise, never off
      # `@last_question` -- is what the delivery commit cites.
      #
      # An {Unanswered} never reaches that harvest: nothing was answered, so no
      # committed :turn may cite this question as one the human retired. The
      # record {#recorded_reply} writes is what says what became of the Q.
      def perform(input, _invocation)
        pending = ask(Announcement.new(requested_set(input)))
        settled(awaited(pending), pending)
      end

      private

      # What became of one answer, whichever park it arrived at. An
      # {Unanswered} is the one thing that is not an answer at all, so it is
      # asked about before anything measures it; anything else that overran is
      # put back to the human rather than refused.
      def settled(answer, pending)
        return Tool::Result.error(Unanswered::REFUSAL) if answer.is_a?(Unanswered)

        over = Ceiling.overrun(answer)
        return delivered(answer, pending) if over.nil?

        reconsidered(over, awaited(reopened(over, pending)), pending)
      end

      # The human decided. Confirming sends the words they already wrote --
      # {Tool::Bounds::Overrun#content}, the frozen whole copy, never a
      # preview. Anything else is a REPLACEMENT answer and is measured like any
      # other, so a human who retypes something just as long is asked again
      # rather than sneaking past a bound they were just shown. Each pass costs
      # one human decision, so nothing here loops on its own.
      def reconsidered(over, answer, pending)
        Ceiling.confirmed?(answer) ? delivered(over.content, pending) : settled(answer, pending)
      end

      # The digest the delivery commit cites, recorded at the ONE exit that
      # carries an answer into the conversation -- so a question handed back
      # three times is still retired exactly once. Recorded AFTER the result is
      # built, so an answer the result refuses (`Tool::Result.ok` takes a String
      # and nothing else) is not booked as delivered on its way out.
      def delivered(answer, pending)
        Tool::Result.ok(answer).tap { @answered.push(pending.digest) }
      end

      # The SAME set, put back to the human. Deliberately not a second {#ask}:
      # an ask writes a second Q event, and {Parent#escalate} relays that one
      # too, so one question would leave two human-addressed records and list
      # two inbox rows. Re-opening on the digest already in the record leaves
      # the record saying what is true -- one question, asked once, answered
      # more than once -- and the arrival that re-prompts the human carries
      # that same digest, so the row they answer is the row they were already
      # holding.
      #
      # {#awaited}'s `ensure` has already abandoned the first park, which is
      # what lets {Outstanding#open} claim the set again, and it gives the
      # second park the same treatment: a stop raised while parked here
      # withdraws the set rather than leaving a question outstanding forever.
      #
      # Opened BEFORE the arrival goes out, the ordering {Notifying#ask} keeps
      # for the same reason: a human who could answer faster than the set was
      # re-opened would be refused as naming nothing -- and through
      # {Outstanding#opened}, so an arrival that RAISES does not leave the set
      # claimed with no park to release it.
      def reopened(over, pending)
        @outstanding.opened(pending.digest) { @notify.call(Ceiling.handback(over)) }
      end

      # A stop raised while parked here -- Ctrl-C, or a caller's timeout --
      # means nobody will ever deliver this answer, so the set stops being
      # outstanding and the asker can ask again. The Q :message stays UNCONSUMED
      # in the record, because a cancelled question is genuinely unanswered.
      def awaited(pending)
        pending.await
      ensure
        @outstanding.abandon(pending)
      end

      # The ONE branch this class draws between an answer and the absence of
      # one. `is_a?` rather than a duck test, for {#announcement_for}'s reason.
      #
      # The Q event is written before the park, so a question with no possible
      # answer is already in the record by the time EOF is seen -- and its
      # disposition is a MATCHING record rather than a silence. Chained to the Q
      # exactly as an A is, so a reader walks from the question to what became
      # of it, but attributed to {Unanswered::NOBODY} and carrying no `"answer"`
      # key, so a question nobody could answer reads differently from one a
      # human answered emptily.
      #
      # `from: @last_question.to` rather than {HUMAN} or {#to}: {#emit_question}
      # may have RELAYED the question past `@to`, and `pending`'s digest --
      # what this A cites and what {Outstanding} named the set by -- is
      # ALWAYS the outermost hop's, so the answer is attributed to whoever
      # that hop was actually addressed to. Q and A close the loop as one
      # identity instead of two straddling the same exchange, whatever the
      # relay's length.
      def recorded_reply(answer, pending)
        return unanswered_record(answer, pending) if answer.is_a?(Unanswered)

        @last_answer = written(pending, from: @last_question.to, body: { "answer" => answer })
      end

      # Its own method rather than a ternary arm, so the two records read side
      # by side: same chain, same recipient, different attribution and key.
      def unanswered_record(answer, pending)
        @last_unanswered = written(pending, from: Unanswered::NOBODY, body: answer.recorded)
      end

      # Addressed back to the asker, chained to the Q the set is named by.
      def written(pending, from:, body:)
        parent = parent_timeline
        write_message(parent, from:, to: identity(parent), body:, causal_parents: [pending.digest])
      end

      # Q, relayed past {#to} for every hop {Parent#escalate} carries, and the
      # digest {Outstanding} names its set by -- always the OUTERMOST hop's,
      # because that is the one a queue announces and a human answers.
      #
      # `settled` rather than {#parent_timeline}: the head THIS OWN Q cites has
      # to be in the record before the citation is written, and for a child's
      # asker that is not free -- see {Parent}. Nothing past this cites a live
      # head again -- {Parent#escalate} chains message to message instead
      # (a :message is journaled the instant {#write_message} returns, the
      # shared observer seeing it synchronously exactly as {Lineage#message}
      # relies on), which is what lets it relay without the parent a hop
      # addresses ever being touched, let alone required to be free to act.
      # The SAME body rides every hop unchanged, {ASKED_BY} included, so
      # whoever finally reads the outermost one learns which role originally
      # asked, not who relayed it -- mechanical on purpose, since nothing here
      # decides WHETHER to escalate, only where the chain already goes next.
      # HAZARD, dormant rather than closed here: `@last_question.from` used to
      # be this asker's own identity and is now, once relayed, the LAST
      # relayer's -- ASKED_BY still carries the true asker's name, but a
      # caller that falls back to the bare event when ASKED_BY is blank
      # ({HumanReplies::InboxItem.asked}, {CLI::Wiring::Askers#desktop_name})
      # would present the relayer rather than who actually asked. Unreachable
      # today, since both production enrolment sites always pass a name --
      # flagged rather than guarded, because closing it means deciding what
      # THOSE callers should show instead, which is their call to make.
      def emit_question(announcement)
        parent = @parent.settled
        own_question = write_message(parent, from: identity(parent), to: @to,
                                             body: emitted_body(announcement),
                                             causal_parents: [parent.head_digest].compact)
        @last_question = @parent.escalate(own_question) { |**hop| write_message(parent, **hop) }
        @last_question.digest
      end

      # What `from_body` refuses -- a duplicate id, an unclosed fence, a set
      # past its byte bound -- is an INPUT defect, so it is re-raised as one and
      # reaches the model carrying this tool's name.
      #
      # `to_h.compact` drops the members the model left out, so Question's own
      # permissive defaults apply rather than a nil reaching a rule that would
      # refuse it.
      def requested_set(input)
        return free_text_set(input.question) if input.questions.blank?

        Question::Set.from_body("questions" => input.questions.map { |question| question.to_h.compact })
      rescue ArgumentError => e
        invalid!(e.message)
      end

      # `is_a?` rather than `respond_to?(:set)`, the one place this file does
      # not duck-type: {Announcement} is this class's own currency, and
      # `+str`/`String#encode` return the class with its ivars dropped -- a husk
      # that answers `respond_to?` and holds nil. The type test is what makes
      # that fail at the door instead of inside {Question::Set}.
      def announcement_for(question)
        bare_set!(question)
        question.is_a?(Announcement) ? question : Announcement.new(free_text_set(question))
      end

      # Named, because the mistake it catches would otherwise surface as "a
      # question body must be a String or a Symbol", naming neither the fix nor
      # the reason there is one.
      def bare_set!(question)
        return unless question.is_a?(Question::Set)

        raise ArgumentError, "wrap a question set as #{Announcement}.new(set): the value #ask is handed is " \
                             "also the value the arrival seam announces, and that must be a String"
      end

      # The free-text arm is a real arm of the design rather than a degenerate
      # set (see {Question#free_text?}).
      def free_text_set(question)
        Question::Set.new(questions: [Question.new(id: FREE_TEXT_ID, body: question)])
      end

      # {Question::Set#to_body} hands back a fresh copy, so merging here
      # reaches nothing the frozen set holds, and `from_body` reads only the
      # keys it owns, so a richer body still rebuilds exactly the set that was
      # asked. This is the event, not the schema -- the tools block is untouched.
      def emitted_body(announcement)
        body = announcement.set.to_body.merge("question" => announcement.summary)
        Blankness.blank?(@agent) ? body : body.merge(ASKED_BY => @agent)
      end

      # Causal-only -- no `render_parent` -- so it never enters a render chain.
      def write_message(parent, from:, to:, body:, causal_parents:)
        @chain_writer.put(parent, kind: :message, from:, to:, causal_parents:, body:)
      end

      # A chain is named by its root event digest, so the asker is addressable
      # without new id machinery -- Subagent's Lineage derives it the same way.
      def identity(timeline) = Event::ChainWriter.correlation_of(timeline)

      # The parent Timeline, live -- read through the {Parent} handle every
      # shape a caller passes is normalized into.
      def parent_timeline = @parent.timeline
    end
  end
end

# Both reopen AskHuman -- Notifying subclasses it -- so they load after the
# class body.
require_relative "ask_human/directory"
require_relative "ask_human/notifying"
require_relative "ask_human/unattended"
