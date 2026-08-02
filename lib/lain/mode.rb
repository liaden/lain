# frozen_string_literal: true

module Lain
  # One exclusive posture governing how the agent's output is interpreted, plus
  # any number of orthogonal layers -- Emacs' major/minor split, keeping Vim's
  # mutual exclusion for the one job it earns: the same token must have exactly
  # one interpretation.
  #
  # == Mode is a class, not a namespace
  #
  # `Mode` doubles as this subtree's require index (`mode/posture.rb` and
  # `mode/layer.rb` both reopen it) AND as the value itself, which forces a
  # choice: `Data.define` answers a class, and re-pointing the `Mode` constant
  # at one would silently drop `Mode::Posture` and `Mode::Layer` with nothing
  # louder than a redefinition warning -- UNLESS both children stop saying
  # `module Mode` and say `class Mode` instead, since `module Mode` against a
  # class is a hard `TypeError` at load. Both were changed here, together, in
  # this commit, and nothing else in either file moved.
  #
  # The alternative -- leave `Mode` a bare namespace and name the value
  # `Mode::Current` -- was rejected. Every Gherkin scenario and every future
  # caller reaches for `Mode.new(posture:, layers:)`, and {Role} already sets
  # the precedent this follows: a `Data`-defined value that is also the file's
  # require anchor for a nested family (`Role::Catalog`).
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

    # Emacs' `C-h m`: the posture this session is in, then every active layer
    # in PRECEDENCE order (declaration order -- see {LayerSet}), each with its
    # lighter. The layered model's known cost is "why did that happen"; this
    # is the payment, so nothing here may summarize or drop a layer silently.
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

    # `is_a?(Array)` rather than the broader `respond_to?(:each)`: every
    # declared call site (this card's Gherkin, {Mode::LayerSet}'s own default)
    # passes an Array, and widening the guard to any Enumerable would let a
    # Hash or a Range past it to fail inside {LayerSet} instead of here.
    def coerce_layers(layers)
      return layers if layers.is_a?(Mode::LayerSet)
      unless layers.is_a?(Array)
        raise ArgumentError,
              "unknown mode layers #{layers.inspect}, expected an Array of #{Mode::Layer::NAMES.inspect}"
      end

      Mode::LayerSet.new(layers)
    end

    # Mirrors {Layer#to_s} rather than calling it -- a posture is not a layer,
    # it has no `#to_s` of its own, and giving it one for this single caller
    # would be a change to {Posture}'s behaviour this card does not own.
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
