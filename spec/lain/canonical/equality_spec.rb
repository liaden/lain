# frozen_string_literal: true

RSpec.describe Lain::Canonical::Equality do
  describe ".same?" do
    {
      "an Integer and the equal Float" => [1, 1.0],
      "0.0 and -0.0" => [0.0, -0.0],
      "2**53 and the Float that == it" => [2**53, 9_007_199_254_740_992.0],
      "nested Hashes differing deep in a Float" => [{ "a" => [{ "n" => 1 }] }, { "a" => [{ "n" => 1.0 }] }],
      "nested Arrays differing in a zero's sign" => [[[0.0]], [[-0.0]]],
      "Hashes with the same pairs in another order" => [{ "a" => 1, "b" => 2 }, { "b" => 2, "a" => 1 }],
      "Arrays of different lengths" => [[1], [1, nil]]
    }.each do |name, (one, other)|
      it "tells apart #{name}, which == does not always" do
        expect([described_class.same?(one, other), described_class.same?(other, one)]).to eq([false, false])
      end
    end

    it "holds 2 values that dump to the same bytes the same, nested Hash and Array included" do
      one = { "a" => [1, 2.5, -0.0, nil, true, "x", { "b" => [] }] }
      other = JSON.parse(JSON.generate(one))

      expect(described_class.same?(one, other)).to be(true)
      expect(Lain::Canonical.dump(one)).to eq(Lain::Canonical.dump(other))
    end

    it "holds an object the same as itself" do
      value = { "a" => [1.0] }

      expect(described_class.same?(value, value)).to be(true)
    end
  end
end
