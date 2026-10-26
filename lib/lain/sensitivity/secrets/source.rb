# frozen_string_literal: true

module Lain
  class Sensitivity
    module Secrets
      # A process's own secret values, read per call, so a value committed or
      # written to an ignored file after the source was built is still known.
      # The gateway and the egress guard both read one.
      #
      # @!attribute [r] child_env
      #   @return [Exec::ChildEnv] the environment a child would inherit
      # @!attribute [r] history
      #   @return [#to_a, #refusable] see {HistoryLiterals}
      Source = Data.define(:child_env, :history) do
        # @return [Array<String>] every value the masker knows
        def to_a = Secrets.for(child_env:, context: nil, history:)

        # @return [Egress] the same values, split into those refused from
        #   leaving the machine and those only flagged
        def egress = Egress.of(child_env:, history:)
      end
    end
  end
end
