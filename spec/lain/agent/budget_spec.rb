# frozen_string_literal: true

# The ceilings that bound an autonomous loop, pinned directly rather than only
# through the Agent. A budget stop is the *harness* deciding to halt (it raises),
# which is a different thing from a model `:refusal` (recorded, not raised) --
# these examples hold that line.
RSpec.describe Lain::Agent::Budget do
  describe "the iteration ceiling" do
    it "admits turns below the ceiling silently" do
      budget = described_class.new(max_iterations: 3)

      expect { budget.check_iterations!(0) }.not_to raise_error
      expect { budget.check_iterations!(2) }.not_to raise_error
    end

    it "refuses one more turn at the ceiling, with an inspectable reason" do
      budget = described_class.new(max_iterations: 3)

      expect { budget.check_iterations!(3) }
        .to raise_error(described_class::Exceeded, /3 iterations, ceiling is 3/)
    end

    it "raises the harness's own halt type, not a generic error" do
      budget = described_class.new(max_iterations: 1)

      expect { budget.check_iterations!(1) }.to raise_error(Lain::Error)
    end

    it "defaults to a finite ceiling so an unattended loop still stops" do
      expect(described_class.new.max_iterations).to eq(described_class::DEFAULT_MAX_ITERATIONS)
    end
  end

  describe "the token ceiling" do
    it "is opt-in: a nil ceiling never refuses" do
      budget = described_class.new(max_total_tokens: nil)

      expect { budget.check_tokens!(Lain::Usage.new(input_tokens: 10_000, output_tokens: 10_000)) }
        .not_to raise_error
    end

    it "admits spend at or below the ceiling" do
      budget = described_class.new(max_total_tokens: 100)

      expect { budget.check_tokens!(Lain::Usage.new(input_tokens: 60, output_tokens: 40)) }
        .not_to raise_error
    end

    it "refuses once total spend passes the ceiling, naming the ceiling" do
      budget = described_class.new(max_total_tokens: 50)

      expect { budget.check_tokens!(Lain::Usage.new(input_tokens: 40, output_tokens: 20)) }
        .to raise_error(described_class::Exceeded, /60 tokens, ceiling is 50/)
    end
  end

  it "is a frozen value once constructed" do
    expect(described_class.new).to be_frozen
  end
end
