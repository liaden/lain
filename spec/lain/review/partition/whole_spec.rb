# frozen_string_literal: true

# A REAL {Lain::Review::Changeset} over a synthetic diff String, never a double
# of one: the subject reads `#files`, and a double would let the fixture answer
# a file list the parser never produces. `bounds_spec.rb`'s own reasoning, and
# it costs no subprocess.
RSpec.describe Lain::Review::Partition::Whole do
  subject(:strategy) { described_class.new }

  def changeset_over(paths)
    diff = paths.map do |path|
      "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n-old\n+new\n"
    end.join
    source = DiffSource.over(instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, commits: [],
                                                                                base_ref: "b" * 40,
                                                                                head_ref: "h" * 40))
    Lain::Review::Changeset.new(source:)
  end

  let(:paths) { %w[a.rb lib/b.rb lib/c.rb lib/deep/d.rb e.rb] }

  it "answers the strategy port, so it can be handed anywhere one is taken" do
    expect { Lain::Review::Partition::Strategy.check!(strategy) }.not_to raise_error
  end

  it "names itself in the vocabulary's own spelling for the flat view" do
    expect(strategy.name).to eq("cumulative")
  end

  it "advises presenting whole, naming the scope that does it" do
    expect(strategy.advice).to include("cumulative")
  end

  # The degenerate strategy is degenerate on purpose: every source can be shown
  # whole, so there is no source it declines.
  it "supports any source, including one that answers no commit history" do
    expect(strategy.supports?(Object.new)).to be(true)
  end

  it "yields ONE partition carrying every file" do
    partitions = strategy.partition(changeset_over(paths))

    expect(partitions.size).to eq(1)
    expect(partitions.first.files.map(&:path)).to eq(paths)
  end

  it "labels that partition for what it is, so a refusal can name it" do
    expect(strategy.partition(changeset_over(paths)).first.label).to eq("the whole changeset")
  end

  # An empty changeset still yields the group, empty -- skipping it would make
  # "one partition" a claim that holds only sometimes.
  it "yields the one partition even for a changeset that touches nothing" do
    expect(strategy.partition(changeset_over([])).map(&:files)).to eq([[]])
  end

  it "partitions the same way twice, so a re-render cannot reorder the view" do
    changeset = changeset_over(paths)

    expect(strategy.partition(changeset).map(&:label)).to eq(strategy.partition(changeset).map(&:label))
  end

  it "answers partitions that withhold #hunks, so no group reaches Marks#reconcile" do
    expect(strategy.partition(changeset_over(paths))).to all(satisfy { |group| !group.respond_to?(:hunks) })
  end
end
