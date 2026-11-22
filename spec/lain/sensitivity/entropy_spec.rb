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

    it "rejects a GGUF model id" do
      expect(described_class.high?("bartowski/GLM-4-9B-Chat-GGUF")).to be(false)
    end

    it "rejects a mixed-case org and model id" do
      expect(described_class.high?("HuggingFaceTB/SmolLM2-360M-Instruct-GGUF")).to be(false)
    end

    it "still flags a prefixed token" do
      expect(described_class.high?("ghp_6Fz9qL2vX8mN4pR7tY1wK3sD5hJ0aB2cE4gI")).to be(true)
    end

    it "still flags alternating capital-digit runs either side of a slash" do
      expect(described_class.high?("Ab1Cd2Ef3Gh4/Ij5Kl6Mn7Op8Qr9St0Uv1Wx2")).to be(true)
    end

    it "still flags a second alternating run either side of a slash" do
      expect(described_class.high?("Kd8Fj2Ls9Qw/Tr5Yu1Io7Pa3Zx6Cv4Bn0Mm")).to be(true)
    end

    it "accepts real model ids" do
      ids = %w[meta-llama/Llama-3.1-8B-Instruct Qwen/Qwen2.5-Coder-7B]
      expect(ids.map { described_class.high?(_1) }).to eq([false, false])
    end

    it "still flags a random mixed-case segment after a slash" do
      expect(described_class.high?("keys/Qm9vT2s3x9ZpL1aBc7Yw2RtUv5NhGd8E")).to be(true)
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

    it "accepts lowercase hex of a digest's width, since the name is the evidence" do
      expect(described_class.hinted?("28e89f0b9fca089cc2c6396a4ccfa0e37f639d263349669a581a6936df935634")).to be(true)
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

    {
      "md5" => "fa39a630d203fd86c87d4a1f5d1e88a4",
      "sha1" => "a060eea4645974845f4617573851fef55b484d89",
      "sha256" => "87a760f0e59750fc3c04a887a562c415784bdd55fd442b604230dea3587eb2ce",
      "sha512" => "6e0cc266de6456cfe7bbe6345a519cb93a014aea55962d6fcd7d23e224c7172a" \
                  "14c4fc7f162ffa8b13f164f262cea6efb905a518a11caa6216e4dd8ab2350b61"
    }.each do |algorithm, hex|
      it "is true for lowercase hex of #{algorithm}'s width" do
        expect(described_class.predictable?(hex)).to be(true)
      end
    end

    it "is false for uppercase hex of a digest's width" do
      upper = "87A760F0E59750FC3C04A887A562C415784BDD55FD442B604230DEA3587EB2CE"

      expect(described_class.predictable?(upper)).to be(false)
    end

    it "is false for lowercase hex one character off a digest's width" do
      widths = %w[87a760f0e59750fc3c04a887a562c415784bdd55fd442b604230dea3587eb2c
                  87a760f0e59750fc3c04a887a562c415784bdd55fd442b604230dea3587eb2ce8]

      expect(widths.map { described_class.predictable?(_1) }).to eq([false, false])
    end
  end

  describe ".predictable? over path segments" do
    it "is true for a cargo artifact path, whose crate name carries a hash suffix" do
      expect(described_class.predictable?("target/debug/deps/word_count-46e9759e7fd1a230")).to be(true)
    end

    {
      "nix store" => "/nix/store/b6gvzjyb2pg0kjfwrjmg1vfhh54ad73z-firefox-33",
      "git object" => "git/objects/a0/9a35458c702b33eeacc393d103063234e8bc28",
      "docker overlay" => "lib/docker/overlay2/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08/diff",
      "git sha256 object" => "git/objects/48/252ddff0e5089bd97927c6886df5f7f3d85c82d84ebf6ae75c520bb239fd37",
      "huggingface snapshot" => "hub/models--Qwen--Qwen3-8B/snapshots/a09a35458c702b33eeacc393d103063234e8bc28/config",
      "huggingface repo with dashed names" =>
        "hub/models--meta-llama--Meta-Llama-3-8B/snapshots/a09a35458c702b33eeacc393d103063234e8bc28/config",
      "huggingface snapshot cut at a dot in its repo name" =>
        "5-7B-Instruct/snapshots/6fbdb2765e2d88513dc1825bdd5b168c26453ddd/config",
      "temporary directory named for its date, pid and a short random suffix" =>
        "/home/alice/tmp/lain/lain-issue-actor20261121-3138037-uzht41",
      "temporary directory with no prefix" => "/home/alice/tmp/d20261121-3138037-1x9k2p/out.log"
    }.each do |layout, path|
      it "is true for a #{layout} path" do
        expect(described_class.predictable?(path)).to be(true)
      end
    end

    it "is false for a name glued to a hex run wider than a build hash" do
      path = "hook/webhook_signing_secret-cf588750bd0289e64e97338301006fdc/run"

      expect(described_class.predictable?(path)).to be(false)
    end

    it "is false for a key-width hex segment outside a known layout" do
      path = "com/keys/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08/send"

      expect(described_class.predictable?(path)).to be(false)
    end

    it "is false for a hash segment in a layout's place but not its shape" do
      expect(described_class.predictable?("var/lib/docker/overlay2/Xk9mP2qR7vL4nT8wZ3bY6cH1/diff")).to be(false)
    end

    it "is false for a random mixed-case segment" do
      expect(described_class.predictable?("files/Xk9mP2qR7vL4nT8wZ3bY6cH1/data")).to be(false)
    end

    {
      "a long random suffix" => "/home/alice/tmp/lain-x20261121-3138037-Xk9mP2qR7vL4nT8wZ3bY6cH1",
      "a random prefix" => "/home/alice/tmp/xk9mp2qr7vl4nt8wz3by6ch1q20261121-3138037-uzht41"
    }.each do |what, path|
      it "is false for a temporary directory name with #{what}" do
        expect(described_class.predictable?(path)).to be(false)
      end
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
