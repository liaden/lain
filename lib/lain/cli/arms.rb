# frozen_string_literal: true

module Lain
  module CLI
    Arms = Data.define(:confine, :judge_facts, :tripwire, :round_budget, :round_dedup, :judge_denials)

    # The bench arms a run is started with, parsed from the chat flags once so
    # every consumer reads one answer. The workspace sandbox and the observe-only
    # tripwire are on unless a flag turns them off: neither refuses a call the
    # ladder would allow, and the sandbox degrades loudly where the kernel lacks
    # a layer. Judge facts stay off because they change what the judge decides.
    # The round budget is on: it withholds only what a round's results could not
    # fit in the window anyway. Dedup is on too, and is its own arm so that a
    # budget of off is only the absence of a limit. Judge denials stay off: both
    # other values change who answers a call the judge refused.
    class Arms
      # A flag value outside an arm's set, loud and naming the allowed values. It
      # subclasses {Lain::Error} so the exe maps it to a clean Thor::Error.
      class Unknown < Error; end

      CONFINE = %i[off classes reader workspace].freeze
      # The confine arms that put bash in a sandbox; the others leave it to the approval ladder.
      SANDBOXED = %i[reader workspace].freeze
      JUDGE_FACTS = %i[off facts request].freeze
      TRIPWIRE = %i[off observe stop].freeze
      ROUND_BUDGET = %i[off static window].freeze
      ROUND_DEDUP = %i[off on].freeze
      JUDGE_DENIALS = %i[off escalate_only breaker].freeze
      # Each arm's values, weakest first. round_budget is really a partial order (off is above both
      # static and window, which are incomparable), but its list only has to rank each below window.
      SETS = { confine: CONFINE, judge_facts: JUDGE_FACTS, tripwire: TRIPWIRE, round_budget: ROUND_BUDGET,
               round_dedup: ROUND_DEDUP, judge_denials: JUDGE_DENIALS }.freeze

      # @param options [Hash] the parsed chat flags; an unset arm takes its value from `over`
      # @param over [Arms] what an unset arm runs: the launch defaults, a
      #   resumed session's recorded arms, or {UNSET} to keep only what was
      #   typed. Positional, because callers pass the flags as a braceless
      #   hash, which Ruby would read as keywords.
      # @option options [String, nil] :confine one of {CONFINE}
      # @option options [String, nil] :judge_facts one of {JUDGE_FACTS}
      # @option options [String, nil] :tripwire one of {TRIPWIRE}
      # @option options [String, nil] :round_budget one of {ROUND_BUDGET}
      # @option options [String, nil] :round_dedup one of {ROUND_DEDUP}
      # @option options [String, nil] :judge_denials one of {JUDGE_DENIALS}
      # @return [Arms]
      # @raise [Unknown] on a value outside an arm's set
      def self.from(options, over = DEFAULT) = resolve(options, over) { |arm| "unknown #{flag(arm)} value" }

      # An arm the header left out was off, because {#to_header} writes only
      # the arms that are on, except round_dedup, which it always writes; a
      # header older than the arms reads as every arm off.
      #
      # @param header [Hash] a session header record
      # @return [Arms]
      # @raise [Unknown] on a recorded value outside an arm's set
      def self.from_header(header)
        recorded = (header["arms"] || {}).transform_keys(&:to_sym)
        resolve(recorded, OFF) { |arm| "the session header records #{arm}" }
      end

      # @param arm [Symbol] one of {SETS}' keys
      # @return [String] the chat flag that sets it
      def self.flag(arm) = "--#{arm.to_s.tr("_", "-")}"

      def self.resolve(values, over)
        new(**SETS.to_h { |arm, allowed| [arm, pick(values[arm], allowed, over.public_send(arm)) { yield arm }] })
      end
      private_class_method :resolve

      def self.pick(value, allowed, default)
        return default if value.nil?
        return value.to_sym if allowed.map(&:to_s).include?(value.to_s)

        raise Unknown, "#{yield} #{value.to_s.inspect}, expected one of #{allowed.join(", ")}"
      end
      private_class_method :pick

      # @return [Hash{String=>String}] the arms that are on, and round_dedup either
      #   way: its absence reads as on under a budget, so an off must be written.
      #   An unset arm is dropped, so a typed-only view ({UNSET} laid under the
      #   flags) cannot write an empty value.
      def to_header
        to_h.reject { |arm, value| value.nil? || (value == :off && arm != :round_dedup) }
            .to_h { |arm, value| [arm.to_s, value.to_s] }
      end

      # @return [Tool::RoundBudget] the policy an Agent holds for this arm
      def round_budget_policy
        case round_budget
        when :window then with_dedup(Tool::RoundBudget.window)
        when :static then with_dedup(Tool::RoundBudget.static)
        else round_dedup == :on ? Tool::RoundBudget.dedup_only : Tool::RoundBudget::NONE
        end
      end

      # @return [Array<Symbol>] the arms set weaker than the launch default
      def differs_from_default
        SETS.select { |arm, set| set.index(public_send(arm)) < set.index(DEFAULT.public_send(arm)) }.keys
      end

      def with_dedup(policy) = round_dedup == :on ? policy : policy.without_dedup
      private :with_dedup

      # @return [Boolean] whether bash runs in a sandbox
      def sandboxed? = SANDBOXED.include?(confine)

      # @return [Boolean] whether a gate-approved call runs in the workspace profile
      def workspace? = confine == :workspace

      # @return [Boolean] whether approval uses the command classes; an unset arm reads as off
      def classes? = !confine.nil? && confine != :off

      # @return [Boolean] whether a tripped wire stops the run
      def tripwire_stops? = tripwire == :stop

      # @return [Boolean] whether no ledger watches the journal; an unset arm reads as off
      def tripwire_off? = tripwire.nil? || tripwire == :off

      # @return [Boolean] whether the judge is given facts
      def judge_facts? = !judge_facts.nil? && judge_facts != :off

      # @return [Boolean] whether the judge may ask for more
      def judge_requests? = judge_facts == :request

      OFF = new(**SETS.transform_values { :off })
      DEFAULT = new(confine: :workspace, judge_facts: :off, tripwire: :observe, round_budget: :window, round_dedup: :on,
                    judge_denials: :off)
      # No arm typed: laid under the flags, it keeps only what the human typed.
      UNSET = new(**SETS.transform_values { nil })
    end
  end
end
