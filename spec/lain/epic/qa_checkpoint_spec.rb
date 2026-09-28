# frozen_string_literal: true

# A checkpoint is marked by its id, and the ids it mints for the fixes a failing
# pass files must never be readable as checkpoints themselves -- a fix read as
# one would be run as QA instead of being implemented, and would block itself.
RSpec.describe Lain::Epic::QaCheckpoint do
  def issue(id) = Lain::Epic::Issue.new(id:, title: "the #{id} issue")

  it "recognizes a checkpoint by its id, which the epic markdown already carries" do
    expect(%w[qa-gate-1 qa-gate-final dashboard qa-fix-1-1].map { |id| described_class.of?(issue(id)) })
      .to eq([true, true, false, false])
  end

  # Whatever the checkpoint is called, including one whose own id embeds the
  # checkpoint prefix: the two prefixes are disjoint, so no minted id can be
  # read back as a node the gate would run.
  it "mints fix ids that can never themselves be read as checkpoints" do
    minted = %w[qa-gate-1 qa-gate-final qa-gate-qa-gate-2].flat_map { |id| described_class.fix_ids(id, []).first(3) }

    expect(minted.first(3)).to eq(%w[qa-fix-1-1 qa-fix-1-2 qa-fix-1-3])
    expect(minted).to include("qa-fix-final-1", "qa-fix-qa-gate-2-1")
    expect(minted.map { |id| described_class.of?(issue(id)) }).to all(be(false))
  end

  # Reserving a namespace means every id under it, including one a human meant as
  # ordinary work: it would be run as QA, never implemented, and hold whatever it
  # blocks. Pinned so the cost of the convention is stated rather than discovered.
  it "reads every id under the prefix as a checkpoint, which is what reserving it means" do
    expect(described_class.of?(issue("qa-gate-keeper-refactor"))).to be(true)
  end

  it "files a second failing pass beside the first rather than colliding with it" do
    expect(described_class.fix_ids("qa-gate-1", %w[qa-fix-1-1 qa-fix-1-2]).first(2)).to eq(%w[qa-fix-1-3 qa-fix-1-4])
  end

  # An id the graph accepts but a Home cannot write would fail at the write,
  # after QA had already run.
  it "mints ids the filesystem grammar accepts" do
    minted = described_class.fix_ids("qa-gate-final", []).first

    expect(Lain::Epic::Home.filesystem_name_failure(minted, "id")).to be_nil
  end

  # The ids are unbounded, so a caller asks for as many as it has findings
  # without this object knowing how many that is.
  it "answers an enumerator rather than a list, so a caller takes what it needs" do
    expect(described_class.fix_ids("qa-gate-1", [])).to be_a(Enumerator::Lazy)
  end
end
