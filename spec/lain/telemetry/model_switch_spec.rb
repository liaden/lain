# frozen_string_literal: true

RSpec.describe Lain::Telemetry::ModelSwitch do
  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(from: "qwen3:4b",
                                   to: "lfm2.5:latest",
                                   surface: "nvim")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"model_switch","from":"qwen3:4b","to":"lfm2.5:latest","surface":"nvim"}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        from: "qwen3:4b",
        to: "lfm2.5:latest",
        surface: "nvim"
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing from, naming it" do
      given = {
        from: "qwen3:4b",
        to: "lfm2.5:latest",
        surface: "nvim"
      }
      expect { described_class.new(**given.except(:from)) }.to raise_error(ArgumentError, /from/)
    end

    it "interns from" do
      first = described_class.new(from: +"v", to: "b", surface: "s")
      second = described_class.new(from: +"v", to: "b", surface: "s")
      expect(first.from).to equal(second.from)
    end

    it "interns to" do
      first = described_class.new(from: "a", to: +"v", surface: "s")
      second = described_class.new(from: "a", to: +"v", surface: "s")
      expect(first.to).to equal(second.to)
    end

    it "interns surface" do
      first = described_class.new(from: "a", to: "b", surface: +"v")
      second = described_class.new(from: "a", to: "b", surface: +"v")
      expect(first.surface).to equal(second.surface)
    end
  end
end
