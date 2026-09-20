# frozen_string_literal: true

# The head of a review: which source produced the changeset, what it spans, and
# the address every later record joins back to.
RSpec.describe Lain::Review::ChangesetOpened do
  def opened(**overrides)
    described_class.new(source: "local_branch", base_ref: "a1b2c3", head_ref: "d4e5f6",
                        digest: "cafe", **overrides)
  end

  let(:record) { opened }

  it_behaves_like "a review journal record", "changeset_opened"

  it "refuses a changeset that names no source, no span, or no address" do
    expect { opened(source: nil) }.to raise_error(ArgumentError, /source/)
    expect { opened(base_ref: "  ") }.to raise_error(ArgumentError, /base_ref/)
    expect { opened(head_ref: nil) }.to raise_error(ArgumentError, /head_ref/)
    expect { opened(digest: "") }.to raise_error(ArgumentError, /digest/)
  end

  # A refusal that says "got nil" over a value that was `""` sends the reader
  # looking for a missing argument they did not pass. Every message reports the
  # value it actually judged, in `inspect` form, so nil and "" and "  " are three
  # different sentences.
  it "reports the value it judged rather than assuming which blank arrived" do
    expect { opened(digest: "") }.to raise_error(ArgumentError, 'digest must address the changeset, got ""')
    expect { opened(digest: nil) }.to raise_error(ArgumentError, "digest must address the changeset, got nil")
    expect { opened(source: "  ") }
      .to raise_error(ArgumentError, 'source must name what produced the changeset, got ""')
  end

  # The source registry is the port's, and one of its entries is deletable. A
  # second copy of the set here would have to be edited to delete a capability,
  # which is exactly the drift a shared vocabulary avoids.
  it "accepts any named source rather than restating the source registry" do
    expect(opened(source: "github_pr").source).to eq("github_pr")
  end

  # The TARGET is what a human would call the same review: a survey of `big/`
  # whose files changed since is still that survey, while its digest is not.
  describe "the target a round was opened on" do
    let(:record) { opened(target: "/work/big") }

    it_behaves_like "a review journal record", "changeset_opened"

    it "carries the target the round was opened on" do
      expect(opened(target: " /work/big\n").target).to eq("/work/big")
    end

    # A round opened by a caller that names no target journals exactly the
    # record it always did, and one read back from before the field existed
    # rebuilds rather than refusing.
    it "journals no target key at all when none was named" do
      expect(opened.to_journal).not_to have_key("target")
      expect(opened.target).to be_nil
    end

    it "refuses a blank target, which would match every other blank one" do
      expect { opened(target: "  ") }.to raise_error(ArgumentError, /target/)
    end
  end
end
