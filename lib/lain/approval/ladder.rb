# frozen_string_literal: true

module Lain
  module Approval
    # One first-decisive fold over rungs, shared by the chat's escalation
    # ladder and the rules ladder inside it.
    #
    # A rung answers a decision, {ABSTAIN} (or nil), an {.abstain} with a
    # reason, or another ladder's {Outcome}. The first decision wins and no
    # rung past it is consulted. A rung that raises is a {Fault}, carried in
    # the outcome rather than reported from inside, so a nested ladder cannot
    # lose one.
    #
    # Nesting is a monoid with the empty ladder as its unit, because a nested
    # {Outcome} is unwrapped raw: `[[a, b], c]`, `[a, [b, c]]` and `[a, b, c]`
    # answer alike. That holds only while a fault's effect on a later allow
    # is decided ONCE, at the edge, by {Poisoning}; poisoning inside every
    # nested ladder made the same rungs deny or escalate by bracketing.
    class Ladder
      ABSTAIN = Ractor.make_shareable(Object.new.tap { |o| o.define_singleton_method(:inspect) { "ABSTAIN" } })

      # A rung answered something that is neither a decision nor an abstention:
      # a Boolean from a total-predicate habit, or a bare verdict Symbol.
      class NotADecision < Error; end

      Fault = Data.define(:rung, :error, :message)
      Outcome = Data.define(:decision, :by, :faults, :why_not)

      # An abstention with something for a human to read. The reason is a
      # block, asked only when the outcome is not an allow, since working it
      # out can cost more than the decision did.
      Reasoned = Data.define(:explain)
      Unasked = Data.define(:explains, :fallback)

      # Abstentions' reasons nobody has read yet, carried out of a ladder so one
      # nesting it asks them no sooner than the flat ladder would.
      class Unasked
        # @return [String, nil] the first reason that can be worked out, else the fallback
        def call = explains.lazy.filter_map { Ladder.explained(_1) }.first || fallback
      end

      # A rung that raised instead of answering. Strings only, so it is
      # shareable and journal-safe where the exception is neither.
      class Fault
        # @param rung [#to_s] the rung's name, captured when the ladder was built
        # @param error [Exception]
        # @return [Fault]
        def self.for(rung:, error:)
          new(rung: -rung.to_s, error: -(error.class.name || error.class.inspect).to_s, message: -error.message.to_s)
        end

        # @return [String] the one line a refusal quotes
        def reason = "#{error}: #{message}"
      end

      # The fold's answer. `decision` is nil when no rung decided, or when the
      # edge suppressed an allow, in which case `by` names the rung that faulted.
      class Outcome
        # @param decision [#allow?, #deny?, nil]
        # @param by [#to_s, nil] the leaf rung that decided
        # @param faults [Enumerable<#rung>]
        # @param why_not [#to_s, Unasked, nil]
        def initialize(decision:, by:, faults:, why_not:)
          why_not = -why_not.to_s unless why_not.nil? || why_not.is_a?(Unasked)
          super(decision:, by: (-by.to_s unless by.nil?), faults: faults.to_a.dup.freeze, why_not:)
        end

        # Prepended over the member reader, so an {Unasked} is worked out only
        # when somebody reads it.
        module Asked
          # @return [String, nil]
          def why_not
            reason = super
            reason.is_a?(Unasked) ? reason.call : reason
          end
        end
        prepend Asked

        def decided? = !decision.nil?
        def faulted? = !faults.empty?
        def allow? = decided? && decision.allow?
        def deny? = decided? && decision.deny?

        # The same outcome with its reason worked out, so it is deeply frozen;
        # what a ladder's edge hands out.
        #
        # @return [Outcome]
        def asked = to_h[:why_not].is_a?(Unasked) ? with(why_not:) : self

        # An allow the edge withheld, as opposed to nobody answering.
        def suppressed? = !decided? && !by.nil?
      end

      # @return [Reasoned] an abstention whose reason the block works out
      def self.abstain(&explain) = Reasoned.new(explain:)

      # @param rungs [Array<#call>]
      # @return [Ladder]
      def self.[](*rungs) = new(rungs)

      # @param rungs [Enumerable<#call>] consulted in order; each named by
      #   `#name` if it has one, captured here because asking a rung that has
      #   just raised is how a second raise escapes
      def initialize(rungs = [])
        @rungs = rungs.to_a.freeze
        @named = @rungs.map { |rung| [rung, -(rung.respond_to?(:name) ? rung.name : rung.class.name).to_s].freeze }
                       .freeze
        freeze
      end

      def name = "ladder"

      # Nesting, which is the monoid's operation.
      #
      # @param other [Ladder]
      # @return [Ladder]
      def +(other) = Ladder[self, other]

      # @return [Outcome]
      def call(*input)
        faults = []
        abstained = []
        hit = @named.lazy.filter_map { |rung, name| consult(rung, name, input, faults, abstained) }.first
        decision, by = hit
        Outcome.new(decision:, by:, faults: faults.freeze,
                    why_not: (unasked(abstained.freeze, decision) unless decision&.allow?))
      end

      # A reason that cannot be worked out is no reason, never a fault: it is
      # asked after the decision, and must not change one.
      #
      # @param explain [#call]
      # @return [String, nil]
      def self.explained(explain)
        explain.call
      rescue StandardError
        nil
      end

      private

      def consult(rung, name, input, faults, abstained)
        answered(rung.call(*input), name, faults, abstained)
      rescue StandardError => e
        faults << Fault.for(rung: name, error: e)
        nil
      end

      def answered(answer, name, faults, abstained)
        case answer
        when Outcome then unwrapped(answer, faults, abstained)
        when ABSTAIN, nil then nil
        when Reasoned then abstained.push(answer.explain) && nil
        else [decision(answer, name), name]
        end
      end

      def decision(answer, name)
        return answer if answer.respond_to?(:allow?) && answer.respond_to?(:deny?)

        raise NotADecision, "#{name} answered #{answer.inspect}; a rung decides or abstains"
      end

      # The inner reasons stay unread, so nesting asks them no sooner than flat.
      def unwrapped(outcome, faults, abstained)
        faults.concat(outcome.faults)
        reason = outcome.to_h[:why_not]
        abstained.concat(reason.explains) if reason.is_a?(Unasked)
        abstained.push(-> { reason }) if reason.is_a?(String) && !outcome.decided?
        [outcome.decision, outcome.by] if outcome.decided?
      end

      def unasked(abstained, decision)
        fallback = (decision.reason if decision.respond_to?(:reason))
        abstained.empty? ? fallback : Unasked.new(explains: abstained, fallback:)
      end
    end
  end
end
