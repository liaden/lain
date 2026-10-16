# frozen_string_literal: true

module Lain
  module CLI
    Arms = Data.define(:confine, :judge_facts, :tripwire)

    # The bench arms a run is started with, parsed from the chat flags once so
    # every consumer reads one answer. Every default is `off`: an arm is a
    # switch an operator turns on, never a behaviour a run inherits.
    class Arms
      # A flag value outside an arm's set, loud and naming the allowed values. It
      # subclasses {Lain::Error} so the exe maps it to a clean Thor::Error.
      class Unknown < Error; end

      CONFINE = %i[off classes reader].freeze
      JUDGE_FACTS = %i[off facts request].freeze
      TRIPWIRE = %i[off observe].freeze

      # @param options [Hash] the parsed chat flags; an unset arm is off
      # @option options [String, nil] :confine one of {CONFINE}
      # @option options [String, nil] :judge_facts one of {JUDGE_FACTS}
      # @option options [String, nil] :tripwire one of {TRIPWIRE}
      # @return [Arms]
      # @raise [Unknown] on a value outside an arm's set
      def self.from(options)
        new(confine: pick(options[:confine], CONFINE, "--confine"),
            judge_facts: pick(options[:judge_facts], JUDGE_FACTS, "--judge-facts"),
            tripwire: pick(options[:tripwire], TRIPWIRE, "--tripwire"))
      end

      def self.pick(value, allowed, flag)
        return :off if value.nil?
        return value.to_sym if allowed.map(&:to_s).include?(value.to_s)

        raise Unknown, "unknown #{flag} value #{value.to_s.inspect}, expected one of #{allowed.join(", ")}"
      end
      private_class_method :pick

      # @return [Hash{String=>String}] the arms that are on; empty when none is,
      #   so a run with every arm off writes a header byte-identical to one
      #   written before the arms existed
      def to_header = to_h.reject { |_, value| value == :off }.to_h { |arm, value| [arm.to_s, value.to_s] }

      OFF = new(confine: :off, judge_facts: :off, tripwire: :off)
    end
  end
end
