# frozen_string_literal: true

module Lain
  module Telemetry
    # One request counted past its model's prompt-size price tier, and what
    # became of it: `:approve` or `:deny` from the human, `:allow` or `:refuse`
    # when the run's mode or an unattended hold answered without asking.
    # Journaled once per distinct body, so a retried request adds no second
    # record. The costs are the prompt alone at each rate, as fixed-point
    # dollar Strings ({Telemetry.fixed_point}).
    PriceTierCrossed = Data.define(:model, :prompt_tokens, :boundary, :standard_cost, :tier_cost, :decision) do
      include Journalable

      def initialize(model:, prompt_tokens:, boundary:, standard_cost:, tier_cost:, decision:)
        super(model: -model.to_s, prompt_tokens: Integer(prompt_tokens), boundary: Integer(boundary),
              standard_cost: Telemetry.fixed_point(standard_cost), tier_cost: Telemetry.fixed_point(tier_cost),
              decision: decision.to_sym)
      end
    end
  end
end
