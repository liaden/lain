# frozen_string_literal: true

# What joined a survey already open, and the address the corpus has now. The
# second record able to move a round's digest, and the reason `regenerated?`
# reads the LAST one on record rather than the opened one.
RSpec.describe Lain::Review::CorpusExtended do
  def extended(**overrides)
    described_class.new(paths: ["lib/lain/agent.rb"], digest: "survey-corpus-v1:cafe", **overrides)
  end

  let(:record) { extended }

  it_behaves_like "a review journal record", "corpus_extended"

  it "refuses a widening that names nothing, or addresses nothing" do
    expect { extended(paths: []) }.to raise_error(ArgumentError, /paths/)
    expect { extended(paths: nil) }.to raise_error(ArgumentError, /paths/)
    expect { extended(digest: nil) }.to raise_error(ArgumentError, /digest/)
    expect { extended(digest: "  ") }.to raise_error(ArgumentError, /digest/)
  end

  it "carries every path that joined, not just the first" do
    expect(extended(paths: %w[a.md b.md]).paths).to eq(%w[a.md b.md])
  end

  # `presence:` judges the LIST, so `[nil]` and `[""]` are both present lists of
  # nothing. This record is a wire boundary -- Session::Replay reads `paths`
  # straight off a JSON line and rebuilds through this constructor -- and a nil
  # inside the list replays into a path a resume then walks.
  it "refuses a blank inside the list, which a present list can still carry" do
    expect { extended(paths: [nil, "a.md"]) }.to raise_error(ArgumentError, /paths/)
    expect { extended(paths: [""]) }.to raise_error(ArgumentError, /paths/)
    expect { extended(paths: ["a.md", "  "]) }.to raise_error(ArgumentError, /paths/)
  end

  it "says which list it judged, rather than which element" do
    expect { extended(paths: [nil, "a.md"]) }
      .to raise_error(ArgumentError, 'paths must name only real paths, got [nil, "a.md"]')
  end

  # The record is what a resume reads to know which tree to walk, so the paths
  # cross the wire under the same normalization every other token here gets --
  # a name with a trailing newline off a wire would otherwise rebuild a walk
  # over a path that does not exist.
  it "reads its paths through the whitespace a wire wrapped them in" do
    expect(extended(paths: [" a.md\n"]).paths).to eq(["a.md"])
  end

  # `Array()` and not a type test: a single path is the ordinary case the
  # gesture produces, and refusing it would make the caller wrap a value the
  # record is perfectly able to read.
  it "reads one path given bare as the one-path widening it is" do
    expect(extended(paths: "a.md").paths).to eq(["a.md"])
  end
end
