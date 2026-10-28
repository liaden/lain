# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `carried` is a crossing sent unasked because the human approved the model's tier earlier.
      class PriceTierCrossed < Declarative::Carrier
        attribute :model, :lain_interned
        attribute :prompt_tokens
        attribute :boundary
        attribute :standard_cost, :lain_fixed_point
        attribute :tier_cost, :lain_fixed_point
        attribute :decision
        validates :decision, inclusion: { in: %i[approve deny allow refuse carried],
                                          message: "must be approve/deny/allow/refuse/carried, got %<value>s" }
      end
    end

    # One request counted past its model's prompt-size price tier, and what
    # became of it: `:approve` or `:deny` from the human, `:allow` or `:refuse`
    # when the run's mode or an unattended hold answered without asking.
    # Journaled once per distinct body, so a retried request adds no second
    # record. The costs are the prompt alone at each rate, as fixed-point
    # dollar Strings.
    PriceTierCrossed = Data.define(:model, :prompt_tokens, :boundary, :standard_cost, :tier_cost, :decision) do
      include Journalable

      def initialize(model:, prompt_tokens:, boundary:, standard_cost:, tier_cost:, decision:)
        super(**Carriers::PriceTierCrossed.settle!(model:, prompt_tokens: Integer(prompt_tokens),
                                                   boundary: Integer(boundary), standard_cost:, tier_cost:,
                                                   decision: decision.to_sym))
      end
    end
  end
end
