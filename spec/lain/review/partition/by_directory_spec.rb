# frozen_string_literal: true

# `whole_spec.rb`'s fixture and its reason: a real {Lain::Review::Changeset}
# over a synthetic diff, so the paths under test are the ones the parser
# actually produces.
RSpec.describe Lain::Review::Partition::ByDirectory do
  subject(:strategy) { described_class.new }

  def changeset_over(paths)
    diff = paths.map do |path|
      "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n-old\n+new\n"
    end.join
    source = instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, commits: [],
                                                                base_ref: "b" * 40, head_ref: "h" * 40)
    Lain::Review::Changeset.new(source:)
  end

  # Six directories, twenty files, interleaved so a grouping that merely kept
  # the diff's order would come out wrong.
  def scattered
    dirs = ["lib/a", "lib/b", "lib/a/deep", "spec", "spec/support", "."]
    Array.new(20) { |i| File.join(dirs[i % dirs.size], "f#{i}.rb").delete_prefix("./") }
  end

  it "answers the strategy port, so it can be handed anywhere one is taken" do
    expect { Lain::Review::Partition::Strategy.check!(strategy) }.not_to raise_error
  end

  it "names itself, and the name is what a scope will be spelled as" do
    expect(strategy.name).to eq("by_directory")
  end

  it "advises presenting per directory, naming the scope that does it" do
    expect(strategy.advice).to include("by_directory")
  end

  # It reads `File.dirname` off a path and nothing else, so there is no source
  # it cannot partition -- which is the whole reason it ships now rather than
  # after a corpus exists.
  it "supports any source, including one that answers no commit history" do
    expect(strategy.supports?(Object.new)).to be(true)
  end

  it "groups files under their directory, the repository root included" do
    partitions = strategy.partition(changeset_over(%w[lib/a/one.rb lib/b/two.rb README.md]))

    expect(partitions.map(&:label)).to eq(["lib/a", "lib/b", "."])
    expect(partitions.map { |group| group.files.map(&:path) })
      .to eq([["lib/a/one.rb"], ["lib/b/two.rb"], ["README.md"]])
  end

  it "puts every file in exactly one partition, losing none and copying none" do
    changeset = changeset_over(scattered)
    grouped = strategy.partition(changeset).flat_map { |group| group.files.map(&:path) }

    expect(grouped.sort).to eq(changeset.files.map(&:path).sort)
    expect(grouped.uniq.size).to eq(grouped.size)
  end

  it "yields one partition per distinct directory, not one per file" do
    expect(strategy.partition(changeset_over(scattered)).size).to eq(6)
  end

  it "partitions the same way twice, so a re-render cannot reorder the view" do
    changeset = changeset_over(scattered)

    expect(strategy.partition(changeset).map(&:label)).to eq(strategy.partition(changeset).map(&:label))
  end

  it "yields nothing for a changeset that touches nothing, having no directory to name" do
    expect(strategy.partition(changeset_over([]))).to be_empty
  end

  it "answers partitions that withhold #hunks, so no group reaches Marks#reconcile" do
    expect(strategy.partition(changeset_over(scattered)))
      .to all(satisfy { |group| !group.respond_to?(:hunks) })
  end
end
