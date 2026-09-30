# frozen_string_literal: true

RSpec.describe Lain::Config::Isolation do
  let(:path) { "/project/.lain/config.toml" }

  describe ".from" do
    it "yields the ruled defaults for an absent table" do
      expect(described_class.from(nil, path:).to_h)
        .to eq(retain_days: 7, rebase_retries: 1, diff_algorithm: "histogram", conflict_style: "zdiff3")
    end

    it "is the same value .empty answers when the table is absent" do
      expect(described_class.from(nil, path:)).to eq(described_class.empty)
    end

    it "reads every key it knows, defaulting the ones left out" do
      isolation = described_class.from({ "retain_days" => 3, "diff_algorithm" => "patience" }, path:)

      expect(isolation.to_h)
        .to eq(retain_days: 3, rebase_retries: 1, diff_algorithm: "patience", conflict_style: "zdiff3")
    end

    # Zero is a real setting, not a typo: it is how a project turns worker
    # self-sync off and goes straight to handback.
    it "accepts rebase_retries = 0" do
      expect(described_class.from({ "rebase_retries" => 0 }, path:).rebase_retries).to eq(0)
    end

    it "refuses a scalar where the table belongs, naming the file" do
      expect { described_class.from("fast", path:) }
        .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(path)}.*`isolation` must be a table/)
    end

    it "refuses an unknown key, naming the key and the file" do
      expect { described_class.from({ "retian_days" => 7 }, path:) }
        .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(path)}.*"retian_days".*retain_days/)
    end

    {
      "retain_days" => [-1, 0, 7.5, "7", true],
      "rebase_retries" => [-1, 1.5, "1", false],
      "diff_algorithm" => ["patients", 3],
      "conflict_style" => ["zdiff4", "diff2", nil]
    }.each do |key, values|
      values.each do |value|
        it "refuses #{key}: #{value.inspect}, naming the key and the file" do
          named = /#{Regexp.escape(path)}.*#{key}: #{Regexp.escape(value.inspect)}/

          expect { described_class.from({ key => value }, path:) }.to raise_error(Lain::Config::Refusal, named)
        end
      end
    end
  end

  # The closed sets belong to the VALUE, not only to the path that parses TOML
  # into one: a hand-built table must refuse as loudly as a bad file.
  describe ".new" do
    it "refuses a bad value built directly, naming the key" do
      expect { described_class.new(**described_class.empty.to_h, conflict_style: "zdiff4") }
        .to raise_error(Lain::Config::Refusal, /conflict_style: "zdiff4"/)
    end
  end

  describe ".empty" do
    it "is deeply frozen" do
      expect(described_class.empty).to be_deeply_frozen
    end

    it "is one value, not a fresh allocation per call" do
      expect(described_class.empty).to equal(described_class.empty)
    end
  end
end
