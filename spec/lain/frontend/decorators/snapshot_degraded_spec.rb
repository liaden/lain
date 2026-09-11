# frozen_string_literal: true

# A turn whose shadow snapshot store failed was recorded as the write-set
# scope records one. The journal says so for the record; this is what tells the
# human, who would otherwise find out only when an /undo cannot reach a shell's
# change.
RSpec.describe Lain::Frontend::Decorators::SnapshotDegraded do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }
  let(:event) do
    Lain::Agent::SnapshotSlot::SnapshotDegraded.new(phase: :prime, scope: "shadow_git",
                                                    reason: "shadow git init failed (Errno::ENOENT): git")
  end

  it "is what the frontend renders a degraded turn with" do
    expect(Lain::Frontend::Decorators.for(event)).to be_a(described_class)
  end

  it "says this turn's shell changes cannot be undone, and why" do
    rendered = described_class.new(event).render(theme)

    expect(rendered).to include("this turn's shell changes can't be undone", "shadow git init failed")
  end

  it "is one whole line the frontend may terminate" do
    expect(described_class.new(event).line_shaped?).to be(true)
  end

  it "writes nothing to stdout or stderr -- it only returns a string for the caller to route" do
    expect { described_class.new(event).render(theme) }.not_to output.to_stdout
  end
end
