# frozen_string_literal: true

module Lain
  module CLI
    Arms = Data.define(:confine, :judge_facts, :tripwire, :round_budget, :round_dedup)

    # The bench arms a run is started with, parsed from the chat flags once so
    # every consumer reads one answer. The reader sandbox and the observe-only
    # tripwire are on unless a flag turns them off: neither refuses a call the
    # ladder would allow, and the sandbox degrades loudly where the kernel lacks
    # a layer. Judge facts stay off because they change what the judge decides.
    # The round budget is on: it withholds only what a round's results could not
    # fit in the window anyway. Dedup is on too, and is its own arm so that a
    # budget of off is only the absence of a limit.
    class Arms
      # A flag value outside an arm's set, loud and naming the allowed values. It
      # subclasses {Lain::Error} so the exe maps it to a clean Thor::Error.
      class Unknown < Error; end

      CONFINE = %i[off classes reader].freeze
      JUDGE_FACTS = %i[off facts request].freeze
      TRIPWIRE = %i[off observe].freeze
      ROUND_BUDGET = %i[off static window].freeze
      ROUND_DEDUP = %i[off on].freeze
      # Each arm's values, weakest first. round_budget is really a partial order (off is above both
      # static and window, which are incomparable), but its list only has to rank each below window.
      SETS = { confine: CONFINE, judge_facts: JUDGE_FACTS, tripwire: TRIPWIRE, round_budget: ROUND_BUDGET,
               round_dedup: ROUND_DEDUP }.freeze

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
      # @return [Arms]
      # @raise [Unknown] on a value outside an arm's set
      def self.from(options, over = DEFAULT) = resolve(options, over) { |arm| "unknown #{flag(arm)} value" }

      # An arm the header left out was off, because {#to_header} writes only
      # the arms that are on, except round_dedup, which it always writes; a
      # header older than the arms reads as every arm off.
      # The exception is round_dedup: a budget deduplicated before the arm
      # existed, so a header with a budget and no round_dedup key ran with it on.
      #
      # @param header [Hash] a session header record
      # @return [Arms]
      # @raise [Unknown] on a recorded value outside an arm's set
      def self.from_header(header)
        recorded = (header["arms"] || {}).transform_keys(&:to_sym)
        arms = resolve(recorded, OFF) { |arm| "the session header records #{arm}" }
        recorded.key?(:round_dedup) || arms.round_budget == :off ? arms : arms.with(round_dedup: :on)
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

      OFF = new(confine: :off, judge_facts: :off, tripwire: :off, round_budget: :off, round_dedup: :off)
      DEFAULT = new(confine: :reader, judge_facts: :off, tripwire: :observe, round_budget: :window, round_dedup: :on)
      # No arm typed: laid under the flags, it keeps only what the human typed.
      UNSET = new(confine: nil, judge_facts: nil, tripwire: nil, round_budget: nil, round_dedup: nil)
    end
  end
end
