# frozen_string_literal: true

module Lain
  module CLI
    Arms = Data.define(:confine, :judge_facts, :tripwire, :round_budget)

    # The bench arms a run is started with, parsed from the chat flags once so
    # every consumer reads one answer. The reader sandbox and the observe-only
    # tripwire are on unless a flag turns them off: neither refuses a call the
    # ladder would allow, and the sandbox degrades loudly where the kernel lacks
    # a layer. Judge facts stay off because they change what the judge decides.
    # The round budget is on: it withholds only what a round's results could not
    # fit in the window anyway.
    class Arms
      # A flag value outside an arm's set, loud and naming the allowed values. It
      # subclasses {Lain::Error} so the exe maps it to a clean Thor::Error.
      class Unknown < Error; end

      CONFINE = %i[off classes reader].freeze
      JUDGE_FACTS = %i[off facts request].freeze
      TRIPWIRE = %i[off observe].freeze
      ROUND_BUDGET = %i[off static window].freeze
      # Each arm's values, weakest first.
      SETS = { confine: CONFINE, judge_facts: JUDGE_FACTS, tripwire: TRIPWIRE, round_budget: ROUND_BUDGET }.freeze

      # @param options [Hash] the parsed chat flags; an unset arm takes its value from `over`
      # @param over [Arms] what an unset arm runs: the launch defaults, a
      #   resumed session's recorded arms, or {UNSET} to keep only what was
      #   typed. Positional, because callers pass the flags as a braceless
      #   hash, which Ruby would read as keywords.
      # @option options [String, nil] :confine one of {CONFINE}
      # @option options [String, nil] :judge_facts one of {JUDGE_FACTS}
      # @option options [String, nil] :tripwire one of {TRIPWIRE}
      # @option options [String, nil] :round_budget one of {ROUND_BUDGET}
      # @return [Arms]
      # @raise [Unknown] on a value outside an arm's set
      def self.from(options, over = DEFAULT) = resolve(options, over) { |arm| "unknown #{flag(arm)} value" }

      # An arm the header left out was off, because {#to_header} writes only
      # the arms that are on; a header older than the arms reads as every arm off.
      #
      # @param header [Hash] a session header record
      # @return [Arms]
      # @raise [Unknown] on a recorded value outside an arm's set
      def self.from_header(header)
        resolve(header.fetch("arms", {}).transform_keys(&:to_sym), OFF) { |arm| "the session header records #{arm}" }
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

      # @return [Hash{String=>String}] the arms that are on; empty when none is,
      #   so a run with every arm off writes a header byte-identical to one
      #   written before the arms existed. An unset arm is dropped too, so a
      #   typed-only view ({UNSET} laid under the flags) cannot write an empty value.
      def to_header
        to_h.reject { |_, value| value.nil? || value == :off }.to_h { |arm, value| [arm.to_s, value.to_s] }
      end

      # @return [Tool::RoundBudget] the policy an Agent holds for this arm
      def round_budget_policy
        case round_budget
        when :window then Tool::RoundBudget.window
        when :static then Tool::RoundBudget.static
        else Tool::RoundBudget::NONE
        end
      end

      # @param other [Arms]
      # @return [Array<Symbol>] the arms set weaker here than in `other`
      def weaker_than(other)
        SETS.select { |arm, set| set.index(public_send(arm)) < set.index(other.public_send(arm)) }.keys
      end

      OFF = new(confine: :off, judge_facts: :off, tripwire: :off, round_budget: :off)
      DEFAULT = new(confine: :reader, judge_facts: :off, tripwire: :observe, round_budget: :window)
      # No arm typed: laid under the flags, it keeps only what the human typed.
      UNSET = new(confine: nil, judge_facts: nil, tripwire: nil, round_budget: nil)
    end
  end
end
