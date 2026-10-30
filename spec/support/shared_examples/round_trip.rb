# frozen_string_literal: true

# The law a renderer and its parser hold together: `parse(render(x)) == x`. One
# law, so a pair that drops or reshapes a field anywhere on the way out and back
# fails it, and the battery lets a spec show a pair that is NOT one.
#
# Include with a Hash, built at the `include_examples` site:
#
#   render      [#call(value) -> bytes]   the writing half
#   parse       [#call(bytes) -> value]   the reading half
#   population  [#call -> Array]          the values to judge, drawn once
#   generator   [PropCheck::Generator]    instead of a population: sampled
#   samples     [Integer]                 draws taken from the generator; defaults to 50
#   equal       [#call(a, b) -> bool]     defaults to `==`
#
# The population is drawn inside the examples, so a constructor that raises fails one example
# naming it rather than the file's load. Under a strict parse a lossy pair surfaces as the
# parse's exception, not as `:fails`; read it leniently to see the law fail.
module AlgebraLaws
  ROUND_TRIP_LAW = "parses what it renders back to an equal value"

  RoundTrip = Data.define(:render, :parse, :values, :same) do
    def self.from(config)
      new(render: config.fetch(:render), parse: config.fetch(:parse), values: drawn(config),
          same: config.fetch(:equal, ->(a, b) { a == b }))
    end

    def self.drawn(config)
      return config.fetch(:population).call if config.key?(:population)

      config.fetch(:generator).sample(config.fetch(:samples, 50))
    end

    def to_h = { ROUND_TRIP_LAW => method(:returns?) }

    def returns? = values.all? { |value| returned?(value) }

    # The first value the law breaks on, so a failure names it rather than only counting.
    def witness = values.find { |value| !returned?(value) }

    def returned?(value) = same.call(parse.call(render.call(value)), value)
  end
end

RSpec.shared_examples "a round trip" do |config|
  define_method(:battery) { @battery ||= AlgebraLaws::RoundTrip.from(config) }

  it(AlgebraLaws::ROUND_TRIP_LAW) do
    expect(battery.returns?).to be(true), -> { "breaks on #{battery.witness.inspect[0, 400]}" }
  end

  context "when reading that law over these values" do
    it "includes at least one" do
      expect(battery.values).not_to be_empty
    end
  end
end
