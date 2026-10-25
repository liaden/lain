# frozen_string_literal: true

# Which weights a local server ran: the digest it has resident and the
# quantization its model file declares.
RSpec.describe Lain::Provider::ModelIdentity do
  it "holds a digest and a quant" do
    expect(described_class.new(digest: "sha256:abc", quant: "Q4_K_M"))
      .to have_attributes(digest: "sha256:abc", quant: "Q4_K_M")
  end

  it "names the two readings a server can fail to give" do
    expect([described_class::NOT_RESIDENT, described_class::UNRECORDED]).to eq(["not resident", "unrecorded"])
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(described_class.new(digest: +"sha256:abc", quant: +"Q4_K_M"))).to be(true)
  end
end
