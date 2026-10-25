# frozen_string_literal: true

module Lain
  module Telemetry
    # The reply that carried a run past its dollar ceiling, and by how much.
    # The ceiling is checked only once a reply's price is known, so spend always
    # lands past it; this is the measure of how far. Figures are fixed-point
    # dollar Strings ({Telemetry.fixed_point}).
    #
    # @!attribute [r] ceiling
    #   @return [String] the dollar ceiling
    # @!attribute [r] spent
    #   @return [String] the priced spend, which is above the ceiling
    # @!attribute [r] overshoot
    #   @return [String] spend less ceiling
    # @!attribute [r] model
    #   @return [String] the model that answered
    # @!attribute [r] complete
    #   @return [Boolean] false when unpriced turns are missing from the spend,
    #     so the true overshoot is at least this
    BudgetOvershoot = Data.define(:ceiling, :spent, :overshoot, :model, :complete) do
      include Journalable

      # Journals the overshoot, if any, and then lets the ceiling refuse.
      # Ordered so the record lands before the raise unwinds the turn.
      #
      # @param ceilings [Budget::Ceilings]
      # @param spent [Budget::Spent]
      # @param journal [#<<] where the record lands
      # @param model [String] the model that answered
      # @raise [Lain::Budget::Exceeded] when the priced spend has passed the dollar ceiling
      def self.check!(ceilings, spent, journal:, model:)
        ceiling = ceilings.dollars
        amount = spent.dollars.amount
        if ceiling && amount > ceiling
          journal << new(ceiling:, spent: amount, overshoot: amount - ceiling, model:,
                         complete: spent.dollars.complete?)
        end
        ceilings.check_dollars!(spent)
      end

      def initialize(ceiling:, spent:, overshoot:, model:, complete:)
        super(ceiling: Telemetry.fixed_point(ceiling), spent: Telemetry.fixed_point(spent),
              overshoot: Telemetry.fixed_point(overshoot), model: -model.to_s, complete: complete ? true : false)
      end
    end
  end
end
