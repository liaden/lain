# frozen_string_literal: true

module Lain
  module CLI
    Human = Data.define(:kind)

    # Who answers this run, read once from the launch options. Readers ask it
    # a question rather than comparing kinds, so a new kind changes the answers
    # here and nowhere else.
    #
    # @!attribute [r] kind
    #   @return [Symbol] one of {KINDS}
    class Human
      KINDS = %i[terminal remote none].freeze

      # A headless run with `--human remote` is answered from the phone. The flag
      # without `--non-interactive` is refused at launch, so it reads as terminal here.
      #
      # @param options [Hash] the launch options
      # @option options [Boolean] :non_interactive nobody is attached to this run's terminal
      # @option options [String, nil] :human "remote" when a phone answers a headless run
      # @return [Human]
      def self.from(options)
        return new(kind: :terminal) unless options[:non_interactive]

        new(kind: options[:human] == "remote" ? :remote : :none)
      end

      # @param kind [Symbol] one of {KINDS}
      # @raise [ArgumentError] for any other kind
      def initialize(kind:)
        unless KINDS.include?(kind)
          raise ArgumentError, "unknown human kind #{kind.inspect}; expected one of #{KINDS.inspect}"
        end

        super
      end

      # @return [Boolean] whether someone types and reads at this run's own terminal
      def answers_at_terminal? = kind == :terminal

      # @return [Boolean] whether a question or a parked call can reach anyone
      def can_be_asked? = kind != :none

      # @return [Boolean] whether a gated call must be refused because nobody can decide it
      def ladder_refuses? = kind == :none

      # Outside the sandbox only what a human approved runs, traced: any other
      # call could pair itself as a phone or reach the relay and approve its own run.
      #
      # @return [Boolean] whether the phone answers, so bash runs confined unless a human approved it
      def answers_remotely? = kind == :remote
    end
  end
end
