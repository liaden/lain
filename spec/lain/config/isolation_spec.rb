# frozen_string_literal: true

RSpec.describe Lain::Config::Isolation do
  let(:path) { "/project/.lain/config.toml" }
  let(:coordinator_defaults) do
    { verifier: "command", verify: [], verify_timeout: 1800, verify_keep: ["target/"], batch_cap: 8,
      rebuild_cap: 3, check: [], lint: [], lint_files: [], check_retries: 1 }
  end

  describe ".from" do
    it "yields the ruled defaults for an absent table" do
      expect(described_class.from(nil, path:).to_h)
        .to eq(retain_days: 7, rebase_retries: 1, diff_algorithm: "histogram", conflict_style: "zdiff3",
               **coordinator_defaults)
    end

    it "is the same value .empty answers when the table is absent" do
      expect(described_class.from(nil, path:)).to eq(described_class.empty)
    end

    it "reads every key it knows, defaulting the ones left out" do
      isolation = described_class.from({ "retain_days" => 3, "diff_algorithm" => "patience" }, path:)

      expect(isolation.to_h)
        .to eq(retain_days: 3, rebase_retries: 1, diff_algorithm: "patience", conflict_style: "zdiff3",
               **coordinator_defaults)
    end

    it "reads the verify, fast-tier and batch keys" do
      isolation = described_class.from({ "verify" => %w[bundle exec rake], "verify_timeout" => 60,
                                         "verify_keep" => %w[target/ vendor/], "batch_cap" => 2,
                                         "rebuild_cap" => 0, "check" => %w[rspec], "lint" => %w[rubocop],
                                         "lint_files" => %w[**/*.rb],
                                         "check_retries" => 0 }, path:)

      expect(isolation.to_h).to include(verify: %w[bundle exec rake], verify_timeout: 60, batch_cap: 2,
                                        rebuild_cap: 0, check: %w[rspec], lint: %w[rubocop],
                                        lint_files: %w[**/*.rb], check_retries: 0,
                                        verify_keep: %w[target/ vendor/])
    end

    it "names every bad argv entry in one refusal" do
      named = /#{Regexp.escape(path)}.*`isolation`.*verify:.*entry 1.*entry 2/m

      expect { described_class.from({ "verify" => ["bundle", "", 3] }, path:) }
        .to raise_error(Lain::Config::Refusal, named)
    end

    it "refuses a verifier strategy it does not know, listing the accepted ones" do
      expect { described_class.from({ "verifier" => "jenkins" }, path:) }
        .to raise_error(Lain::Config::Refusal, /verifier: "jenkins".*one of command/)
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
      "conflict_style" => ["zdiff4", "diff2", nil],
      "verify" => ["bundle", { "a" => 1 }, nil],
      "check" => ["rspec", 1],
      "lint" => [[""], [nil]],
      "lint_files" => ["*.rb", [""], [3]],
      "verify_keep" => ["target/", [""], [3], ["/abs"], ["../x"], ["a/../b"]],
      "verify_timeout" => [0, 1.5, "60"],
      "batch_cap" => [0, "8"],
      "rebuild_cap" => [-1, 1.5],
      "check_retries" => [-1, true]
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

    it "holds frozen lists, so a caller cannot edit the defaults" do
      expect(described_class.from({ "verify" => %w[a b] }, path:).verify).to be_frozen
    end

    it "is one value, not a fresh allocation per call" do
      expect(described_class.empty).to equal(described_class.empty)
    end
  end
end
