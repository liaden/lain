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
    # A deny after a fault still denies and is still attributed; the cost is that
    # a suppressed allow is indistinguishable from "nobody had an opinion", and
    # both escalate, which is the safe direction.
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
        def self.for(rule:, call:, error:)
          # An anonymous exception class answers a nil name, and a blank error
          # field is a record nobody can act on.
          new(rule: -rule.to_s, tool: -call.tool_name.to_s,
              error: -(error.class.name || error.class.inspect).to_s,
              message: -error.message.to_s)
        end
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
      # @return [Rule::Decision, nil] the first decision made, or nil when no
      #   rule had an opinion (or when a fault poisoned an allow) -- the caller
      #   escalates
      def decide(call)
        raise NotACall, "a rule chain decides a Rule::Call, got #{call.class}" unless call.is_a?(Rule::Call)

        # A local rather than instance state: #initialize freezes the chain, so
        # a `@faulted` would be a FrozenError on the first broken rule.
        faulted = false
        # Lazy, so the rules past the deciding one are never consulted: a chain
        # is a lookup, not a survey, and a later rule must not pay (or fault)
        # for a call an earlier one already settled.
        decision = @consulted.lazy.filter_map { |rule, name| consult(rule, name, call) { faulted = true } }.first
        return nil if faulted && decision&.allow?

        decision
      end

      private

      def consult(rule, name, call)
        answer = rule.decide(call)
        return answer if answer.nil? || answer.is_a?(Rule::Decision)

        raise NotADecision, "#{name} answered #{answer.class}; a rule decides or says nothing"
      rescue StandardError => e
        report(Fault.for(rule: name, call:, error: e))
        yield
        nil
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
