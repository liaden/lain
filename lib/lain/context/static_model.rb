# frozen_string_literal: true

module Lain
  class Context
    # The model in force for a Context that never switches: a tiny frozen value
    # over an interned String, the immutable sibling of {ModelSwitch}. Both
    # answer `#current`, so {Context#render} reads the live model through one
    # message regardless of which it holds -- no per-render `respond_to?` probe.
    #
    # Unlike {ModelSwitch} there is no mutable coordination state here: a
    # StaticModel is frozen at construction, so a Context wrapping one stays
    # `Ractor.shareable?` and renders byte-identically to the old bare-String
    # path (the wrapped value is the SAME interned String that path produced).
    class StaticModel
      attr_reader :current

      # @param model [#to_s] the fixed model id, interned like every model the
      #   Context hands a Request
      def initialize(model)
        @current = -model.to_s
        freeze
      end

      def to_s = current
    end
  end
end
