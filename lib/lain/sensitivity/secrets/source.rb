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
        # @param context [#worker_env, nil] the call whose worker's own environment is added
        # @return [Array<String>] every value the masker knows for that call
        def for(context) = Secrets.for(child_env:, context:, history:)

        # @return [Array<String>] every value the masker knows, with no call's worker
        def to_a = self.for(nil)

        # @param released [Set<String>] region digests a human released
        # @return [Egress] the same values, split into those refused from
        #   leaving the machine and those only flagged
        def egress(released: Set.new) = Egress.of(child_env:, history:, released:)
      end

      class Source
        DEFAULT = new(child_env: Exec::ChildEnv::DEFAULT, history: HistoryLiterals::Null)
      end
    end
  end
end
