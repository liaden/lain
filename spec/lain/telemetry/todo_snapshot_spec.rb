# frozen_string_literal: true

RSpec.describe Lain::Telemetry::TodoSnapshot do
  describe ".writable_head?" do
    it "accepts a digest or no head, and nothing else" do
      expect([nil, "blake3:a", 7, :a, ["a"]].map { |head| described_class.writable_head?(head) })
        .to eq([true, true, false, false, false])
    end
  end
end
