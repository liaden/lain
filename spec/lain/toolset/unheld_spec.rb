# frozen_string_literal: true

# What a name resolves to when the toolset does not hold it. Every reader of
# the tool phase takes it in the tool's place, so each answer below is one a
# reader would otherwise have had to branch on.
RSpec.describe Lain::Toolset::Unheld do
  subject(:unheld) { described_class.new(:ghost) }

  it "refuses by name when run, as an error result rather than a raise" do
    expect(unheld.call({ "path" => ".env" }, Lain::Tool::Invocation.new(context: nil)))
      .to eq(Lain::Tool::Result.error('no tool named "ghost" is available'))
  end

  it "is never parallel-safe, never asks for approval, and is not held" do
    expect([unheld.parallel_safe?, unheld.requires_approval?, unheld.held?]).to eq([false, false, false])
  end

  it "is a shareable value over the name as a String" do
    expect(unheld.name).to eq("ghost")
    expect(unheld).to eq(described_class.new("ghost"))
    expect(Ractor.shareable?(unheld)).to be(true)
  end

  it "is what the runner resolves a name the toolset lacks to" do
    expect(dispatch_call("ghost", toolset: Lain::Toolset.new).content).to eq('no tool named "ghost" is available')
  end
end
