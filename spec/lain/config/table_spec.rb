# frozen_string_literal: true

RSpec.describe Lain::Config::Table do
  describe ".read" do
    it "answers an empty Hash for nil" do
      expect(described_class.read(nil, path: nil, name: "`todos`", keys: %w[file])).to eq({})
    end

    it "answers the table when its keys are known" do
      expect(described_class.read({ "file" => "A.md" }, path: nil, name: "`todos`", keys: %w[file]))
        .to eq({ "file" => "A.md" })
    end

    it "refuses a non-table, naming the table and the path" do
      expect { described_class.read("x", path: "c.rb:3", name: "`todos`", keys: %w[file]) }
        .to raise_error(Lain::Config::Refusal, /`todos`.*must be a table/m) { |e| expect(e.message).to include("c.rb:3") }
    end

    it "refuses unknown keys, listing the known ones" do
      expect { described_class.read({ "fil" => 1 }, path: nil, name: "`todos`", keys: %w[file]) }
        .to raise_error(Lain::Config::Refusal, /has no keys "fil"; known keys: file/)
    end

    it "leaves the keys open when keys is nil" do
      expect(described_class.read({ "any" => 1 }, path: nil, name: "`theme`", keys: nil)).to eq({ "any" => 1 })
    end
  end
end
