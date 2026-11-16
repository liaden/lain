# frozen_string_literal: true

RSpec.describe Lain::Config::Github do
  def from(source) = Lain::Config::Builder.evaluate(source, path: "config.rb").github

  describe ".from" do
    it "keeps the filters typed, frozen and the roots expanded" do
      github = from(<<~RUBY)
        github orgs: %w[fuze], roots: %w[~/src ~/work], keywords: %w[perf sql],
               paths: [%r{\\Adb/migrate/}, /\\.sql\\z/], since_days: 14
      RUBY

      expect(github.roots).to eq([File.expand_path("~/src"), File.expand_path("~/work")])
      expect([github.orgs, github.keywords, github.paths, github.since_days])
        .to eq([%w[fuze], %w[perf sql], [%r{\Adb/migrate/}, /\.sql\z/], 14])
      expect(Ractor.shareable?(github)).to be(true)
    end

    it "refuses a typo naming the file, line, the key and the known keys" do
      expect { from("\ngithub acount: \"x\"\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2.*acount.*account.*since_days/m)
    end

    it "refuses a non-Regexp path" do
      expect { from("github paths: [\"db/\"]\n") }.to raise_error(Lain::Config::Refusal, /paths/)
    end

    it "accepts a Symbol keyword as its name" do
      expect(from("github keywords: [:perf]\n").keywords).to eq(%w[perf])
    end

    it "makes a Regexp built at run time shareable" do
      github = described_class.from({ "paths" => [Regexp.new("a+")] }, path: nil)

      expect(Ractor.shareable?(github)).to be(true)
    end

    it "refuses a non-String keyword" do
      expect { from("github keywords: [3]\n") }.to raise_error(Lain::Config::Refusal, /keywords/)
    end

    it "refuses a since_days that is not a positive integer" do
      expect { from("github since_days: 0\n") }.to raise_error(Lain::Config::Refusal, /since_days/)
    end
  end

  describe ".resolve" do
    let(:project) { described_class.from({ "account" => "liaden", "orgs" => %w[a] }, path: nil) }
    let(:user) { described_class.from({ "account" => "joel-fuze", "orgs" => %w[b], "since_days" => 3 }, path: nil) }

    it "lets the project beat the user, field by field" do
      resolved = described_class.resolve(project:, user:, env: {})

      expect([resolved.account, resolved.orgs, resolved.since_days]).to eq(["liaden", %w[a], 3])
    end

    it "lets the environment beat both for the account" do
      expect(described_class.resolve(project:, user:, env: { "LAIN_GH_ACCOUNT" => "other" }).account).to eq("other")
    end

    it "is the default, with no account, when nothing sets anything" do
      resolved = described_class.resolve(project: described_class.empty, user: described_class.empty, env: {})

      expect(resolved).to eq(described_class.new(account: nil, orgs: [], roots: [], keywords: [], paths: [],
                                                 since_days: 14))
      expect(resolved.account).to be_nil
    end
  end
end
