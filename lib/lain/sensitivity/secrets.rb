# frozen_string_literal: true

module Lain
  class Sensitivity
    # The one secret set a command's output is masked for, read per call
    # because a call's context lends its own environment. The live display
    # and the model's copy both ask here, so the 2 copies of one output are
    # masked for the same values.
    module Secrets
      # @param child_env [Exec::ChildEnv] the launch's child environment
      # @param context [#worker_env, nil] the call's context; nil reads as {Session::Null}
      # @return [Array<String>] the values to mask, as {Literals#to_a} lists them
      def self.for(child_env:, context:)
        lent = (context || Session::Null.instance).worker_env.env
        Literals.new(child_env:, lent:).to_a
      end
    end
  end
end
