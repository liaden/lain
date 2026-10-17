# frozen_string_literal: true

RSpec.describe Lain::CLI::EnvDefaults do
  describe ".string" do
    it "answers the variable when it is set" do
      with_env("LAIN_PROVIDER" => "ollama") do
        expect(described_class.string("LAIN_PROVIDER", "anthropic")).to eq("ollama")
      end
    end

    it "answers the fallback when the variable is unset" do
      with_env("LAIN_PROVIDER" => nil) do
        expect(described_class.string("LAIN_PROVIDER", "anthropic")).to eq("anthropic")
      end
    end

    # `direnv` and a shell `export FOO=` both produce an EMPTY string rather
    # than an absent one, and reading that as a provider named "" refuses far
    # from the cause -- `UnknownProvider ""` names nothing a human can act on.
    it "treats an empty variable as absence, which is what `export LAIN_PROVIDER=` leaves behind" do
      with_env("LAIN_PROVIDER" => "") do
        expect(described_class.string("LAIN_PROVIDER", "anthropic")).to eq("anthropic")
      end
    end

    it "strips surrounding whitespace, which a quoted .envrc line carries in" do
      with_env("LAIN_MODEL" => "  qwen3:4b \n") do
        expect(described_class.string("LAIN_MODEL")).to eq("qwen3:4b")
      end
    end

    it "answers nil with no fallback, so an unset flag stays unset rather than becoming empty" do
      with_env("LAIN_MODEL" => nil) do
        expect(described_class.string("LAIN_MODEL")).to be_nil
      end
    end
  end

  describe ".numeric" do
    it "reads an integer" do
      with_env("LAIN_NUM_CTX" => "8192") do
        expect(described_class.numeric("LAIN_NUM_CTX", 4_096)).to eq(8_192)
      end
    end

    # One reader serves whole and fractional values, so the Float arm is not
    # decoration: `0.7` read as an Integer is 0, which is
    # silently wrong.
    it "reads a float, because a fractional value rides this same reader" do
      with_env("LAIN_NUM_BATCH" => "0.7") do
        expect(described_class.numeric("LAIN_NUM_BATCH")).to eq(0.7)
      end
    end

    it "answers the fallback when unset" do
      with_env("LAIN_NUM_CTX" => nil) do
        expect(described_class.numeric("LAIN_NUM_CTX", 4_096)).to eq(4_096)
      end
    end

    # THE COUNTER-EXAMPLE THIS OBJECT EXISTS FOR. Falling back on garbage is the
    # tempting implementation and the wrong one: the human set the variable
    # deliberately, and a session that quietly ran at 4096 tokens because
    # `LAIN_NUM_CTX=lots` did not parse is the failure nobody can see.
    it "refuses garbage by name rather than falling back to the default" do
      with_env("LAIN_NUM_CTX" => "lots") do
        expect { described_class.numeric("LAIN_NUM_CTX", 4_096) }
          .to raise_error(Lain::Error, /LAIN_NUM_CTX="lots" is not a number/)
      end
    end

    it "refuses a number with trailing junk rather than reading the numeric prefix" do
      with_env("LAIN_NUM_CTX" => "8192tokens") do
        expect { described_class.numeric("LAIN_NUM_CTX") }.to raise_error(Lain::Error, /not a number/)
      end
    end
  end

  describe "the name tables" do
    it "keeps every read name apart from every retired one" do
      expect(described_class::READ & described_class::RETIRED).to be_empty
    end

    it "is deeply frozen and sorted" do
      expect(Ractor.shareable?(described_class::READ)).to be(true)
      expect(Ractor.shareable?(described_class::RETIRED)).to be(true)
      expect(described_class::READ).to eq(described_class::READ.sort)
    end
  end
end
