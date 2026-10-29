# frozen_string_literal: true

RSpec.describe Lain::Config::Theme do
  let(:defaults) { Lain::Frontend::Theme::DEFAULT_TOKENS }

  it "is the default vocabulary when nothing is declared" do
    expect(described_class.empty.tokens).to eq(defaults)
  end

  it "recolours the declared tokens and keeps every other at its default" do
    tokens = described_class.from({ "response" => %w[green], "tool_header" => %w[magenta bold] }, path: nil).tokens

    expect(tokens).to eq(defaults.merge(response: %i[green], tool_header: %i[magenta bold]))
  end

  it "is deeply frozen" do
    expect(described_class.from({ "response" => %w[green] }, path: nil)).to be_deeply_frozen
  end

  it "refuses an unknown token, naming it, the file's line and the known tokens" do
    expect { described_class.from({ "respnse" => %w[green] }, path: "/u/config.rb:3") }
      .to raise_error(Lain::Config::Refusal, %r{\A/u/config\.rb:3: `theme` .*"respnse".*known tokens: response, rule})
  end

  it "refuses an unknown style, naming it and the token" do
    expect { described_class.from({ "response" => %w[green chartreuse] }, path: "/u/config.rb:4") }
      .to raise_error(Lain::Config::Refusal, %r{\A/u/config\.rb:4: .*response.*"chartreuse".*known styles: .*green})
  end

  it "refuses a reset, which ends a style rather than being one" do
    expect { described_class.from({ "response" => %w[reset] }, path: nil) }
      .to raise_error(Lain::Config::Refusal, /response has no style "reset"/)
  end

  it "refuses a value that is not a list of style names" do
    expect { described_class.from({ "response" => "green" }, path: nil) }
      .to raise_error(Lain::Config::Refusal, /response must be a list of style names, got "green"/)
  end

  it "refuses a table that is not a table" do
    expect { described_class.from("green", path: nil) }.to raise_error(Lain::Config::Refusal, /must be a table/)
  end
end
