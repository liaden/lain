# frozen_string_literal: true

RSpec.describe Lain::Listed do
  describe ".comma" do
    it "splits, strips and drops empties, frozen" do
      listed = described_class.comma("a, b,,c ")

      expect(listed).to eq(%w[a b c])
      expect(listed).to be_frozen
    end

    it "answers an empty list for nil and for a blank string" do
      expect([described_class.comma(nil), described_class.comma(" , ")]).to eq([[], []])
    end
  end
end
