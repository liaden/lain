# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Secrets::Egress do
  describe ".of" do
    let(:keys) do
      %w[kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3
         qW3eR7tY1uI5oP9aS2dF6gH0jK4lZ8xC3vB7nM1qW5eR9tY2
         zX9cV5bN1mA7sD3fG8hJ4kL0qW6eR2tY5uI9oP3aS7dF1gH4]
    end
    let(:child_env) do
      Lain::Exec::ChildEnv.new(env: keys.each_with_index.to_h { |key, i| ["SLOT_#{i}_SECRET", "/#{key}"] })
    end

    it "detects the regions of each value once per build" do
      allow(Lain::Sensitivity::Regions).to receive(:detect).and_call_original

      egress = described_class.of(child_env:, history: Lain::Sensitivity::HistoryLiterals::Null,
                                  released: Set["a" * 64, "b" * 64], lent: {})

      expect(egress.refused).to match_array(keys.map { "/#{_1}".b })
      expect(Lain::Sensitivity::Regions).to have_received(:detect).exactly(3).times
    end
  end
end
