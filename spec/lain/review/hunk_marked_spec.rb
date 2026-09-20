# frozen_string_literal: true

# One hunk's reviewed mark. The tri-state a file or a commit shows is DERIVED
# from these, so the vocabulary stored here is binary and closed.
RSpec.describe Lain::Review::HunkMarked do
  def marked(**overrides)
    described_class.new(hunk_key: "hunk-content-v1:beef", state: "reviewed", **overrides)
  end

  let(:record) { marked }

  it_behaves_like "a review journal record", "hunk_marked"

  it "carries both mark states and refuses a third spelling" do
    expect(marked(state: "unreviewed").state).to eq("unreviewed")
    expect { marked(state: "partial") }.to raise_error(ArgumentError, /state/)
    expect { marked(state: nil) }.to raise_error(ArgumentError, /state/)
  end

  it "refuses a mark that names no hunk" do
    expect { marked(hunk_key: nil) }.to raise_error(ArgumentError, /hunk_key/)
  end

  # The key's scheme prefix belongs to Review::Hunk, which is the object
  # that can change it. Restating the prefixes here would be a second copy of
  # that scheme waiting to disagree with the first.
  it "does not restate the key scheme it stores" do
    expect(marked(hunk_key: "hunk-span-v1:beef").hunk_key).to eq("hunk-span-v1:beef")
  end

  it "accepts a Symbol state as readily as its name" do
    expect(marked(state: :reviewed).state).to eq("reviewed")
  end

  # The half of Wire's two rules that nothing else here could see. `presence:`
  # already treats a whitespace-only String as blank, so every refusal in this
  # file passes with or without the strip -- and a token arriving off a wire with
  # a space around it would then miss its closed set and be refused as an unknown
  # spelling rather than read as the value it is.
  it "reads a token through the whitespace a wire wrapped it in" do
    expect(marked(state: " reviewed ").state).to eq("reviewed")
    expect(marked(hunk_key: " hunk-content-v1:beef\n").hunk_key).to eq("hunk-content-v1:beef")
  end
end
