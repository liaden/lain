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
    # That is the composability property, and it is what lets rungs be reordered
    # among the abstaining ones without surprise: a rung with nothing to say
    # answers nothing, and the ladder consults the next one. A rung is never
    # asked to invent an answer to stay total, because the bottom of the ladder
    # is already total -- the surfaces rung parks on {Approval::Queue}, whose
    # window expires into a denial -- and because a ladder that runs out of
    # rungs refuses. An unanswered gate refuses; it never wedges.
    #
    # == A fault is NOT an abstention, and must not be launderable into one
    #
    # {RuleChain} poisons the allow side: a rule that raises is recorded as a
    # {RuleChain::Fault} and a LATER allow is suppressed, so the chain answers a
    # {RuleChain::Poisoned} rather than a decision. {Rules} passes that through
    # as a Ruling that SAYS a fault happened, and the ladder applies the same
    # poisoning one level up -- an allow reached after any rung faulted is
    # suppressed, and the denial is attributed to the rung that faulted rather
    # than to the rung that was about to say yes.
    #
    # == ...and the poison STOPS at the asking rung, if a human answered
    #
    # This is the one place the analogy to {RuleChain} breaks, and it breaks for
    # a reason worth stating. Poisoning is sound between RULES because a later
    # rule is the same kind of authority as the one that faulted: suppressing its
    # allow loses nothing a human was ever asked about. A human is not a later
    # rule. They are the authority this entire ladder exists to escalate TO, and
    # `#settle` is lazy, so a fault can only have come from a rung consulted
    # BEFORE them -- which means the only shape a blanket suppression fires on is
    # "something broke, we escalated BECAUSE it broke, a person looked at the
    # call and said yes, and we threw their answer away".
    #
    # That is not fail-closed, it is a wedge. A broken rule is a persistent
    # config fault, so every call in the session denies, {Effect::Handler::Gate}
    # renders each one as the same `"approval denied for tool ..."` (`gate.rb:70`)
    # and the operator's only escape is a MORE permissive posture. It also
    # corrupts the record: the Journal would hold an `approval_decision` reading
    # `approve` beside an `escalation` reading `deny`, for one call, with nothing
    # joining them.
    #
    # So a HUMAN surface's allow is honoured, and journaled `verdict: allow,
    # faulted: true`, naming the rung that broke -- which gives the bench
    # everything it needs to exclude those runs without inventing a denial no
    # authority ever made. An {AutoSurface} allow keeps being suppressed: an LLM
    # adjudicator IS a later automatic rung wearing a human's clothes, and that
    # half of the poison is earned. {Ruling#authority} is what tells them apart.
    #
    # == Every rung's ruling is evidence
    #
    # Each consulted rung's Ruling is journaled, not merely the settled one. On a
    # study bench "which rungs were consulted and what each said" is the record;
    # in particular it is the only place {Shell::Verdict}'s answer has ever been
    # written down, and a verdict nobody records is a layer nobody can measure.
    class Escalation
      # A rung answered something that is not a {Ruling}: the total-predicate
      # mistake, raised INSIDE the consult so it becomes a fault like any other
      # broken rung rather than a NoMethodError far from its cause.
      class NotARuling < Error; end

      class UnknownVerdict < Error; end

      # The rung a synthesized ruling wears: the ladder itself, deciding because
      # nothing else would. A name, not a nil, so journal readers never guard.
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
        # Data class (the {Request::SYSTEM_PREFIX} trap).

        # Three-valued, and abstention is a MEMBER here rather than the absence
        # of a Ruling -- which is the one place this file departs from {Rule},
        # deliberately. A rule abstains by answering nothing because it is a
        # partial predicate over one call; a rung abstains as a REPORT, because
        # the ladder journals what each rung said and "said nothing" is a thing
        # a reader needs to see said.
        VERDICTS = %i[allow deny abstain].freeze

        # WHO answered, in the only distinction the ladder acts on: a person, or
        # something automatic. It is not a synonym for the rung -- the asking
        # rung produces both, depending on which surface won the race for the
        # pending -- and it is the whole reason an {AutoSurface}'s allow is
        # suppressed over a fault where a human's is honoured.
        AUTHORITIES = %i[automatic human].freeze
        class UnknownAuthority < Error; end

        def self.allow(rung:, because:, **rest) = new(verdict: :allow, rung:, reason: because, **rest)
        def self.deny(rung:, because:, **rest) = new(verdict: :deny, rung:, reason: because, **rest)
        def self.abstain(rung:, because:, **rest) = new(verdict: :abstain, rung:, reason: because, **rest)

        # An abstention that is NOT a plain one: something broke, so no automatic
        # allow above it may be promoted. See the class comment on laundering.
        def self.fault(rung:, because:) = new(verdict: :abstain, rung:, reason: because, fault: true)

        def initialize(verdict:, rung:, reason:, fault: false, authority: :automatic)
          unless VERDICTS.include?(verdict)
            raise UnknownVerdict, "unknown verdict #{verdict.inspect}; expected one of #{VERDICTS.inspect}"
          end
          unless AUTHORITIES.include?(authority)
            raise UnknownAuthority, "unknown authority #{authority.inspect}; expected one of #{AUTHORITIES.inspect}"
          end

          super(verdict:, rung: -rung.to_s, reason: -reason.to_s, fault: fault == true, authority:)
        end

        def allow? = verdict == :allow
        def deny? = verdict == :deny

        # Asked, never inferred from `!allow?`, which is true of a denial AND of
        # an abstention -- and this whole layer's premise is that those are
        # different outcomes.
        def abstain? = verdict == :abstain
        def fault? = fault
        def human? = authority == :human

        def record
          { "verdict" => verdict.to_s, "rung" => rung, "reason" => reason,
            "faulted" => fault, "authority" => authority.to_s }.freeze
        end
      end

      # How a session wires it (see {CLI::Switchboard}): the deterministic rungs
      # first, the asking rung last.
      #
      # BOTH deterministic rungs are inert as this repo wires them TODAY, and
      # that is a fact about the wiring rather than about the mechanism:
      #
      # * `rules:` is empty, because T20's remembered answers need a project root
      #   the switchboard does not hold. An empty rung abstains on everything,
      #   which by this class's own composability property changes no outcome.
      # * `triage:` defaults to a {Shell::Verdict} over
      #   {Shell::Verdict::AnyProgram}, which permits every program, and to
      #   {Triage::AnyPath}, which protects no path -- and nothing in `lib/`
      #   constructs a restricting capability set or knows a home to anchor a
      #   {Sensitivity} on. So BOTH of {Triage}'s deny arms, the two things in
      #   this file that refuse anything on their own, wait on a call site.
      #
      # Both are seams rather than hardcoded, so wiring either is a call-site
      # change and not an edit to this file. Until then a gated call gets two
      # journal lines and parks exactly where it parked before.
      def self.for(queue:, tools:, journal:, rules: [], triage: Triage.new)
        new([triage, Rules.new(rules:, tools:, faults: Faults.new(journal)), Surfaces.new(queue)], journal:)
      end

      include Enumerable

      # @param rungs [Enumerable<#call, #name>] consulted in order
      # @param journal [#record] where every ruling lands as evidence
      def initialize(rungs = [], journal:)
        @rungs = rungs.to_a.freeze
        # Every rung names itself HERE, while the ladder is BUILT, and the answer
        # is KEPT -- {RuleChain}'s reasoning exactly: asking a rung for its name
        # inside the rescue clause, after it has just proved it can raise, is how
        # a second raise escapes and takes the ladder down.
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
        # The FIRST fault is the one that suppresses, and it is remembered rather
        # than counted: what a suppression has to name is the rung that broke.
        remember = ->(ruling) { faulted ||= ruling }
        # Lazy, so the rungs past the deciding one are never consulted: parking a
        # human on a call an earlier rung already settled is the whole thing this
        # ladder exists to avoid.
        decided = @consulted.lazy
                            .filter_map { |rung, name| decisive(consult(rung, name, effect, context), &remember) }
                            .first
        answer(decided, faulted, effect)
      end

      def consult(rung, name, effect, context) = record(ask(rung, name, effect, context), effect)

      def ask(rung, name, effect, context)
        ruling = rung.call(effect, context)
        return ruling if ruling.is_a?(Ruling)

        raise NotARuling, "#{name} answered #{ruling.class}; a rung rules or abstains"
      rescue StandardError => e
        # A rung's own failure -- a failed spawn, an unreadable config -- is a
        # fault and never an approval. Deny-when-unsure is the doctrine
        # `auto_surface.rb:21-25` states one rung up, and it binds every rung.
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

      # The three rulings nobody made as such: a human's allow re-stated so the
      # record carries the fault it was given despite, the suppression of an
      # automatic allow attributed to the rung that faulted, and the fail-closed
      # bottom.
      def honoured(decided, faulted)
        decided.with(fault: true, reason: "#{decided.reason} -- #{HONOURED} #{faulted.rung}: #{faulted.reason}")
      end

      # The rung stays LADDER when nothing answered, because nothing did -- a
      # reader tallying denials by rung must not be told a rung that abstained
      # refused. But the fault still gets named: it is one line up in the stream
      # either way, and a fail-closed denial that silently omits the reason a
      # rung had nothing to say is the record being less useful than it can be.
      def synthesized(decided, faulted)
        return Ruling.deny(rung: faulted.rung, because: "#{LAUNDERED}: #{faulted.reason}") if decided
        return Ruling.deny(rung: LADDER, because: NOTHING_ANSWERED) unless faulted

        Ruling.deny(rung: LADDER, fault: true,
                    because: "#{NOTHING_ANSWERED} -- and #{faulted.rung} faulted: #{faulted.reason}")
      end

      # Evidence about a turn must never COST the turn: this ladder sits on
      # Gate's policy seam, ABOVE {Effect::Handler::Live}, so nothing below is
      # left to turn an exception into a {Tool::Result} and a closed Journal
      # would hand the user a dead turn instead of the denial an unanswerable
      # approval is owed. {Approval::Queue#record_evidence} states it at length.
      # `tool_use_id` rather than the tool name alone: parallel tool calls put
      # several gated calls of the SAME tool in flight at once, so the name
      # cannot attribute a ruling -- or a fault -- to the call it belongs to.
      def record(ruling, effect)
        @journal.record({ "type" => TYPE, "tool" => effect.name,
                          "tool_use_id" => effect.tool_use_id }.merge(ruling.record))
        ruling
      rescue StandardError
        ruling
      end

      # Where a broken RULE is reported, journal-backed. {RuleChain}'s default is
      # {RuleChain::Faults::Null}, and under poisoning that silence is dangerous
      # in a new way -- the chain still refuses to promote an allow past a fault,
      # but nobody is ever told the rule is broken. A live wiring passes this.
      class Faults
        TYPE = "escalation_fault"

        def initialize(journal)
          @journal = journal
          freeze
        end

        # `tool_use_id` is the call's, not the fault's: a {RuleChain::Fault} is
        # built from a {Rule::Call}, which carries the tool and its input and no
        # identity for the invocation. Without it a reader cannot join a fault to
        # the ruling it poisoned once parallel tools put two bash calls in
        # flight -- which is also why {Rules} stamps it per call.
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
        #   is read off the exact tool the executor would dispatch
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

        # The chain is built PER CALL only because its fault recorder is stamped
        # with THIS call's `tool_use_id`; the poisoning itself is the chain's own
        # (it answers a {RuleChain::Poisoned}), so nothing here has to keep a
        # tally of the fault stream to tell an abstention from a suppression.
        def call(effect, _context)
          ruling(RuleChain.new(@rules, faults: recorder(effect)).decide(subject(effect)))
        rescue Rule::Call::Undeclared, Tool::InvalidInput, Toolset::UnknownTool => e
          # Structural, expected, and not a bug: a tool with no declaration, an
          # input the tool itself will refuse, a name this session does not hold.
          Ruling.abstain(rung: NAME, because: "#{NO_SUBJECT}: #{e.class}: #{e.message}")
        rescue StandardError => e
          # MEASURED (T19's panel): `Rule::Call.for` is not total. Invalid UTF-8
          # in a required String raises ArgumentError from ActiveSupport's
          # `String#blank?`, NOT Tool::InvalidInput. And a rescue list is not a
          # substitute for a total classifier -- a NUL byte and a UTF-16LE value
          # BUILD cleanly here and detonate later, inside a rule, where the
          # tally below is what catches them.
          Ruling.fault(rung: NAME, because: "#{BROKEN}: #{e.class}: #{e.message}")
        end

        private

        def subject(effect) = Rule::Call.for(tool: @tools.fetch(effect.name), input: effect.input)

        # Stateless and per call, so two gated fibers never share one: it exists
        # only to carry this call's identity onto whatever the chain reports.
        def recorder(effect) = ->(fault) { @faults.call(fault, tool_use_id: effect.tool_use_id) }

        # A deny after a fault still denies and is still attributed -- what
        # poisoning suppresses is the ALLOW side, and only that -- but the record
        # says a fault happened, or a reader sees a clean denial that was not one.
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
      # excludes a program the command names -- a decision the session already
      # made -- and until this rung existed nothing enforced it: `Tools::Bash`
      # routes a non-allow straight to `sh -c` (`bash.rb:103`), so a denied
      # command ran anyway, silently. Here it refuses at the gate, before the
      # tool is reached at all.
      #
      # An ALLOW abstains, and that is the important half. `rm -rf /home/joel`
      # is literal, fully understood, and covered to the byte; promoting that to
      # an approval would auto-run it. The verdict's own {Shell::Verdict::CLAIM}
      # says what it is claiming, this rung takes it at exactly its word, and the
      # human still sees the call. What the allow DOES buy is one layer down --
      # `Tools::Bash` runs the reconstructed argv rather than the string once
      # approved -- and that is a property of the execution, not a licence to
      # skip the human.
      #
      # == ...with one refusal read off the allowed argv
      #
      # An allow hands over the PARSED WORDS, and that is the only place in this
      # ladder where a path a command names can be read without guessing. So the
      # allow branch asks a {Sensitivity} about each word and refuses when one of
      # them is a path nothing may read -- a private key, a keyring, a `.netrc`.
      #
      # Three properties hold it in scope, and each is a spec:
      #
      # * *The argv, never the command string.* `approval/rule.rb:36-52` and
      #   `risk.rb:74-80` both name the same hole -- a signal read off one flat
      #   field is confident about text it has not understood -- so a command the
      #   verdict abstained on is not scanned at all. `cat '~/.ssh/id_rsa'`
      #   abstains and reaches a human; it does not deny on a substring.
      # * *Denied only, and only when written as a path.* A GATED path stays an
      #   abstention, because an abstention already reaches a human and a second
      #   gating notion here would decide nothing the queue does not already
      #   decide. A denied name written as a BARE word does too -- it is named in
      #   the record and nothing more. {PATHLIKE} carries that ruling and the
      #   measurement behind it.
      # * *Inert until wired.* No home is known where a ladder is built, so the
      #   classifier is injected and defaults to {AnyPath}.
      class Triage
        NAME = "triage"

        # Both tools declare `Bash::Input`, so both hand the model a command
        # string. Named rather than sniffed: a tool that grows a `command` field
        # should have to be added here deliberately.
        COMMAND_TOOLS = %w[bash core_exec].freeze
        FIELD = "command"
        # Both tools take this from `Bash::Input` too, and `Tools::Bash` runs
        # every command under it (`bash.rb:137`), so it is where a relative word
        # in the argv lands.
        CWD_FIELD = "cwd"

        NOT_JUDGED = "this rung judges only the tools whose input is a command string"
        NOT_A_COMMAND = "the call carries no command string to judge"
        NOT_SAFE = "an allow claims the command is literal and fully understood, never that it is safe"
        PROTECTED = "the command's argv names a path no approval may lift"
        BARE = "a word matches a protected name but is not written as a path, so this rung only says so"

        # A word is evidence about a PATH when it is written as one: it carries
        # a separator, or it names a home. MEASURED, and the reason the refusal
        # is this narrow: six of the denied rules match a bare basename, four of
        # them (`.netrc`, `.gnupg`, `.password-store`, `*.kdbx`) from ANY cwd and
        # two (`Cookies`, `key4.db`) anywhere under `$HOME` -- which is where
        # checkouts live. Denying on a bare word therefore stops
        # `grep -n Cookies lib/lain/sensitivity.rb` in this very repository, and
        # NOTHING lifts it: not a policy, not `--yolo`, not `ApproveAll`, and not
        # `[sensitivity] exempt`, which subtracts from the gated half only
        # (`sensitivity.rb:170-175`).
        #
        # The trade is deliberate and it is small. A denied path named as a bare
        # word DROPS FROM DENY TO ABSTAIN -- it is still named in the record, the
        # call still reaches a human because {Triage} downgrades every allow
        # anyway, `Tools::Bash` is gated regardless, and the read boundary proper
        # ({Sensitivity::Policy}) classifies the RESOLVED path when a tool opens
        # it. This rung is a bonus refusal on unambiguous evidence, and a word
        # with neither a separator nor a tilde is not unambiguous evidence.
        #
        # The tilde arm earns its place only barely, and it is worth saying how
        # narrowly. It needs the `verdict:` seam in every case: today's
        # {Shell::Verdict} abstains on any word matching its `EXPANDING`, which
        # includes every `~`. Past that, a SLASHLESS tilde word is rewritten by
        # {Sensitivity} to the home directory ITSELF, so the arm fires when that
        # directory is denied -- by EITHER a `[sensitivity] denied` rule naming
        # the home's basename, OR a home that is a denied path in its own right
        # (`/home/.gnupg`, `/home/x/.netrc`; both verified). No config is needed
        # for the second. It stays because the two objects agree deliberately
        # about what a leading `~` means and dropping it would silently
        # disagree, and because {Shell::Verdict} contemplates widening.
        PATHLIKE = %r{/|\A~}

        # Bounded like {Shell::Verdict}'s own unaccounted-bytes reason: a long
        # command can name many, and a Journal line wants the shape rather than
        # the census. Bounds the RENDERING only -- every word is still classified,
        # or a refusal could hide behind eight harmless ones.
        MAX_NAMED = 8

        # The classifier of a session that protects nothing, and the shape of
        # {Shell::Verdict::AnyProgram} for the same reason: an inert default that
        # answers the same messages a real one does, so no branch below guards on
        # nil. It is its own factory, because there is nothing to build.
        class AnyPath
          ORDINARY = Sensitivity::Verdict.new(level: :ordinary, reason: :none)

          def call(_cwd) = self
          def classify(_path) = ORDINARY
        end

        # `verdict:` defaults at CALL time, not in a constant: `lain.rb` loads
        # `lain/approval` twenty-odd entries before `lain/shell`, so a
        # `Shell::Verdict.new` in this class body is a hard NameError at load.
        # {Sensitivity} loads BEFORE approval, so {AnyPath} may be built here.
        #
        # @param verdict [#call] `String -> Shell::Verdict::Decision`
        # @param tools [Enumerable<String>] the tools whose input is a command
        # @param field [String] the input field carrying that command
        # @param sensitivity [#call] `cwd -> #classify`, a {Sensitivity} FACTORY
        #   rather than one classifier: a bash call names its own working
        #   directory, so a classifier built once at wiring time would anchor a
        #   relative word under whatever directory the agent started in -- and
        #   could refuse a project file for a name it happens to share with a
        #   browser profile, which no policy can then lift. The cwd is handed
        #   over AS THE CALL WROTE IT (relative, or nil when it named none),
        #   because only the wiring knows what it resolves against.
        #
        #   IT MUST BE TOTAL, and that is a security property rather than
        #   tidiness. `cwd` is MODEL-CONTROLLED (`bash.rb:50`) and
        #   `Sensitivity.new` refuses a cwd that is not absolute and readable, so
        #   a factory that lets those raise hands the model a one-argument
        #   disarm: the raise becomes a {RUNG_BROKE} fault, the fault turns this
        #   deny into the abstention it exists to replace, and a human -- whose
        #   allow is honoured over a fault, by design -- approves the read. A
        #   factory resolves the cwd itself and falls back to a classifier that
        #   refuses NOTHING when it cannot, because a wiring error is not
        #   evidence about a path. {AnyPath} is that fallback.
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

        # The allow branch, and the only one with an argv to read: `term` is
        # {Shell::Verdict::NO_TERM} on a deny and on every abstention
        # (`shell/verdict.rb:249-253`), so a path check anywhere else would be
        # interrogating a Null Object about a path nobody wrote.
        def literal(decision, effect)
          written, bare = refused(decision.term, effect.input[CWD_FIELD]).partition { |word, _| word.match?(PATHLIKE) }
          return Ruling.deny(rung: NAME, because: because(decision, named(PROTECTED, written))) unless written.empty?
          return Ruling.abstain(rung: NAME, because: because(decision, named(BARE, bare))) unless bare.empty?

          Ruling.abstain(rung: NAME, because: because(decision, NOT_SAFE))
        end

        # EVERY word of every stage, including each argv0: a word is offered as
        # written, and one that is not a path at all resolves to a name under the
        # cwd and classifies ordinary. What separates a refusal from a mention is
        # {PATHLIKE}, applied after the classification rather than before it, so
        # a bare match can still be named in the record.
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

        # {Shell::Verdict::CLAIM} rides on every record, so nothing a reader of
        # the Journal finds here can be read as a claim about safety.
        def because(decision, note = nil)
          ["shell verdict #{decision.name}", note, decision.reason, Shell::Verdict::CLAIM].compact.join(" -- ")
        end
      end

      # The asking rung: {Approval::Queue}, where a call parks for whatever
      # surfaces are watching -- {AutoSurface}'s adjudicating role, the TTY
      # prompt, a Neovim view -- and where the window expiring is itself a
      # denial signed by the clock (`queue.rb:218-222`). Total by construction,
      # which is what makes it the bottom of the ladder.
      #
      # The queue journals its own decision with the SURFACE that made it, so
      # this rung's record says only that the surfaces answered; which surface
      # is one line over, and not duplicated here.
      class Surfaces
        NAME = "surfaces"

        # THE GENERATING RULE: a surface belongs here when no person is behind
        # it. `auto_approver` is an LLM adjudicating; the other two are the clock
        # and a cancellation. Every surface that decides a {Queue::Pending} today
        # is accounted for -- the human ones are
        # `Frontend::ApprovalPolicy::SURFACE` and `Notify::SURFACE`.
        #
        # An unknown name therefore counts as HUMAN. The two failure modes are
        # structurally symmetric -- one list or the other, one direction of error
        # each -- so what decides it is WHICH WAY the error runs. Reading an
        # unlisted surface as automatic would suppress its allow over a fault,
        # which is exactly the wedge the class comment above exists to refuse,
        # re-opened at the frontend boundary: the place where an author has least
        # reason to suspect that the NAME of an approval surface is
        # security-relevant. Reading it as human costs the other direction --
        # an unlisted automatic surface's allow survives a fault -- and that one
        # fails visibly in a review of a file whose whole subject is adjudication.
        #
        # The deeper defect is not this default. It is that authority is INFERRED
        # from a surface name one layer down, when the decider always knew what it
        # was; "identity travels with the decision" is the rule that says so, and
        # it is why {Ruling} needed an `authority` member at all. The fix is
        # `Pending#decide(verdict, surface:, authority:)` with NO default, so a
        # surface that forgot to declare is a loud ArgumentError at one of five
        # call sites rather than a silent reclassification here. Ticketed.
        # T17 is what the paragraph above predicted, and it took one card to
        # arrive: `secret_oracle` is a 4B LOCAL MODEL releasing files the
        # detector flagged as holding credentials, and an unlisted surface
        # counts as human -- so the one surface built to release secrets was the
        # one this ladder trusted most, its allow surviving a fault that
        # `auto_approver`'s identical judgement does not. Listed here, it is
        # `:automatic` like every other machine.
        AUTOMATIC = [AutoSurface::SURFACE, SecretSurface::SURFACE,
                     Queue::TIMEOUT_SURFACE, Queue::ABANDONED_SURFACE].freeze

        APPROVED = "a surface approved this call"
        REFUSED = "a surface refused this call, or the window closed and the fail-closed doctrine did"

        # The parked list is the SAME object `/approve` drains and `Wiring`
        # exposes; readable here so "the gate asks through the session's one
        # queue" stays an identity a caller can check, not a shape it must
        # trust. A reader and nothing else -- the rung is frozen.
        attr_reader :queue

        def initialize(queue, automatic: AUTOMATIC)
          @queue = queue
          @automatic = automatic.to_a.map { |surface| -surface.to_s }.freeze
          freeze
        end

        def name = NAME

        # {Queue#adjudicate} rather than `#call`, because the Boolean cannot
        # carry WHO answered, and who answered is the one thing the ladder above
        # needs in order not to throw a person's approval away.
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
