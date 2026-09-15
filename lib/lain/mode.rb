# frozen_string_literal: true

module Lain
  # A session's mode: a SCOPE (where writes and commands land) times an
  # APPROVAL level (who decides a gated call), plus any number of orthogonal
  # layers -- Emacs' major/minor split, keeping Vim's mutual exclusion for the
  # one job it earns: the same token must have exactly one interpretation. Each
  # exclusive axis holds one value; a layer is everything that does not need one.
  #
  # == Mode is a class, not a namespace
  #
  # `Mode` doubles as this subtree's require index AND as the value itself.
  # `Data.define` answers a class, so re-pointing the constant at one would
  # silently drop `Mode::Scope`, `Mode::Approval` and `Mode::Layer` with nothing
  # louder than a redefinition warning -- which is why the children say
  # `class Mode` rather than `module Mode`, the latter being a hard `TypeError`
  # at load against a class.
  Mode = Data.define(:scope, :approval, :layers) do
    # Every axis defaults to where a session starts, so `Mode.new` IS the
    # starting mode and the reset.
    #
    # @param scope [Mode::Scope, Symbol, String] a declared scope, or its name
    # @param approval [Mode::Approval, Symbol, String] a declared level, or its name
    # @param layers [Mode::LayerSet, Array<Symbol, String>] the active layer set,
    #   or names to build one from
    # @raise [ArgumentError] on an undeclared name OR on an argument that is not
    #   even name/Array-shaped -- guarded here so garbage of the WRONG TYPE fails
    #   exactly as loudly as garbage of the wrong NAME, instead of leaking
    #   whichever private method (`to_sym`, `map`) this coercion calls first
    def initialize(scope: :checkout, approval: :ask, layers: Mode::LayerSet.empty)
      super(scope: coerce(Mode::Scope, scope, "mode scope"),
            approval: coerce(Mode::Approval, approval, "approval"),
            layers: coerce_layers(layers))
    end

    # Emacs' `C-h m`: the scope and the approval level, then every active layer
    # in PRECEDENCE order (declaration order -- see {LayerSet}) with its
    # lighter. The layered model's known cost is "why did that happen" and this
    # is the payment, so nothing here may summarize or drop a layer silently.
    #
    # @return [String]
    def describe
      "#{label(scope)} #{label(approval)}: #{layer_description}"
    end

    private

    # `respond_to?(:to_sym)` before delegating: `.for`'s own "unknown" message
    # is only reachable once `.to_sym` has succeeded, so anything that cannot
    # even offer a name (`nil`, an Integer, an Array) is turned away here.
    def coerce(family, value, noun)
      return value if value.is_a?(family)
      unless value.respond_to?(:to_sym)
        raise ArgumentError, "unknown #{noun} #{value.inspect}, expected one of #{family::NAMES.inspect}"
      end

      family.for(value)
    end

    # `is_a?(Array)` rather than the broader `respond_to?(:each)`: every call
    # site passes an Array, and widening to any Enumerable would let a Hash or a
    # Range past to fail inside {LayerSet} instead of here.
    def coerce_layers(layers)
      return layers if layers.is_a?(Mode::LayerSet)
      unless layers.is_a?(Array)
        raise ArgumentError,
              "unknown mode layers #{layers.inspect}, expected an Array of #{Mode::Layer::NAMES.inspect}"
      end

      Mode::LayerSet.new(layers)
    end

    # Mirrors {Layer#to_s}: an axis value is not a layer and has no `#to_s` of
    # its own.
    def label(axis) = axis.lighter.empty? ? axis.name.to_s : "#{axis.name} (#{axis.lighter})"

    def layer_description
      return "no layers active" if layers.empty?

      layers.layers.join(", ")
    end
  end
end

require_relative "mode/layer"
require_relative "mode/scope"
require_relative "mode/approval"
require_relative "mode/switch"
require_relative "mode/resolution"
