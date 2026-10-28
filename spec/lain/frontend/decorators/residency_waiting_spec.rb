# frozen_string_literal: true

# A local request waiting for another model to finish on the same endpoint. The
# journal records how the wait ended; this is what tells the human, who would
# otherwise see a turn that has gone quiet.
RSpec.describe Lain::Frontend::Decorators::ResidencyWaiting do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }
  let(:event) do
    Lain::Provider::Residency::Waiting.new(endpoint: "http://localhost:11434", model: "qwen3:4b",
                                           resident: "lfm2.5:latest")
  end

  it "is what the frontend renders a residency wait with" do
    expect(Lain::Frontend::Decorators.for(event)).to be_a(described_class)
  end

  it "says which model it waits on, where, and which model it will load" do
    rendered = described_class.new(event).render(theme)

    expect(rendered).to eq("[residency] waiting for lfm2.5:latest to finish on http://localhost:11434 " \
                           "before loading qwen3:4b")
  end

  it "is one whole line the frontend may terminate, unstamped" do
    decorator = described_class.new(event)

    expect([decorator.line_shaped?, decorator.stamped?]).to eq([true, false])
  end

  it "writes nothing to stdout or stderr -- it only returns a string for the caller to route" do
    expect { described_class.new(event).render(theme) }.not_to output.to_stdout
  end
end
