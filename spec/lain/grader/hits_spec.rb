# frozen_string_literal: true

RSpec.describe Lain::Grader::Hits do
  describe ".id_of" do
    it "answers a bare hit as a frozen string" do
      expect(described_class.id_of(:a)).to eq("a").and be_frozen
    end

    it "answers a hit with an id the same interned string as that bare id" do
      hit = Struct.new(:id).new(7)

      expect(described_class.id_of(hit)).to equal(described_class.id_of(7))
    end
  end

  it "leaves id coercion to Hits in both graders" do
    expect([Lain::Grader::Ndcg, Lain::Grader::Recall].flat_map { |g| g.private_instance_methods(false) })
      .not_to include(:id_of)
  end
end
