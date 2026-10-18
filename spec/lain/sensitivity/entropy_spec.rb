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

  describe ".hinted?" do
    it "accepts a 16-char token mixing lowercase, uppercase and digits" do
      expect(described_class.hinted?("Qm9vT2s3x9ZpL1aB")).to be(true)
    end

    it "accepts a 16-char hex run that holds a letter" do
      expect(described_class.hinted?("3f5a9c2e1d7b4086")).to be(true)
    end

    it "rejects a token shorter than 16 chars" do
      expect(described_class.hinted?("Qm9vT2s3x9ZpL1a")).to be(false)
    end

    it "rejects a random token missing a letter case" do
      expect(described_class.hinted?("qm9vt2s3x9zpl1ab")).to be(false)
    end

    it "rejects a pure-digit token" do
      expect(described_class.hinted?("12345678901234567")).to be(false)
    end

    it "rejects a dashed uuid" do
      expect(described_class.hinted?("7d9f2c1e-3b4a-4c5d-8e6f-0a1b2c3d4e5f")).to be(false)
    end

    it "rejects a version string of hinted length" do
      expect(described_class.hinted?("1.24.3-rc.1+build.20261018")).to be(false)
    end

    it "rejects a 3-class token at 3.0 bits per char" do
      expect(described_class.hinted?("Qm9vQm9vT2s3T2s3")).to be(false)
    end

    it "rejects a hex run at 2.0 bits per char" do
      expect(described_class.hinted?("aaaa1111bbbb2222")).to be(false)
    end

    it "rejects a 15-char hex run" do
      expect(described_class.hinted?("3f5a9c2e1d7b408")).to be(false)
    end

    it "rejects a token with no lowercase letter" do
      expect(described_class.hinted?("BLD20261018X7Q9ZK")).to be(false)
    end

    it "accepts an uppercase hex run" do
      expect(described_class.hinted?("3F5A9C2E1D7B4086")).to be(true)
    end

    it "rejects a token holding a slash" do
      expect(described_class.hinted?("Qm9vT2s3/x9ZpL1aB")).to be(false)
    end

    it "rejects an alphabet run" do
      expect(described_class.hinted?("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123")).to be(false)
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
