# frozen_string_literal: true

module Lain
  module Approval
    # An ordered chain of {Rule}s, consulted until one has an opinion.
    #
    # The whole object is the lookup: ask each rule in turn, answer the first
    # {Rule::Decision} anyone produces, and answer nothing when nobody does.
    # "Nothing" is the interesting outcome -- it is what routes a call up to the
    # surfaces that already exist ({Approval::Queue}, {AutoSurface}, and the
    # fail-closed timeout behind them), so the deterministic layer never has to
    # invent an answer to stay total.
    #
    # It is `include Enumerable` over its rules ({Toolset}'s idiom) because a
    # chain is a thing you read: "which rules are in force, in what order" must
    # be answerable without running a call through it.
    #
    # == A fault poisons the allow side, and only the allow side
    #
    # A rule that raises is recorded as a {Fault} and the chain continues to the
    # next rule -- but if what the chain then reaches is an ALLOW, the chain
    # answers nothing instead, and the call escalates.
    #
    # Plain skip-and-continue was measured and is unsound: `[Raiser, Allower]`
    # answered allow while `[Denier, Allower]` answered deny, so ONE bug flips a
    # denial into an approval, and the resulting Decision is `to_h`-identical to
    # a clean one -- the caller cannot tell it stepped over a broken rule.
    # Deny-on-raise is unsound the other way: {Effect::Handler::Gate} renders
    # every denial as `"approval denied for tool ..."` with no rule and no
    # reason (`gate.rb:70`), so a `NoMethodError` in one rule would present to
    # the model exactly like policy, indefinitely.
    #
    # Poisoning is what makes a fault an actual NO-OP, which is the doctrine
    # {AutoSurface} already follows one rung up: a failed spawn there decides
    # nothing (`auto_surface.rb:110-114`) -- it does not let some other surface's
    # yes through in its place. Promoting the next rule's allow is not a no-op.
    # A deny after a fault still denies and is still attributed.
    #
    # == A poisoned answer is NOT the same nothing as an abstention
    #
    # This chain first shipped answering `nil` for both, and that was a defect
    # rather than a simplification: `nil` then meant "nobody had an opinion" AND
    # "an allow was suppressed", which are not interchangeable to a composer. A
    # rule that OWNS an inner chain -- the shape this class exists to make
    # possible -- would hand the outer chain the inner's poisoned `nil`, the
    # outer would read it as a plain abstention, and the next rule's allow would
    # be promoted over a fault that really happened:
    #
    #   inner = RuleChain.new([Raiser, Allower])          # poisons correctly
    #   RuleChain.new([Delegating.new(inner), Allower]).decide(call)   # => allow
    #
    # So a poisoned answer is a {Poisoned}, and {#consult} understands one when a
    # rule hands it back. Nesting then composes for free, and a caller can tell
    # the two nothings apart without keeping its own tally of the fault stream.
    class RuleChain
      # A subject that is not a {Rule::Call}. The chain type-checks exactly here
      # -- normally it would depend on messages, not types, but "a rule sees the
      # validated input object" is the card's central claim, and a claim about
      # what an object IS cannot be made by duck typing.
      class NotACall < Error; end

      # A rule that answered something other than a {Rule::Decision} or nothing:
      # the total-predicate mistake this chain exists to make unnecessary. It is
      # raised INSIDE the consult, so it becomes a {Fault} like any other broken
      # rule rather than a `NoMethodError` far from its cause.
      class NotADecision < Error; end

      # A rule that raised instead of deciding. Deeply frozen and string-valued
      # so it can go straight into the Journal: the exception itself is neither
      # shareable nor JSON-safe, and its class and message are what a reader
      # needs to find the rule.
      Fault = Data.define(:rule, :tool, :error, :message)

      # Reopened rather than written in the `Data.define` block -- a nested
      # constant declared inside that block is scoped to the enclosing module,
      # not to the Data class.
      class Fault
        # @param rule [String] the deciding rule's name, CAPTURED at wiring
        #   time. Asking the rule for it here would be asking a rule that has
        #   just proved it can raise, from inside the rescue clause -- which is
        #   how the second raise escapes.
        # @param call [Rule::Call] the call the raising rule was deciding, so
        #   the fault can name the tool by `#tool_name` for a reader who has
        #   only the journal
        # @param error [StandardError] what the rule raised; only its class
        #   and message survive into {Fault}, since the exception itself is
        #   neither shareable nor JSON-safe
        def self.for(rule:, call:, error:)
          # An anonymous exception class answers a nil name, and a blank error
          # field is a record nobody can act on.
          new(rule: -rule.to_s, tool: -call.tool_name.to_s,
              error: -(error.class.name || error.class.inspect).to_s,
              message: -error.message.to_s)
        end
      end

      # What a chain answers when a rule faulted: the decision that survived the
      # fault (a deny, or nothing once an allow was suppressed) travelling
      # WITH the fault that poisoned it.
      #
      # It is a value rather than a bare sentinel because a caller needs both
      # halves -- "did anything break" and "what, if anything, was still
      # decided". A deny reached after a fault is still a deny and is still
      # attributed; a record of it that does not say a rule broke is a clean
      # denial that was not one.
      Poisoned = Data.define(:decision, :fault)

      # Reopened rather than written in the `Data.define` block, per
      # {Request::SYSTEM_PREFIX}.
      class Poisoned
        # Answers the same three questions a {Rule::Decision} does, so a caller
        # branching on the verdict does not have to unwrap first. `allow?` is
        # unconditionally false: an allow is exactly what poisoning suppresses,
        # so one can never be inside.
        def allow? = false
        def deny? = !decision.nil? && decision.deny?
        def faulted? = true
      end

      # Where a broken rule is reported: anything answering `#call(Fault)`.
      module Faults
        # The `/dev/null` of fault recorders ({Sink::Null}'s posture), so a
        # chain built without one still runs and no call site guards on nil.
        #
        # It is the DEFAULT, and poisoning makes that silence dangerous in a new
        # way: a chain wired with this one still refuses to promote an allow
        # past a fault, but nobody is ever told the rule is broken. A live
        # wiring passes a journal-backed recorder.
        module Null
          def self.call(_fault) = nil
        end
      end

      include Enumerable

      # @param rules [Enumerable<#decide, #name>] consulted in order
      # @param faults [#call] where a raising rule is reported
      def initialize(rules = [], faults: Faults::Null)
        @rules = rules.to_a.freeze
        # Every rule names itself HERE, while the chain is being BUILT, and the
        # answer is KEPT. #name is how both a Decision and a Fault attribute
        # themselves, so asking a rule at decide time -- inside the rescue
        # clause, after it has just proved it can raise -- is how a second raise
        # escapes and takes the whole chain down. Asked once, the check becomes
        # a guarantee: a rule that names itself at wiring and refuses later
        # cannot reach the fault path at all.
        #
        # The cost is that the rule source is consumed eagerly, so a chain
        # cannot be built over an endless generator. That is the right trade
        # rather than a regrettable one: this class claims "which rules are in
        # force, in what order" is answerable without running a call through it,
        # and no endless source can answer it.
        @consulted = @rules.map { |rule| [rule, -rule.name.to_s].freeze }.freeze
        @faults = faults
        freeze
      end

      def each(&block)
        return enum_for(:each) unless block

        @rules.each(&block)
      end

      # @param call [Rule::Call] the validated call to judge
      # @return [Rule::Decision, Poisoned, nil] the first decision made; a
      #   {Poisoned} when a rule faulted, carrying whatever survived it; nil when
      #   no rule had an opinion at all. The last two both escalate, and a caller
      #   that treats them as the same thing is the laundering bug in the class
      #   comment.
      def decide(call)
        raise NotACall, "a rule chain decides a Rule::Call, got #{call.class}" unless call.is_a?(Rule::Call)

        # A local rather than instance state: #initialize freezes the chain, so
        # a `@faulted` would be a FrozenError on the first broken rule. The FIRST
        # fault is kept, because what a poisoned answer has to name is the rule
        # that broke.
        faulted = nil
        remember = ->(fault) { faulted ||= fault }
        # Lazy, so the rules past the deciding one are never consulted: a chain
        # is a lookup, not a survey, and a later rule must not pay (or fault)
        # for a call an earlier one already settled.
        decision = @consulted.lazy.filter_map { |rule, name| consult(rule, name, call, remember) }.first
        return decision unless faulted

        Poisoned.new(decision: decision&.allow? ? nil : decision, fault: faulted)
      end

      private

      # A rule may hand back another chain's {Poisoned} -- that is what a rule
      # OWNING an inner chain does, and it is the case a plain type check would
      # turn into a NotADecision fault of its own. Unwrapping it here is what
      # makes nesting compose: the inner fault propagates as this chain's fault,
      # and whatever survived it goes on being the answer.
      # `remember` is a plain argument rather than a block because this method
      # passes it ON to {#propagate}, and a block that only exists to be
      # re-yielded is the shape `Style/ExplicitBlockArgument` and
      # `Performance/RedundantBlockCall` disagree about. It is the same
      # accumulator {Escalation#settle} threads one layer up.
      def consult(rule, name, call, remember)
        answer = rule.decide(call)
        return answer if answer.nil? || answer.is_a?(Rule::Decision)
        return propagate(answer, remember) if answer.is_a?(Poisoned)

        raise NotADecision, "#{name} answered #{answer.class}; a rule decides or says nothing"
      rescue StandardError => e
        fault = Fault.for(rule: name, call:, error: e)
        report(fault)
        remember.call(fault)
        nil
      end

      # An inner chain's poison, carried out as this chain's own: the fault it
      # names becomes this chain's fault, and whatever survived it goes on being
      # the answer -- a deny still decides, a suppressed allow still escalates.
      #
      # It does NOT re-{#report} the fault, and with {Faults::Null} as the
      # default constructor argument that is worth stating: a rule that writes
      # `RuleChain.new([...])` with no recorder -- the likely spelling -- keeps
      # its fault out of the recorder stream entirely, because the only chain
      # that ever saw it had nowhere to send it. The OUTCOME is unaffected (the
      # poison propagates either way, and the raising rule is named in the
      # {Fault} this carries, which {Approval::Escalation::Rules} renders into
      # its ruling's reason). What is lost is the fault RECORD, so a nested
      # author who wants one passes the outer chain's recorder inward.
      # Re-reporting here instead would double-record every fault in the common
      # case, where both chains share a recorder.
      def propagate(poisoned, remember)
        remember.call(poisoned.fault)
        poisoned.decision
      end

      # The report is itself total. Behind this seam is a journal, and a journal
      # write is IO that fails on a full disk -- an approval path that dies
      # because it could not write about a broken rule fails in exactly the
      # place it exists to be reliable. There is nowhere else to put the news:
      # `lib/` may not touch the terminal.
      def report(fault)
        @faults.call(fault)
      rescue StandardError
        nil
      end
    end
  end
end
