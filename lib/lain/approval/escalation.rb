# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module Lain
  module Approval
    # The escalation ladder: "middleware wrapping the human", in this repo's own
    # idiom. A ladder is a VALUE -- an ordered list of named rungs -- and every
    # verdict it reaches is journaled attributed to the rung that reached it.
    #
    #   Shell::Verdict / the rules  ->  surfaces (the human, the oracle)  ->  timeout
    #        deterministic                        asking                     fail-closed
    #
    # It presents to {Middleware::Gate} as a ruling policy, `#rule(effect,
    # context) -> Ruling`, handing over the ruling it settled on so a refusal
    # can say which rung made it and why. Three values live INSIDE -- allow,
    # deny, and the abstention that is the absence of either -- and only allow
    # and deny ever leave. `#call` still collapses that to a Boolean for a
    # caller that only needs the answer.
    #
    # == An abstaining rung does not change the outcome
    #
    # The composability property, and what lets rungs be reordered among the
    # abstaining ones without surprise. No rung is ever asked to invent an
    # answer to stay total, because the BOTTOM of the ladder already is: the
    # surfaces rung parks on {Approval::Parked::Queue}, whose window expires into a
    # denial, and a ladder that runs out of rungs refuses. An unanswered gate
    # refuses; it never wedges.
    #
    # == A fault is NOT an abstention, and must not be launderable into one
    #
    # An allow reached after ANY rung faulted is suppressed, and the denial is
    # attributed to the rung that faulted rather than to the rung that was about
    # to say yes -- {Ladder::Poisoning} at this ladder's edge, exempting a human.
    #
    # == ...and the poison STOPS at the asking rung, if a human answered
    #
    # Poisoning is sound between RULES because a later rule is the same kind of
    # authority as the one that faulted. A human is not a later rule: they are
    # the authority this ladder exists to escalate TO, and `#rule` is lazy, so
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
    # `deny` under the same `tool_use_id`, contradicting each other.
    #
    # So a HUMAN surface's allow is honoured and journaled `verdict: allow,
    # faulted: true`, naming the rung that broke -- enough for the bench to
    # exclude those runs without inventing a denial no authority ever made. An
    # {Parked::SecretSurface} allow keeps being suppressed: a model adjudicator IS a later
    # automatic rung wearing a human's clothes. {Ruling#authority} tells them
    # apart.
    #
    # == Every rung's ruling is evidence
    #
    # Each consulted rung's Ruling is journaled, not merely the settled one:
    # this is the only place {Shell::Verdict}'s answer has ever been written
    # down, and a verdict nobody records is a layer nobody can measure.
    #
    # == The context may bar automatic approval
    #
    # {Middleware::WithholdAutomaticOutput} runs a command under a context
    # answering `automatic_approval_barred?`. A barred command's automatic
    # allow is read as an abstention, so it reaches a human or nobody. The
    # settled ruling reaches that layer through {Middleware::Gate}, which
    # hands back whatever any policy settled on. Duck-typed, on
    # {Parked::PolicySwitch::Requested}'s terms: every other context is judged as
    # before.
    class Escalation
      # A name, not a nil, so journal readers never guard.
      LADDER = "ladder"

      NOTHING_ANSWERED = "no rung answered, and an unanswered gate refuses"
      LAUNDERED = "an allow was suppressed because a rung faulted"
      HONOURED = "a human authorized this despite a fault at"
      RUNG_BROKE = "the rung itself failed, which is not an answer"
      BARRED = "an automatic allow does not answer for a command whose automatically approved output was withheld"
      ABANDONED = "the requester was stopped during this rung, so nobody answered"
      UNDECIDED = "the rung's own ladder decided nothing"
      TYPE = "escalation"

      # What one rung said, and everything a journal needs to attribute it.
      # Deeply frozen -- strings interned, `fault` coerced to a strict Boolean --
      # so `Ractor.shareable?` holds and the record is safe to share.
      Ruling = Data.define(:verdict, :rung, :reason, :fault, :authority, :final, :told, :said, :rule, :note, :liftable)

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
        # reason a {Parked::SecretSurface}'s allow is suppressed over a fault where a
        # human's is honoured.
        AUTHORITIES = Parked::Queue::AUTHORITIES

        def self.allow(rung:, because:, **rest) = new(verdict: :allow, rung:, reason: because, **rest)
        def self.deny(rung:, because:, **rest) = new(verdict: :deny, rung:, reason: because, **rest)
        def self.abstain(rung:, because:, **rest) = new(verdict: :abstain, rung:, reason: because, **rest)

        # An abstention that is NOT a plain one: something broke, so no
        # automatic allow above it may be promoted.
        def self.fault(rung:, because:) = new(verdict: :abstain, rung:, reason: because, fault: true)

        # `final` is a deny the session decided BEFORE anyone could be asked --
        # a project exclusion, a protected path, a remembered answer -- so no
        # approval can lift it, and a model told only "denied" retries the same
        # command in another form or concludes the tool is missing. Only the
        # rung that refused can know that, so it is declared, never inferred
        # from the rung's name: a suppressed allow is attributed to the rung
        # that faulted without that rung having refused anything, which is
        # also why {#record} carries it -- the rung alone cannot tell the two.
        #
        # `liftable` marks a final deny that a human in `ask` could still approve,
        # so the model is not promised that no approval will lift it. Off {#record}:
        # the journal keeps the rung, which already implies it.
        #
        # `told` is the clause a MODEL reads, and defaults to the reason. The
        # reason is written for a journal reader and carries what a model would
        # misread -- a verdict's name, its disclaimer about safety -- so a rung
        # that refuses names the narrower clause itself. Left off {#record},
        # which already holds the whole reason.
        #
        # `said` is kept apart from `told` because the gate appends it to its
        # own sentence rather than replacing that sentence, and off {#record}
        # because the queue's `approval_decision` already journals it.
        #
        # `rule` names the {Rule} behind a ruling the rules rung made, so two
        # allows from one rung can be told apart; nil for any other rung. Off
        # {#record} too: {Escalation#record} adds it only when present.
        #
        # `note` is what an ABSTAINING rung wants the human to read when the call
        # parks, and never the model: the ladder hands it down as {Noted}, and it
        # is left off `told` and `said` so no refusal can carry it.
        def initialize(verdict:, rung:, reason:, fault: false, authority: :automatic, final: false, told: nil,
                       said: nil, rule: nil, note: nil, liftable: false)
          unless VERDICTS.include?(verdict)
            raise Error, "unknown verdict #{verdict.inspect}; expected one of #{VERDICTS.inspect}"
          end
          unless AUTHORITIES.include?(authority)
            raise Error, "unknown authority #{authority.inspect}; expected one of #{AUTHORITIES.inspect}"
          end

          super(verdict:, rung: -rung.to_s, reason: -reason.to_s, fault: fault == true, authority:,
                final: final == true, told: -(told || reason).to_s, said: spoken(said), rule: spoken(rule),
                note: spoken(note), liftable: liftable == true)
        end

        def allow? = verdict == :allow
        def deny? = verdict == :deny

        # Asked, never inferred from `!allow?`, which is true of a denial AND
        # of an abstention -- and this layer's premise is that those differ.
        def abstain? = verdict == :abstain
        def fault? = fault
        def human? = authority == :human
        def final? = final
        def liftable? = liftable

        def record
          { "verdict" => verdict.to_s, "rung" => rung, "reason" => reason,
            "faulted" => fault, "authority" => authority.to_s, "final" => final }
            .merge(note ? { "note" => note } : {}).freeze
        end

        private

        # One spelling of no reason, so a blank never leaves a dangling ": ".
        def spoken(said) = (-said.to_s if said.present?)
      end

      # The context a rung below an abstaining one is handed, carrying why the
      # call reached it. Read by respond_to?, so it stays invisible to rungs
      # that do not ask.
      class Noted < SimpleDelegator
        def initialize(context, note)
          super(context)
          @note = note
        end

        def parked_because
          inner = __getobj__
          [*(inner.parked_because if inner.respond_to?(:parked_because)), @note]
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
      #
      # This is `ask` approval's ladder: what the deterministic rungs leave
      # open parks on the queue.
      def self.for(queue:, tools:, journal:, rules: [], triage: Triage.new)
        over(Surfaces.new(queue), label: "ask", tools:, journal:, rules:, triage:)
      end

      # `bypass` approval's ladder: the same deterministic rungs, so a triage deny
      # or a rule deny still decides, and {Bypass} where the queue would be.
      def self.bypass(tools:, journal:, rules: [], triage: Triage.new)
        over(Bypass.new, label: "bypass", tools:, journal:, rules:, triage:)
      end

      # Whether the context a call is judged in bars it from automatic approval.
      def self.barred?(context)
        context.respond_to?(:automatic_approval_barred?) && context.automatic_approval_barred?
      end

      def self.over(bottom, label:, tools:, journal:, rules:, triage:)
        new([triage, Rules.new(rules:, tools:, faults: Faults.new(journal)), bottom], journal:, label:)
      end
      private_class_method :over

      include Enumerable

      # What a `policy_switch` record names this ladder as. Two ladders of one
      # class stand behind the two approval levels, so the class cannot say
      # which one a flip moved to.
      attr_reader :label

      # @param rungs [Enumerable<#call, #name>] consulted in order
      # @param journal [#<<, #record] where every ruling lands as evidence; {Faults} still calls `record`
      # @param label [String] the name a policy flip journals this ladder under
      def initialize(rungs = [], journal:, label: TYPE)
        @label = -label.to_s
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

      # {Middleware::Gate}'s policy seam.
      #
      # @param effect [Effect::ToolCall] the call to judge, already unwrapped
      # @param context [Object, nil] whatever {Effect::Handler} threads through
      #   unexamined; forwarded to every rung's own `#call` untouched
      # @return [Ruling] the settled allow or deny, never an abstention
      def rule(effect, context)
        # The context grows by one {Noted} per abstaining rung that left a note,
        # so the rung that parks the call reads every reason above it. A local,
        # built per call, because the ladder is frozen and shared between fibers.
        handed = context
        steps = @consulted.map do |rung, name|
          Step.new(name) do
            ruling = consult(rung, name, effect, handed)
            handed = Noted.new(handed, ruling.note) if ruling.is_a?(Ruling) && ruling.abstain? && ruling.note
            climbed(ruling, name)
          end
        end
        answer(Ladder::Poisoning.new(Ladder.new(steps), exempt: :human).call, effect, context)
      end

      # @return [Boolean] whether the call may be performed
      def call(effect, context) = rule(effect, context).allow?

      private

      # Built per call, because each rung is asked over the context the rungs
      # above it grew, and the ladder hands every rung the same input.
      class Step
        attr_reader :name

        def initialize(name, &ask)
          @name = name
          @ask = ask
        end

        def call = @ask.call
      end

      # Every rung's answer is journaled as it comes, an {Ladder::Outcome}'s
      # decision included, faulted if it carries a fault.
      def consult(rung, name, effect, context)
        answer = ask(rung, name, effect, context)
        record(shown(answer), effect, context)
        answer
      rescue Async::Stop
        # Stopped while parked: the queue journals the abandonment, but the
        # ladder's own stream would otherwise show a call that never settled.
        record(Ruling.deny(rung: name, because: ABANDONED, authority: :automatic), effect, context)
        raise
      end

      def ask(rung, name, effect, context)
        ruling = rung.call(effect, context)
        return barred(ruling, context) if ruling.is_a?(Ruling)
        return undecided(ruling, name) if ruling.is_a?(Ladder::Outcome)

        # Raised INSIDE the consult, so a rung answering a non-Ruling becomes a
        # fault like any other broken rung rather than a NoMethodError far from
        # its cause.
        raise Error, "#{name} answered #{ruling.class}; a rung rules or abstains"
      rescue StandardError => e
        # A rung's own failure -- a failed spawn, an unreadable config -- is a
        # fault and never an approval. Deny-when-unsure binds every rung.
        Ruling.fault(rung: name, because: "#{RUNG_BROKE}: #{e.class}: #{e.message}")
      end

      def barred(ruling, context)
        return ruling unless ruling.allow? && !ruling.human? && Escalation.barred?(context)

        Ruling.abstain(rung: ruling.rung, because: "#{BARRED}: #{ruling.reason}", rule: ruling.rule)
      end

      # A rung's own ladder that decided nothing, cleanly, abstained, as a
      # nested ladder does inside {Ladder}.
      def undecided(outcome, name)
        return outcome if outcome.decided? || outcome.faulted?

        Ruling.abstain(rung: name, because: UNDECIDED, note: outcome.why_not)
      end

      def shown(answer)
        return answer if answer.is_a?(Ruling)

        ruling = answer.decision || answer.faults.first
        answer.faulted? ? ruling.with(fault: true) : ruling
      end

      def climbed(answer, name)
        return answer if answer.is_a?(Ladder::Outcome)
        return (answer.abstain? ? Ladder::ABSTAIN : answer) unless answer.fault?
        return Ladder::Outcome.new(decision: nil, by: nil, faults: [answer], why_not: nil) if answer.abstain?

        Ladder::Outcome.new(decision: answer.with(fault: false), by: name, faults: [answer], why_not: nil)
      end

      # The edge has already suppressed an automatic allow over a fault; a
      # human's allow over one stands and is re-recorded saying so.
      def answer(outcome, effect, context)
        faulted = outcome.faults.first
        return record(synthesized(outcome, faulted), effect, context) unless outcome.decided?
        return outcome.decision.with(fault: true) if faulted && !outcome.allow?
        return outcome.decision unless faulted

        record(honoured(outcome.decision, faulted), effect, context)
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
      def synthesized(outcome, faulted)
        return Ruling.deny(rung: faulted.rung, because: "#{LAUNDERED}: #{faulted.reason}") if outcome.suppressed?
        return Ruling.deny(rung: LADDER, because: NOTHING_ANSWERED) unless faulted

        Ruling.deny(rung: LADDER, fault: true,
                    because: "#{NOTHING_ANSWERED} -- and #{faulted.rung} faulted: #{faulted.reason}")
      end

      # Never costs the turn: see {Telemetry::Escalation.write}.
      def record(ruling, effect, context)
        ::Lain::Telemetry::Escalation.write(@journal, ruling, effect, context)
        ruling
      end

      # Where a broken RULE is reported: the rules rung reads the faults off its
      # ladder's {Ladder::Outcome} and hands each here, with this call's id.
      class Faults
        TYPE = "escalation_fault"

        Broken = Data.define(:rule, :tool, :error, :message)

        # A rule that raised, as the journal names it.
        class Broken
          # @param fault [Ladder::Fault] what the ladder caught
          # @param tool [#to_s] the tool the call named
          # @return [Broken]
          def self.of(fault, tool:)
            new(rule: fault.rung, tool: -tool.to_s, error: fault.error, message: fault.message)
          end
        end

        def initialize(journal)
          @journal = journal
          freeze
        end

        # `tool_use_id` is the CALL's, not the fault's: a fault is built from a
        # {Rule::Call}, which carries no identity for the invocation. Without it
        # a reader cannot join a fault to the ruling it poisoned once parallel
        # tools put two bash calls in flight.
        def call(fault, tool_use_id: nil)
          @journal.record({ "type" => TYPE, "tool_use_id" => tool_use_id }
                            .merge(fault.to_h.transform_keys(&:to_s)))
        end
      end

      # The deterministic rung over the rules ladder: the remembered answers and
      # any other predicate a session declares, poisoned once at that ladder's
      # edge so a fault followed by an allow escalates rather than settles.
      class Rules
        NAME = "rules"
        NO_OPINION = "no rule had an opinion"
        NO_SUBJECT = "no rule could be shown this call"
        BROKEN = "the rung could not build a subject to judge"

        # One {Rule} as a {Ladder} rung: its decision, its raw inner outcome
        # when it owns a ladder, or an abstention whose reason is its `why_not`.
        class Consulted
          attr_reader :name

          def initialize(rule, report)
            @rule = rule
            @name = -rule.name.to_s
            @report = report
            freeze
          end

          # @param call [Rule::Call]
          # @return [Rule::Decision, Ladder::Outcome, Ladder::Reasoned]
          # @raise [Ladder::NotADecision] when the rule answers anything else; the
          #   ladder catches it as this rule's fault
          def call(call)
            answer = @rule.decide(call)
            return Ladder.abstain { explain(call) } if answer.nil?
            return answer if answer.is_a?(Rule::Decision) || answer.is_a?(Ladder::Outcome)

            raise Ladder::NotADecision, "#{@name} answered #{answer.class}; a rule decides or says nothing"
          end

          private

          # A rule that raises while explaining has no reason, and the call is
          # already parking; the fault is reported and decides nothing.
          def explain(call)
            @rule.why_not(call)
          rescue StandardError => e
            @report.call(Ladder::Fault.for(rung: @name, error: e))
            nil
          end
        end

        UNREPORTED = ->(_fault) {}

        # The rules as one ladder, unpoisoned: what a rule owning an inner
        # ladder hands up, and what this rung poisons at its edge.
        #
        # @param rules [Enumerable<Rule>]
        # @param report [#call] told a fault raised while explaining
        # @return [Ladder]
        def self.ladder(rules, report: UNREPORTED) = Ladder.new(rules.map { Consulted.new(_1, report) })

        # @param rules [Enumerable<Approval::Rule>] consulted in order
        # @param tools [#fetch] the LIVE capability set, so the tier a rule reads
        #   is read off the exact tool the executor would dispatch -- and so is
        #   {Rule::Call#term}, which that tool derives from its own
        #   {Shell::Verdict} rather than this rung threading one down
        # @param faults [#call] where a broken rule is reported; REQUIRED, with
        #   no Null default, because a ladder wired with a silent recorder is
        #   lenient in exactly the way poisoning exists to prevent
        def initialize(rules:, tools:, faults:)
          @rules = rules.to_a.freeze
          @tools = tools
          @faults = faults
          freeze
        end

        def name = NAME

        def call(effect, _context)
          call = subject(effect)
          report = recorder(effect)
          outcome = Ladder::Poisoning.new(Rules.ladder(@rules, report:)).call(call)
          outcome.faults.each { report.call(_1) }
          ruling(outcome)
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
        # carries this call's identity onto whatever the ladder reports. A
        # recorder that fails costs the record, never the call.
        def recorder(effect)
          lambda do |fault|
            @faults.call(Faults::Broken.of(fault, tool: effect.name), tool_use_id: effect.tool_use_id)
          rescue StandardError
            nil
          end
        end

        # A deny after a fault still denies and is still attributed, and says
        # a fault happened, or a reader sees a clean denial that was not. Either
        # way it is final: a rule is the session's remembered answer, and no
        # human is asked over it.
        def ruling(outcome)
          return refusal(outcome.decision, outcome.faulted?) if outcome.deny?
          return Ruling.fault(rung: NAME, because: broke(outcome.faults.first)) if outcome.faulted? && !outcome.allow?
          return Ruling.abstain(rung: NAME, because: NO_OPINION, note: outcome.why_not) unless outcome.decided?

          Ruling.allow(rung: NAME, because: attributed(outcome.decision), rule: outcome.decision.rule)
        end

        # The model is told the rule's own reason: the journal's attribution
        # prefixes a name the reason usually already starts with.
        def refusal(decision, faulted)
          Ruling.deny(rung: NAME, because: attributed(decision), fault: faulted, final: true,
                      told: decision.reason, rule: decision.rule)
        end

        def attributed(decision) = "#{decision.rule}: #{decision.reason}"

        def broke(fault) = "#{fault.rung} raised #{fault.error}: #{fault.message}"
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
      # == ...with one refusal read off the paths a command names
      #
      # The paths come from {Shell::Named}, never from the command text, and a
      # path nothing may read refuses.
      #
      # * *A doubted command is read only when every path in it is literal.*
      #   The verdict abstains on a quote, a redirect or a builtin, none of
      #   which changes which file `cat` opens; an expansion does, so
      #   `cat "$HOME/.ssh/id_rsa"` reaches a human rather than denying on a
      #   substring.
      # * *Denied only.* A GATED path stays an abstention, which already reaches
      #   a human.
      # * *Inert until wired*: the classifier and the policy default to
      #   protecting nothing.
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
        PROTECTED = "the command names a path no approval may lift"
        # The same refusal as a model reads it, where the sentence around it
        # already says no approval will lift it.
        TOLD_PROTECTED = "the command names a path this session protects"
        BARE = "a word matches a protected name but is not written as a path, so this rung only says so"

        # A word is evidence about a PATH when it is written as one: it carries
        # a separator, or it names a home. MEASURED, and the reason the refusal
        # is this narrow: six denied rules match a bare BASENAME, four
        # (`.netrc`, `.gnupg`, `.password-store`, `*.kdbx`) from any cwd and two
        # (`Cookies`, `key4.db`) anywhere under `$HOME`, which is where
        # checkouts live. Denying on a bare word therefore stops
        # `grep -n Cookies lib/lain/sensitivity.rb` in this very repository, and
        # NOTHING lifts it -- not a policy, not `/mode bypass`, not `ApproveAll`,
        # and not `sensitivity exempt:`, which subtracts from the gated half
        # only.
        #
        # So a denied NAME written as a bare word inside the project DROPS FROM
        # DENY TO ABSTAIN: still named in the record, and the call still reaches
        # a human. Outside the project the false positive was never measured, so
        # `cat shadow` from `/etc` refuses.
        #
        # Where a word LANDS refuses whatever its spelling, and that is a trade
        # too: the refusal fires on the link's own name, so `rm`, `readlink` or
        # `ls -l` of a planted link to `/etc/shadow` is refused as well, and a
        # human removes the link by hand.
        #
        # The tilde arm needs the `verdict:` seam, since {Shell::Verdict}
        # abstains on any word matching its `EXPANDING`; a bare `~` names the
        # home itself, which a project may deny by its basename.
        PATHLIKE = %r{/|\A~}

        # A long command can name many, and a Journal line wants the shape
        # rather than the census. Bounds the RENDERING only -- every word is
        # still classified, or a refusal could hide behind eight harmless ones.
        MAX_NAMED = 8

        # One named path this session protects, and whether the refusal may act
        # on it; {PATHLIKE} says when.
        Refusal = Data.define(:word, :why, :decisive)

        # bash opens it as its own directory, where lain's process would open lain's.
        PROC_CWD = %r{\A/proc/(?:self|thread-self)/cwd(?=/|\z)}

        # The classifier of a session that protects nothing: an inert default
        # answering the same messages a real one does, so no branch below guards
        # on nil. Its own factory, because there is nothing to build.
        class AnyPath
          ORDINARY = Sensitivity::Verdict.new(level: :ordinary, reason: :none)

          def call(_cwd) = self
          def classify(_path) = ORDINARY

          # A session protecting nothing protects nothing for a worker it
          # leases either.
          def for(_worker_env) = self
        end

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
        # @param policy [Sensitivity::Policy, #judge, #home, #confined] judges where
        #   a named path lands, since only it spells a landing under the
        #   configured home and root as well as the real ones; resolves `~`; and
        #   says what lies outside the project
        def initialize(verdict: Shell::Verdict.new, tools: COMMAND_TOOLS, field: FIELD, sensitivity: AnyPath.new,
                       policy: Sensitivity::Policy::Null.instance)
          @verdict = verdict
          @tools = tools.to_a.map { |name| -name.to_s }.freeze
          @field = -field.to_s
          @sensitivity = sensitivity
          @policy = policy
          freeze
        end

        def name = NAME

        def call(effect, context)
          return Ruling.abstain(rung: NAME, because: NOT_JUDGED) unless @tools.include?(effect.name)

          command = effect.input[@field]
          return Ruling.abstain(rung: NAME, because: NOT_A_COMMAND) unless command.is_a?(String)

          judge(@verdict.call(command), effect, context)
        end

        private

        def judge(decision, effect, context)
          return denied(because(decision), told: decision.reason) if decision.deny?
          return literal(decision, effect, context) if decision.allow?

          doubted(decision, effect, context)
        end

        def literal(decision, effect, context)
          decisive, bare = refused(effect, context, allowed: true).partition(&:decisive)
          return protected(decision, decisive) unless decisive.empty?
          return Ruling.abstain(rung: NAME, because: because(decision, named(BARE, bare))) unless bare.empty?

          Ruling.abstain(rung: NAME, because: because(decision, NOT_SAFE))
        end

        def doubted(decision, effect, context)
          decisive = refused(effect, context, allowed: false).select(&:decisive)
          return protected(decision, decisive) unless decisive.empty?

          Ruling.abstain(rung: NAME, because: because(decision))
        end

        def protected(decision, refusals)
          denied(because(decision, named(PROTECTED, refusals)), told: named(TOLD_PROTECTED, refusals))
        end

        # Both of this rung's refusals are final: an exclusion and a protected
        # path are the session's own rules, and no human's answer changes them.
        def denied(reason, told:) = Ruling.deny(rung: NAME, because: reason, final: true, told:)

        # An opaque reading names paths only up to where it stopped, which a
        # doubted command cannot vouch for. Paths come in stage order, so a
        # `cd` target is where the stages after it run.
        def refused(effect, context, allowed:)
          cwd = effect.input[CWD_FIELD]
          dir = directory(cwd, context)
          named = Middleware::ParsedCommand.named_in(effect, context, home: @policy.home)
          paths = vouched(named, allowed)
          return [] if paths.empty?

          judges = [@sensitivity.call(cwd), project(context)]
          here = dir
          paths.filter_map do |path|
            refusal(path, in_place(path.resolved, here), dir, judges).tap { here = path.resolved if path.directory }
          end
        end

        # A doubted opaque reading is vouched for only by the words written as
        # absolute, which no `cd` or unresolved directory can move.
        def vouched(named, allowed) = named.opaque? && !allowed ? named.paths.select(&:absolute?) : named.paths

        # The board's root, and the checkout this call's worker or spike runs in,
        # whose own files share the names a project's do.
        def project(context) = @policy.confined(roots: [Sensitivity::Policy.base_of(context)])

        # The landing first: a link named `.netrc` that opens `/etc/shadow` is
        # refused for the file it opens, not left as a bare protected name.
        def refusal(path, resolved, dir, judges)
          redirect = Landing.redirect(resolved, cwd: dir)
          return by_name(path, [resolved, *redirect], *judges) if redirect.nil? || moved_with?(resolved, redirect, dir)

          verdict = @policy.judge(redirect, cwd: dir)
          return by_name(path, [resolved], *judges) unless verdict.denied?

          Refusal.new(word: path.word, why: "lands on #{redirect}, which is #{verdict.explanation}", decisive: true)
        end

        # Each spelling by name, the real one included, so a cwd that is itself
        # a link out of the project is judged where it really is.
        def by_name(path, spellings, classifier, project)
          verdict = spellings.lazy.map { classifier.classify(_1) }.find(&:denied?)
          return unless verdict

          Refusal.new(word: path.word, why: "is #{verdict.explanation}",
                      decisive: path.word.match?(PATHLIKE) || outside?(project, File.dirname(spellings.first)))
        end

        # A link at or above the word's own directory moves the project with
        # it, so the word has not left for another file, and its real spelling
        # is judged by name; nor has the same file under a home reached
        # through a link.
        def moved_with?(resolved, redirect, dir)
          beside?(redirect, resolved) || Landing.of(redirect, cwd: dir, home: @policy.home).include?(resolved)
        end

        def beside?(redirect, resolved)
          parent = File.dirname(resolved)
          redirect == File.join(Landing.of(parent, cwd: parent).first, File.basename(resolved))
        rescue Error, SystemCallError
          false
        end

        # A directory denied in its own right is treated as outside, the
        # direction a refusal errs in.
        def outside?(project, directory)
          project.judge(directory, cwd: directory).denied? || project.outside?(directory, cwd: directory)
        end

        def in_place(resolved, dir) = resolved.sub(PROC_CWD) { dir }

        # Where `Tools::Bash` runs the command. A cwd nothing can resolve costs
        # the relative anchoring only, never the refusal of an absolute path.
        def directory(cwd, context)
          base = ::Lain::Session.cwd_of(context)
          cwd.is_a?(String) ? File.expand_path(cwd, base) : base
        rescue ArgumentError, EncodingError
          base
        end

        def named(label, refusals)
          "#{label}: #{refusals.first(MAX_NAMED).map { "#{_1.word.inspect} #{_1.why}" }.join("; ")}"
        end

        # {Shell::Verdict::CLAIM} rides on every record, so nothing a Journal
        # reader finds here can be read as a claim about safety.
        def because(decision, note = nil)
          ["shell verdict #{decision.name}", note, decision.reason, Shell::Verdict::CLAIM].compact.join(" -- ")
        end
      end

      # `bypass` approval's bottom rung, standing where {Surfaces} stands under
      # `ask`: a call no rung above decided is approved. AUTOMATIC authority,
      # so an allow reached over a faulted rung is suppressed like any other
      # machine's -- a broken rule never becomes a free pass.
      #
      # A barred command is refused, and FINAL: there is no queue under `bypass`
      # to park it on, so no approval at this level lifts it. The model cannot
      # switch modes, so it is told only that retrying will not help.
      class Bypass
        NAME = "bypass"
        BECAUSE = "approval is bypass, and no rung above refused this call"
        REFUSED = "approval is bypass, and this command is barred from automatic approval; " \
                  "switch to /mode ask to approve it"
        TOLD = "this command's automatically approved output held a credential, so only a human may approve " \
               "it, and no approval is possible while approval is bypass; do not re-send it"

        # Frozen on {Triage}'s terms: a rung holds no state.
        def initialize = freeze

        def name = NAME

        def call(_effect, context)
          if Escalation.barred?(context)
            return Ruling.deny(rung: NAME, because: REFUSED, final: true, told: TOLD, liftable: true)
          end

          Ruling.allow(rung: NAME, because: BECAUSE)
        end
      end

      # The asking rung: {Approval::Parked::Queue}, where a call parks for whatever
      # surfaces are watching, and where the window expiring is itself a denial
      # signed by the clock. Total by construction, which is what makes it the
      # bottom of the ladder.
      #
      # The queue journals its own decision with the SURFACE that made it, so
      # this rung's record says only that the surfaces answered.
      class Surfaces
        NAME = "surfaces"

        APPROVED = "a surface approved this call"
        REFUSED = "a surface refused this call, or the window closed and the fail-closed doctrine did"

        # The SAME object `/approve` drains, readable here so "the gate asks
        # through the session's one queue" stays an identity a caller can check
        # rather than a shape it must trust.
        attr_reader :queue

        def initialize(queue)
          @queue = queue
          freeze
        end

        def name = NAME

        # {Parked::Queue#adjudicate} rather than `#call`, because a Boolean cannot carry
        # WHO answered -- the one thing the ladder above needs in order not to
        # throw a person's approval away.
        def call(effect, context)
          pending = @queue.adjudicate(effect, context)
          authority = pending.authority
          return Ruling.allow(rung: NAME, because: "#{APPROVED} (#{pending.surface})", authority:) if pending.approved?

          Ruling.deny(rung: NAME, because: "#{REFUSED} (#{pending.surface})", authority:,
                      said: pending.timed_out? ? pending.lapse : pending.reason)
        end
      end
    end
  end
end
