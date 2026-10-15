# frozen_string_literal: true

RSpec.describe Lain::Config::Keys do
  it "defaults the approval cycle to Shift+Tab" do
    expect(described_class.empty.approval_cycle).to eq("S-Tab")
  end

  it "reads a declared approval cycle" do
    expect(described_class.from({ "approval_cycle" => "C-x" }, path: "/u/config.rb:1").approval_cycle).to eq("C-x")
  end

  it "accepts the forms the line editor can bind, in any case" do
    expect(%w[C-g c-G S-Tab s-tab].map do |name|
      described_class.from({ "approval_cycle" => name }, path: nil).approval_cycle
    end)
      .to eq(%w[C-g c-G S-Tab s-tab])
  end

  it "refuses an unknown key name, naming the line and the accepted forms" do
    expect { described_class.from({ "approval_cycle" => "Hyper-Q" }, path: "/u/config.rb:3") }
      .to raise_error(Lain::Config::Refusal, %r{\A/u/config\.rb:3: `keys` .*"C-x".*"S-Tab".*"Hyper-Q"})
  end

  it "refuses a value that is not a string" do
    expect { described_class.from({ "approval_cycle" => 7 }, path: nil) }
      .to raise_error(Lain::Config::Refusal, /approval_cycle.*7/)
  end

  it "refuses a key it does not know" do
    expect { described_class.from({ "approval_cyle" => "C-x" }, path: nil) }
      .to raise_error(Lain::Config::Refusal, /approval_cyle.*approval_cycle/)
  end
end
