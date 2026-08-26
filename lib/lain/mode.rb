# frozen_string_literal: true

module Lain
  # One exclusive posture governing how the agent's output is interpreted, plus
  # any number of orthogonal layers -- Emacs' major/minor split, keeping Vim's
  # mutual exclusion for the one job it earns: the same token must have exactly
  # one interpretation.
  #
  # == Mode is a class, not a namespace
  #
  # `Mode` doubles as this subtree's require index AND as the value itself.
  # `Data.define` answers a class, so re-pointing the constant at one would
  # silently drop `Mode::Posture` and `Mode::Layer` with nothing louder than a
  # redefinition warning -- which is why both children say `class Mode` rather
  # than `module Mode`, the latter being a hard `TypeError` at load against a
  # class.
  #
  # Leaving `Mode` a bare namespace and naming the value `Mode::Current` was
  # rejected: every caller reaches for `Mode.new(posture:, layers:)`, and {Role}
  # sets the precedent -- a `Data`-defined value that is also the require anchor
  # for a nested family (`Role::Catalog`).
  Mode = Data.define(:posture, :layers) do
    # @param posture [Mode::Posture, Symbol, String] a declared posture, or its name
    # @param layers [Mode::LayerSet, Array<Symbol, String>] the active layer set,
    #   or names to build one from
    # @raise [ArgumentError] on an undeclared name (through {Posture.for} or
    #   {LayerSet#initialize}) OR on a posture/layers argument that is not even
    #   name/Array-shaped -- guarded here so garbage of the WRONG TYPE fails
    #   exactly as loudly as garbage of the wrong NAME, instead of leaking
    #   whichever private method ({Posture.for}'s `to_sym`, {LayerSet}'s `map`)
    #   this coercion happens to call first
    def initialize(posture:, layers: Mode::LayerSet.empty)
      super(posture: coerce_posture(posture), layers: coerce_layers(layers))
    end

    # Emacs' `C-h m`: the posture, then every active layer in PRECEDENCE order
    # (declaration order -- see {LayerSet}) with its lighter. The layered model's
    # known cost is "why did that happen" and this is the payment, so nothing
    # here may summarize or drop a layer silently.
    #
    # @return [String]
    def describe
      "#{posture_label}: #{layer_description}"
    end

    private

    # `respond_to?(:to_sym)` before delegating, rather than delegating and
    # rescuing -- {Posture.for}'s OWN "unknown posture" message is only
    # reachable once `.to_sym` has already succeeded, so anything that cannot
    # even offer a name (`nil`, an Integer, an Array) has to be turned away
    # here or it never reaches that message at all.
    def coerce_posture(posture)
      return posture if posture.is_a?(Mode::Posture)
      unless posture.respond_to?(:to_sym)
        raise ArgumentError,
              "unknown posture #{posture.inspect}, expected one of #{Mode::Posture::NAMES.inspect}"
      end

      Mode::Posture.for(posture)
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

    # Mirrors {Layer#to_s} rather than calling it: a posture is not a layer and
    # has no `#to_s`, and minting one for this single caller would change
    # {Posture}'s behaviour for everyone.
    def posture_label
      posture.lighter.empty? ? posture.name.to_s : "#{posture.name} (#{posture.lighter})"
    end

    def layer_description
      return "no layers active" if layers.empty?

      layers.layers.join(", ")
    end
  end
end

require_relative "mode/layer"
require_relative "mode/posture"
require_relative "mode/switch"
require_relative "mode/resolution"
