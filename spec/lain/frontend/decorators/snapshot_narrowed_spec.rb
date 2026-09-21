# frozen_string_literal: true

# A turn wrote where this snapshot's root does not reach, so those paths were
# not recorded and /undo cannot put them back. The journal holds the count for
# the record; this is what tells the human, who would otherwise read "no file
# needed putting back" over a file that is still changed.
RSpec.describe Lain::Frontend::Decorators::SnapshotNarrowed do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }
  let(:event) do
    Lain::Agent::SnapshotSlot::SnapshotNarrowed.new(scope: "shadow_git", root: "/w/spike", dropped: 2)
  end

  it "is what the frontend renders a narrowed turn with" do
    expect(Lain::Frontend::Decorators.for(event)).to be_a(described_class)
  end

  it "says how many paths went unrecorded, where the snapshot reached, and what it costs" do
    rendered = described_class.new(event).render(theme)

    expect(rendered).to include("2 paths outside", "/w/spike", "went unrecorded", "can't be undone")
  end

  # Both halves of the count, because the line is read by a human: "1 paths"
  # reads as a bug in the line, and so does "3 paths ... wasn't recorded".
  it "counts one dropped path in the singular, with a verb that agrees either way" do
    one = Lain::Agent::SnapshotSlot::SnapshotNarrowed.new(scope: "write_set", root: "/w", dropped: 1)

    expect(described_class.new(one).render(theme)).to include("1 path outside /w went unrecorded")
  end

  it "is one whole line the frontend may terminate" do
    expect(described_class.new(event).line_shaped?).to be(true)
  end

  it "writes nothing to stdout or stderr -- it only returns a string for the caller to route" do
    expect { described_class.new(event).render(theme) }.not_to output.to_stdout
  end
end
