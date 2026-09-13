# frozen_string_literal: true

module Lain
  module Approval
    # The escalation ladder: "middleware wrapping the human", in this repo's own
    # idiom. A ladder is a VALUE -- an ordered list of named rungs -- and every
    # verdict it reaches is journaled attributed to the rung that reached it.
    #
    #   Shell::Verdict / RuleChain  ->  surfaces (AutoSurface, the human)  ->  timeout
    #        deterministic                        asking                     fail-closed
    #
    # It presents to {Effect::Handler::Gate} as Gate's existing two-valued policy
    # duck, `#call(effect, context) -> Boolean`, so Gate is untouched. Three
    # values live INSIDE -- allow, deny, and the abstention that is the absence
    # of either -- and collapse at the seam, exactly as {Approval::Queue} keeps
    # `:approve`/`:deny` internally and collapses them at `queue.rb:128`.
    #
    # == An abstaining rung does not change the outcome
    #
    # The composability property, and what lets rungs be reordered among the
    # abstaining ones without surprise. No rung is ever asked to invent an
    # answer to stay total, because the BOTTOM of the ladder already is: the
    # surfaces rung parks on {Approval::Queue}, whose window expires into a
    # denial, and a ladder that runs out of rungs refuses. An unanswered gate
    # refuses; it never wedges.
    #
    # == A fault is NOT an abstention, and must not be launderable into one
    #
    # An allow reached after ANY rung faulted is suppressed, and the denial is
    # attributed to the rung that faulted rather than to the rung that was about
    # to say yes -- {RuleChain}'s poisoning, applied one level up.
    #
    # == ...and the poison STOPS at the asking rung, if a human answered
    #
    # Poisoning is sound between RULES because a later rule is the same kind of
    # authority as the one that faulted. A human is not a later rule: they are
    # the authority this ladder exists to escalate TO, and `#settle` is lazy, so
    # a fault can only have come from a rung consulted BEFORE them. The only
    # shape a blanket suppression fires on is therefore "something broke, we
    # escalated BECAUSE it broke, a person looked at the call and said yes, and
    # we threw their answer away".
    #
    # That is not fail-closed, it is a wedge. A broken rule is a persistent
    # config fault, so every call in the session denies, each rendered as the
    # same `"approval denied for tool ..."`, and the operator's only escape is a
    # MORE permissive posture. It also corrupts the record: an
    # `approval_decision` reading `approve` beside an `escalation` reading
    # `deny`, for one call, with nothing joining them.
    #
    # So a HUMAN surface's allow is honoured and journaled `verdict: allow,
    # faulted: true`, naming the rung that broke -- enough for the bench to
    # exclude those runs without inventing a denial no authority ever made. An
    # {AutoSurface} allow keeps being suppressed: an LLM adjudicator IS a later
    # automatic rung wearing a human's clothes. {Ruling#authority} tells them
    # apart.
    #
    # == Every rung's ruling is evidence
    #
    # Each consulted rung's Ruling is journaled, not merely the settled one:
    # this is the only place {Shell::Verdict}'s answer has ever been written
    # down, and a verdict nobody records is a layer nobody can measure.
    class Escalation
      # A name, not a nil, so journal readers never guard.
      LADDER = "ladder"

      NOTHING_ANSWERED = "no rung answered, and an unanswered gate refuses"
      LAUNDERED = "an allow was suppressed because a rung faulted"
      HONOURED = "a human authorized this despite a fault at"
      RUNG_BROKE = "the rung itself failed, which is not an answer"
      TYPE = "escalation"

      # What one rung said, and everything a journal needs to attribute it.
      # Deeply frozen -- strings interned, `fault` coerced to a strict Boolean --
      # so `Ractor.shareable?` holds and the record is safe to share.
      Ruling = Data.define(:verdict, :rung, :reason, :fault, :authority)

      class Ruling
        # Reopened rather than written in the `Data.define` block: a constant
        # declared there is lexically scoped to the enclosing module, not to the
        # Data class.

        # Abstention is a MEMBER here rather than the absence of a Ruling, which
        # is where this file departs from {Rule}: a rule abstains by answering
        # nothing, a rung abstains as a REPORT, because the ladder journals what
        # each rung said and "said nothing" is something a reader needs to see.
        VERDICTS = %i[allow deny abstain].freeze

        # NOT a synonym for the rung: the asking rung produces both, depending
        # on which surface won the race for the pending, and this is the whole
        # reason an {AutoSurface}'s allow is suppressed over a fault where a
        # human's is honoured.
        AUTHORITIES = %i[automatic human].freeze

        def self.allow(rung:, because:, **rest) = new(verdict: :allow, rung:, reason: because, **rest)
        def self.deny(rung:, because:, **rest) = new(verdict: :deny, rung:, reason: because, **rest)
        def self.abstain(rung:, because:, **rest) = new(verdict: :abstain, rung:, reason: because, **rest)

        # An abstention that is NOT a plain one: something broke, so no
        # automatic allow above it may be promoted.
        def self.fault(rung:, because:) = new(verdict: :abstain, rung:, reason: because, fault: true)

        def initialize(verdict:, rung:, reason:, fault: false, authority: :automatic)
          unless VERDICTS.include?(verdict)
            raise Error, "unknown verdict #{verdict.inspect}; expected one of #{VERDICTS.inspect}"
          end
          unless AUTHORITIES.include?(authority)
            raise Error, "unknown authority #{authority.inspect}; expected one of #{AUTHORITIES.inspect}"
          end

          super(verdict:, rung: -rung.to_s, reason: -reason.to_s, fault: fault == true, authority:)
        end

        def allow? = verdict == :allow
        def deny? = verdict == :deny

        # Asked, never inferred from `!allow?`, which is true of a denial AND
        # of an abstention -- and this layer's premise is that those differ.
        def abstain? = verdict == :abstain
        def fault? = fault
        def human? = authority == :human

        def record
          { "verdict" => verdict.to_s, "rung" => rung, "reason" => reason,
            "faulted" => fault, "authority" => authority.to_s }.freeze
        end
      end

      # The deterministic rungs first, the asking rung last.
      #
      # BOTH deterministic rungs are inert as this repo wires them TODAY -- a
      # fact about the wiring, not the mechanism. `rules:` is empty because
      # remembered answers need a project root the switchboard does not hold,
      # and `triage:` defaults to a verdict permitting every program over a
      # classifier protecting no path. So both of {Triage}'s deny arms, the only
      # things here that refuse on their own, wait on a call site. Both are
      # seams, so wiring either is a call-site change rather than an edit here.
      def self.for(queue:, tools:, journal:, rules: [], triage: Triage.new)
        new([triage, Rules.new(rules:, tools:, faults: Faults.new(journal)), Surfaces.new(queue)], journal:)
      end

      include Enumerable

      # @param rungs [Enumerable<#call, #name>] consulted in order
      # @param journal [#record] where every ruling lands as evidence
      def initialize(rungs = [], journal:)
        @rungs = rungs.to_a.freeze
        # Every rung names itself HERE, while the ladder is BUILT, and the
        # answer is KEPT: asking a rung for its name inside the rescue clause,
        # after it has just proved it can raise, is how a second raise escapes
        # and takes the ladder down.
        @consulted = @rungs.map { |rung| [rung, -rung.name.to_s].freeze }.freeze
        @journal = journal
        freeze
      end

      def each(&block)
        return enum_for(:each) unless block

        @rungs.each(&block)
      end

      # {Effect::Handler::Gate}'s policy seam.
      #
      # @param effect [Effect::ToolCall] the call to judge, already unwrapped
      # @param context [Object, nil] whatever {Effect::Handler} threads through
      #   unexamined; forwarded to every rung's own `#call` untouched
      # @return [Boolean] whether the call may be performed
      def call(effect, context) = settle(effect, context).allow?

      private

      def settle(effect, context)
        # A local rather than instance state: #initialize freezes the ladder, so
        # a `@faulted` would be a FrozenError on the first broken rung -- and it
        # would be shared between concurrently gated fibers besides.
        faulted = nil
        # The FIRST fault is what suppresses, remembered rather than counted: a
        # suppression has to name the rung that broke.
        remember = ->(ruling) { faulted ||= ruling }
        # Lazy, so rungs past the deciding one are never consulted: parking a
        # human on a call an earlier rung already settled is what this ladder
        # exists to avoid.
        decided = @consulted.lazy
                            .filter_map { |rung, name| decisive(consult(rung, name, effect, context), &remember) }
                            .first
        answer(decided, faulted, effect)
      end

      def consult(rung, name, effect, context) = record(ask(rung, name, effect, context), effect)

      def ask(rung, name, effect, context)
        ruling = rung.call(effect, context)
        return ruling if ruling.is_a?(Ruling)

        # Raised INSIDE the consult, so a rung answering a non-Ruling becomes a
        # fault like any other broken rung rather than a NoMethodError far from
        # its cause.
        raise Error, "#{name} answered #{ruling.class}; a rung rules or abstains"
      rescue StandardError => e
        # A rung's own failure -- a failed spawn, an unreadable config -- is a
        # fault and never an approval. Deny-when-unsure binds every rung.
        Ruling.fault(rung: name, because: "#{RUNG_BROKE}: #{e.class}: #{e.message}")
      end

      def decisive(ruling)
        yield ruling if ruling.fault?

        ruling.abstain? ? nil : ruling
      end

      # An allow reached over a fault is suppressed -- UNLESS a human made it,
      # in which case it stands and is re-recorded saying so. Everything else
      # passes straight through.
      def answer(decided, faulted, effect)
        return record(synthesized(nil, faulted), effect) if decided.nil?
        return decided unless faulted && decided.allow?
        return record(honoured(decided, faulted), effect) if decided.human?

        record(synthesized(decided, faulted), effect)
      end

      # The three rulings nobody made as such: a human's allow restated so the
      # record carries the fault it was given despite, the suppression of an
      # automatic allow attributed to the faulting rung, and the fail-closed
      # bottom.
      def honoured(decided, faulted)
        decided.with(fault: true, reason: "#{decided.reason} -- #{HONOURED} #{faulted.rung}: #{faulted.reason}")
      end

      # The rung stays LADDER when nothing answered: a reader tallying denials
      # by rung must not be told a rung that abstained refused. The fault is
      # still named, because a fail-closed denial that omits the reason a rung
      # had nothing to say makes the record less useful than it can be.
      def synthesized(decided, faulted)
        return Ruling.deny(rung: faulted.rung, because: "#{LAUNDERED}: #{faulted.reason}") if decided
        return Ruling.deny(rung: LADDER, because: NOTHING_ANSWERED) unless faulted

        Ruling.deny(rung: LADDER, fault: true,
                    because: "#{NOTHING_ANSWERED} -- and #{faulted.rung} faulted: #{faulted.reason}")
      end

      # Evidence about a turn must never COST the turn: this ladder sits ABOVE
      # {Effect::Handler::Live}, so nothing below is left to turn an exception
      # into a {Tool::Result}, and a closed Journal would hand the user a dead
      # turn instead of the denial an unanswerable approval is owed.
      #
      # `tool_use_id` rather than the tool name alone: parallel tool calls put
      # several gated calls of the SAME tool in flight, so the name cannot
      # attribute a ruling -- or a fault -- to the call it belongs to.
      def record(ruling, effect)
        @journal.record({ "type" => TYPE, "tool" => effect.name,
                          "tool_use_id" => effect.tool_use_id }.merge(ruling.record))
        ruling
      rescue StandardError
        ruling
      end

      # Where a broken RULE is reported. Under {RuleChain}'s Null default the
      # chain still refuses to promote an allow past a fault, but nobody is ever
      # told the rule is broken. A live wiring passes this.
      class Faults
        TYPE = "escalation_fault"

        def initialize(journal)
          @journal = journal
          freeze
        end

        # `tool_use_id` is the CALL's, not the fault's: a {RuleChain::Fault} is
        # built from a {Rule::Call}, which carries no identity for the
        # invocation. Without it a reader cannot join a fault to the ruling it
        # poisoned once parallel tools put two bash calls in flight.
        def call(fault, tool_use_id: nil)
          @journal.record({ "type" => TYPE, "tool_use_id" => tool_use_id }
                            .merge(fault.to_h.transform_keys(&:to_s)))
        end
      end

      # The deterministic rung over a {RuleChain}: the remembered answers and any
      # other predicate a session declares.
      class Rules
        NAME = "rules"
        NO_OPINION = "no rule had an opinion"
        NO_SUBJECT = "no rule could be shown this call"
        BROKEN = "the rung could not build a subject to judge"

        # @param rules [Enumerable<Approval::Rule>] consulted in order
        # @param tools [#fetch] the LIVE capability set, so the tier a rule reads
        #   is read off the exact tool the executor would dispatch -- and so is
        #   {Rule::Call#term}, which that tool derives from its own
        #   {Shell::Verdict} rather than this rung threading one down
        # @param faults [#call] where a broken rule is reported; REQUIRED, with
        #   no Null default, because a ladder wired with the Null is silently
        #   lenient in exactly the way {RuleChain}'s poisoning exists to prevent
        def initialize(rules:, tools:, faults:)
          @rules = rules.to_a.freeze
          @tools = tools
          @faults = faults
          freeze
        end

        def name = NAME

        # Built PER CALL only because its fault recorder is stamped with THIS
        # call's `tool_use_id`. The poisoning is the chain's own, so nothing
        # here tallies the fault stream to tell an abstention from a
        # suppression.
        def call(effect, _context)
          ruling(RuleChain.new(@rules, faults: recorder(effect)).decide(subject(effect)))
        rescue Rule::Call::Undeclared, Tool::InvalidInput, Toolset::UnknownTool => e
          # Structural, expected, and not a bug: a tool with no declaration, an
          # input the tool itself will refuse, a name this session does not hold.
          Ruling.abstain(rung: NAME, because: "#{NO_SUBJECT}: #{e.class}: #{e.message}")
        rescue StandardError => e
          # MEASURED: `Rule::Call.for` is not total. Invalid UTF-8 in a
          # required String raises ArgumentError from ActiveSupport's
          # `String#blank?`, NOT Tool::InvalidInput -- and a rescue list is no
          # substitute for a total classifier, since a NUL byte and a UTF-16LE
          # value BUILD cleanly here and detonate later inside a rule.
          Ruling.fault(rung: NAME, because: "#{BROKEN}: #{e.class}: #{e.message}")
        end

        private

        def subject(effect) = Rule::Call.for(tool: @tools.fetch(effect.name), input: effect.input)

        # Stateless and per call, so two gated fibers never share one: it
        # carries this call's identity onto whatever the chain reports.
        def recorder(effect) = ->(fault) { @faults.call(fault, tool_use_id: effect.tool_use_id) }

        # A deny after a fault still denies and is still attributed --
        # poisoning suppresses the ALLOW side and only that -- but the record
        # says a fault happened, or a reader sees a clean denial that was not.
        def ruling(answer)
          faulted = answer.is_a?(RuleChain::Poisoned)
          return Ruling.deny(rung: NAME, because: attributed(answer), fault: faulted) if answer&.deny?
          return Ruling.fault(rung: NAME, because: broke(answer.fault)) if faulted
          return Ruling.abstain(rung: NAME, because: NO_OPINION) if answer.nil?

          Ruling.allow(rung: NAME, because: attributed(answer))
        end

        # A {RuleChain::Poisoned} carries the surviving decision; an unpoisoned
        # answer IS one.
        def attributed(answer)
          decision = answer.is_a?(RuleChain::Poisoned) ? answer.decision : answer
          "#{decision.rule}: #{decision.reason}"
        end

        def broke(fault) = "#{fault.rule} raised #{fault.error}: #{fault.message}"
      end

      # The deterministic rung over {Shell::Verdict}, which asks *"is this
      # command syntactically literal and fully understood?"* and never *"is it
      # safe?"*.
      #
      # Only its DENY acts. A verdict deny means the session's capability set
      # excludes a program the command names, and until this rung existed
      # nothing enforced it: `Tools::Bash` routes a non-allow straight to
      # `sh -c`, so a denied command ran anyway, silently.
      #
      # An ALLOW abstains, and that is the important half. `rm -rf /home/joel`
      # is literal, fully understood and covered to the byte; promoting that to
      # an approval would auto-run it. What the allow DOES buy is one layer
      # down -- `Tools::Bash` runs the reconstructed argv rather than the string
      # once approved -- which is a property of the execution, not a licence to
      # skip the human.
      #
      # == ...with one refusal read off the allowed argv
      #
      # An allow hands over the PARSED WORDS, the only place in this ladder
      # where a path a command names can be read without guessing. So the allow
      # branch asks a {Sensitivity} about each word and refuses when one is a
      # path nothing may read.
      #
      # Three properties hold it in scope, each with a spec:
      #
      # * *The argv, never the command string.* A signal read off one flat field
      #   is confident about text it has not understood, so a command the
      #   verdict abstained on is not scanned at all. `cat '~/.ssh/id_rsa'`
      #   abstains and reaches a human; it does not deny on a substring.
      # * *Denied only, and only when written as a path.* A GATED path stays an
      #   abstention -- an abstention already reaches a human, and a second
      #   gating notion here would decide nothing the queue does not. A denied
      #   name written as a BARE word is named in the record and nothing more;
      #   {PATHLIKE} carries that ruling and its measurement.
      # * *Inert until wired.* No home is known where a ladder is built, so the
      #   classifier is injected and defaults to {AnyPath}.
      class Triage
        NAME = "triage"

        # Named rather than sniffed: a tool that grows a `command` field should
        # have to be added here deliberately.
        COMMAND_TOOLS = %w[bash].freeze
        FIELD = "command"
        # `Tools::Bash` runs every command under it, so it is where a relative
        # word in the argv lands.
        CWD_FIELD = "cwd"

        NOT_JUDGED = "this rung judges only the tools whose input is a command string"
        NOT_A_COMMAND = "the call carries no command string to judge"
        NOT_SAFE = "an allow claims the command is literal and fully understood, never that it is safe"
        PROTECTED = "the command's argv names a path no approval may lift"
        BARE = "a word matches a protected name but is not written as a path, so this rung only says so"

        # A word is evidence about a PATH when it is written as one: it carries
        # a separator, or it names a home. MEASURED, and the reason the refusal
        # is this narrow: six denied rules match a bare BASENAME, four
        # (`.netrc`, `.gnupg`, `.password-store`, `*.kdbx`) from any cwd and two
        # (`Cookies`, `key4.db`) anywhere under `$HOME`, which is where
        # checkouts live. Denying on a bare word therefore stops
        # `grep -n Cookies lib/lain/sensitivity.rb` in this very repository, and
        # NOTHING lifts it -- not a policy, not `/mode auto`, not `ApproveAll`,
        # and not `[sensitivity] exempt`, which subtracts from the gated half
        # only.
        #
        # The trade is deliberate and small. A denied path named as a bare word
        # DROPS FROM DENY TO ABSTAIN: still named in the record, the call still
        # reaches a human because {Triage} downgrades every allow anyway,
        # `Tools::Bash` is gated regardless, and the read boundary proper
        # ({Sensitivity::Policy}) classifies the RESOLVED path when a tool opens
        # it. This rung is a bonus refusal on unambiguous evidence, and a word
        # with neither a separator nor a tilde is not that.
        #
        # The tilde arm earns its place only barely. It needs the `verdict:`
        # seam in every case, since today's {Shell::Verdict} abstains on any
        # word matching its `EXPANDING`. Past that, a SLASHLESS tilde word is
        # rewritten by {Sensitivity} to the home directory ITSELF, so the arm
        # fires when that directory is denied -- either by a `[sensitivity]
        # denied` rule naming the home's basename, or by a home that is a denied
        # path in its own right (`/home/.gnupg`, `/home/x/.netrc`; both
        # verified). It stays because the two objects agree deliberately about
        # what a leading `~` means, and dropping it would silently disagree.
        PATHLIKE = %r{/|\A~}

        # A long command can name many, and a Journal line wants the shape
        # rather than the census. Bounds the RENDERING only -- every word is
        # still classified, or a refusal could hide behind eight harmless ones.
        MAX_NAMED = 8

        # The classifier of a session that protects nothing: an inert default
        # answering the same messages a real one does, so no branch below guards
        # on nil. Its own factory, because there is nothing to build.
        class AnyPath
          ORDINARY = Sensitivity::Verdict.new(level: :ordinary, reason: :none)

          def call(_cwd) = self
          def classify(_path) = ORDINARY
        end

        # `verdict:` defaults at CALL time, not in a constant: `lain.rb` loads
        # `lain/approval` before `lain/shell`, so a `Shell::Verdict.new` in this
        # class body is a hard NameError at load. {Sensitivity} loads BEFORE
        # approval, so {AnyPath} may be built here.
        #
        # @param verdict [#call] `String -> Shell::Verdict::Decision`
        # @param tools [Enumerable<String>] the tools whose input is a command
        # @param field [String] the input field carrying that command
        # @param sensitivity [#call] `cwd -> #classify`, a {Sensitivity} FACTORY
        #   rather than one classifier: a bash call names its own working
        #   directory, so a classifier built once at wiring time would anchor a
        #   relative word under whatever directory the agent started in, and
        #   could refuse a project file for a name it shares with a browser
        #   profile -- which no policy can then lift. The cwd is handed over AS
        #   THE CALL WROTE IT, because only the wiring knows what it resolves
        #   against.
        #
        #   IT MUST BE TOTAL, and that is a SECURITY property rather than
        #   tidiness. `cwd` is MODEL-CONTROLLED and `Sensitivity.new` refuses a
        #   cwd that is not absolute and readable, so a factory that lets those
        #   raise hands the model a one-argument disarm: the raise becomes a
        #   {RUNG_BROKE} fault, the fault turns this deny into the abstention it
        #   exists to replace, and a human -- whose allow is honoured over a
        #   fault, by design -- approves the read. A factory resolves the cwd
        #   itself and falls back to a classifier refusing NOTHING when it
        #   cannot, because a wiring error is not evidence about a path.
        def initialize(verdict: Shell::Verdict.new, tools: COMMAND_TOOLS, field: FIELD, sensitivity: AnyPath.new)
          @verdict = verdict
          @tools = tools.to_a.map { |name| -name.to_s }.freeze
          @field = -field.to_s
          @sensitivity = sensitivity
          freeze
        end

        def name = NAME

        def call(effect, _context)
          return Ruling.abstain(rung: NAME, because: NOT_JUDGED) unless @tools.include?(effect.name)

          command = effect.input[@field]
          return Ruling.abstain(rung: NAME, because: NOT_A_COMMAND) unless command.is_a?(String)

          judge(@verdict.call(command), effect)
        end

        private

        def judge(decision, effect)
          return Ruling.deny(rung: NAME, because: because(decision)) if decision.deny?
          return literal(decision, effect) if decision.allow?

          Ruling.abstain(rung: NAME, because: because(decision))
        end

        # The only branch with an argv to read: `term` is
        # {Shell::Verdict::NO_TERM} on a deny and on every abstention, so a path
        # check anywhere else would interrogate a Null Object about a path
        # nobody wrote.
        def literal(decision, effect)
          written, bare = refused(decision.term, effect.input[CWD_FIELD]).partition { |word, _| word.match?(PATHLIKE) }
          return Ruling.deny(rung: NAME, because: because(decision, named(PROTECTED, written))) unless written.empty?
          return Ruling.abstain(rung: NAME, because: because(decision, named(BARE, bare))) unless bare.empty?

          Ruling.abstain(rung: NAME, because: because(decision, NOT_SAFE))
        end

        # EVERY word of every stage, argv0 included. {PATHLIKE} is applied
        # AFTER classification rather than before, so a bare match can still be
        # named in the record.
        def refused(term, cwd)
          classifier = @sensitivity.call(cwd)
          term.flatten.uniq.filter_map do |word|
            verdict = classifier.classify(word)
            [word, verdict.explanation] if verdict.denied?
          end
        end

        def named(label, refusals)
          "#{label}: #{refusals.first(MAX_NAMED).map { |word, why| "#{word.inspect} is #{why}" }.join("; ")}"
        end

        # {Shell::Verdict::CLAIM} rides on every record, so nothing a Journal
        # reader finds here can be read as a claim about safety.
        def because(decision, note = nil)
          ["shell verdict #{decision.name}", note, decision.reason, Shell::Verdict::CLAIM].compact.join(" -- ")
        end
      end

      # The asking rung: {Approval::Queue}, where a call parks for whatever
      # surfaces are watching, and where the window expiring is itself a denial
      # signed by the clock. Total by construction, which is what makes it the
      # bottom of the ladder.
      #
      # The queue journals its own decision with the SURFACE that made it, so
      # this rung's record says only that the surfaces answered.
      class Surfaces
        NAME = "surfaces"

        # THE GENERATING RULE: a surface belongs here when no person is behind
        # it. Every surface that decides a {Queue::Pending} today is accounted
        # for; the human ones are `Frontend::ApprovalPolicy::SURFACE` and
        # `Frontend::Neovim::ApprovalView::SURFACE`.
        #
        # An unknown name therefore counts as HUMAN. The two failure modes are
        # structurally symmetric, so what decides it is WHICH WAY the error
        # runs. Reading an unlisted surface as automatic would suppress its
        # allow over a fault -- the wedge this class's comment refuses, reopened
        # at the frontend boundary, where an author has least reason to suspect
        # that the NAME of an approval surface is security-relevant. Reading it
        # as human costs the other direction, and that one fails visibly in a
        # review of a file whose whole subject is adjudication.
        #
        # The deeper defect is that authority is INFERRED from a surface name
        # one layer down, when the decider always knew what it was -- which is
        # why {Ruling} needed an `authority` member at all. The fix is
        # `Pending#decide(verdict, surface:, authority:)` with NO default, so a
        # surface that forgot to declare is a loud ArgumentError at one of five
        # call sites rather than a silent reclassification here.
        #
        # `secret_oracle` is what that predicted: a 4B LOCAL MODEL releasing
        # files the detector flagged as holding credentials, and unlisted it
        # counted as HUMAN -- so the one surface built to release secrets was
        # the one this ladder trusted most, its allow surviving a fault that
        # `auto_approver`'s identical judgement does not. Listed here, it is
        # `:automatic` like every other machine.
        AUTOMATIC = [AutoSurface::SURFACE, SecretSurface::SURFACE,
                     Queue::TIMEOUT_SURFACE, Queue::ABANDONED_SURFACE].freeze

        APPROVED = "a surface approved this call"
        REFUSED = "a surface refused this call, or the window closed and the fail-closed doctrine did"

        # The SAME object `/approve` drains, readable here so "the gate asks
        # through the session's one queue" stays an identity a caller can check
        # rather than a shape it must trust.
        attr_reader :queue

        def initialize(queue, automatic: AUTOMATIC)
          @queue = queue
          @automatic = automatic.to_a.map { |surface| -surface.to_s }.freeze
          freeze
        end

        def name = NAME

        # {Queue#adjudicate} rather than `#call`, because a Boolean cannot carry
        # WHO answered -- the one thing the ladder above needs in order not to
        # throw a person's approval away.
        def call(effect, context)
          pending = @queue.adjudicate(effect, context)
          authority = @automatic.include?(pending.surface) ? :automatic : :human
          return Ruling.allow(rung: NAME, because: "#{APPROVED} (#{pending.surface})", authority:) if pending.approved?

          Ruling.deny(rung: NAME, because: "#{REFUSED} (#{pending.surface})", authority:)
        end
      end
    end
  end
end
