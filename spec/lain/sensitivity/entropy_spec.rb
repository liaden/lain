# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Entropy do
  describe ".high?" do
    it "accepts a random 32-char base64 token" do
      expect(described_class.high?("Qm9vT2s3x9ZpL1aBc7Yw2RtUv5NhGd8E")).to be(true)
    end

    it "accepts a 40-char git sha" do
      expect(described_class.high?("a94a8fe5ccb19ba61c4c0873d391e987982fbbd3")).to be(true)
    end

    it "rejects a path of words" do
      expect(described_class.high?("var/lib/postgresql/data/base/pg_wal_dir")).to be(false)
    end

    it "rejects a hex run below the length floor" do
      expect(described_class.high?("3f5a9c2e1d7b")).to be(false)
    end
  end

  describe ".predictable?" do
    it "is true for slash-joined words" do
      expect(described_class.predictable?("var/lib/postgresql/data")).to be(true)
    end

    it "is true for an alphabet run" do
      expect(described_class.predictable?("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef")).to be(true)
    end

    it "is false for a random token" do
      expect(described_class.predictable?("Qm9vT2s3x9ZpL1aBc7Yw2RtUv5NhGd8E")).to be(false)
    end
  end

  describe ".shannon" do
    it "is 0 for one repeated character" do
      expect(described_class.shannon("aaaa")).to eq(0.0)
    end

    it "is 2 bits for four equally common characters" do
      expect(described_class.shannon("abcd")).to eq(2.0)
    end
  end
end
