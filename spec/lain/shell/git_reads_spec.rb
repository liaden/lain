# frozen_string_literal: true

RSpec.describe Lain::Shell::GitReads do
  def facets(subcommands, *facets) = subcommands.map { |name| facets.map { described_class.facet?(name, _1) } }

  describe ".facet?" do
    it "marks merge-base and rev-list as read-only history reads" do
      expect(facets(%w[merge-base rev-list], :read_only, :history_only)).to all(eq([true, true]))
    end

    it "keeps cat-file read-only but out of history-only" do
      expect(facets(%w[cat-file], :read_only, :history_only)).to eq([[true, false]])
    end

    it "does not count a writing, unlisted or only-listing subcommand as read-only" do
      names = %w[commit push checkout whatchanged range-diff branch nonsense]

      expect(facets(names, :read_only).flatten).to all(be(false))
    end

    it "marks the subcommands that print no tree contents" do
      expect(facets(%w[status ls-files ls-tree rev-parse shortlog merge-base], :tree_free).flatten).to all(be(true))
      expect(facets(%w[log show diff cat-file rev-list], :tree_free).flatten).to all(be(false))
    end

    it "refuses a facet it does not define" do
      expect { described_class.facet?("log", :bogus) }.to raise_error(ArgumentError)
    end
  end
end
