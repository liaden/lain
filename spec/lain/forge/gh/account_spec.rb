# frozen_string_literal: true

# The account every gh child acts as. gh itself is a fake at the Shell::Out seam, so no example
# reads a real keyring.
RSpec.describe Lain::Forge::Gh::Account do
  let(:notes) { Lain::Herdr::HeldNotes.new }
  let(:said) { [] }
  let(:factory) { GhParity.factory }

  before { notes.bind(->(line) { said << line }) }

  def github(account)
    Lain::Config::Github.resolve(project: Lain::Config::Github.from({ "account" => account }, path: nil),
                                 user: Lain::Config::Github.empty, env: {})
  end

  def account_for(name, env: {}) = described_class.for(github(name), env:, shell_out_factory: factory, notes:)

  describe "a configured account" do
    it "lends its token as GH_TOKEN, asking gh for it once" do
      account = account_for("joel-fuze")

      expect(account.environment).to eq("GH_TOKEN" => "t0k")
      expect(account.environment).to eq("GH_TOKEN" => "t0k")
      expect(factory.argvs).to eq([%w[gh auth token --user joel-fuze]])
    end

    it "asks nothing until a token is wanted" do
      account_for("joel-fuze")

      expect(factory.argvs).to be_empty
    end
  end

  describe "an exported token" do
    it "wins over the account, and the chat is told once, by account name" do
      account = account_for("joel-fuze", env: { "GH_TOKEN" => "exported-secret" })

      2.times { expect(account.environment).to eq("GH_TOKEN" => "exported-secret") }
      expect(factory.argvs).to be_empty
      expect(said.size).to eq(1)
      expect(said.first).to include("joel-fuze").and include("GH_TOKEN")
      expect(said.first).not_to include("exported-secret")
    end

    it "counts GITHUB_TOKEN as exported, which gh also reads" do
      account = account_for("joel-fuze", env: { "GITHUB_TOKEN" => "exported-secret" })

      expect(account.environment).to eq("GH_TOKEN" => "exported-secret")
      expect(said.first).to include("GITHUB_TOKEN")
    end
  end

  describe "an account gh does not know" do
    it "refuses on use, naming the account and the fix" do
      account = account_for("nobody")

      expect { account.environment }.to raise_error(described_class::Refused) { |error|
        expect(error).to be_a(Lain::Error)
        expect(error.message).to include("nobody").and include("gh auth login")
      }
    end

    it "asks again after a refusal, so a login made since is picked up" do
      account = account_for("nobody")
      2.times { expect { account.environment }.to raise_error(described_class::Refused) }

      expect(factory.argvs.size).to eq(2)
    end
  end

  it "refuses when no gh is installed, saying gh was not found" do
    absent = Class.new { define_method(:run_command) { raise Errno::ENOENT, "gh" } }.new
    account = described_class.for(github("joel-fuze"), env: {}, shell_out_factory: GhParity::FakeGh.new { absent },
                                                       notes:)

    expect { account.environment }.to raise_error(described_class::Refused, /gh was not found/)
  end

  it "refuses when gh cannot be run, saying why rather than that it is missing" do
    denied = Class.new { define_method(:run_command) { raise Errno::EACCES, "gh" } }.new
    account = described_class.for(github("joel-fuze"), env: {}, shell_out_factory: GhParity::FakeGh.new { denied },
                                                       notes:)

    expect { account.environment }.to raise_error(described_class::Refused) { |error|
      expect(error.message).to include("gh could not be run (Permission denied - gh)").and include("joel-fuze")
      expect(error.message).not_to include("not found")
    }
  end

  it "refuses an empty token rather than lending one" do
    empty = GhParity::FakeGhShellOut.new(0, "\n", "")
    account = described_class.for(github("joel-fuze"), env: {}, shell_out_factory: GhParity::FakeGh.new { empty },
                                                       notes:)

    expect { account.environment }.to raise_error(described_class::Refused, /joel-fuze/)
  end

  it "refuses a token gh printed while exiting non-zero" do
    failed = GhParity::FakeGhShellOut.new(1, "t0k\n", "token store is locked")
    account = described_class.for(github("joel-fuze"), env: {}, shell_out_factory: GhParity::FakeGh.new { failed },
                                                       notes:)

    expect { account.environment }.to raise_error(described_class::Refused, /joel-fuze/)
  end

  it "shows the account name and never the token when inspected, alone or inside a Gh" do
    account = account_for("joel-fuze")
    account.environment

    expect(account.inspect).to include("joel-fuze")
    expect([account.inspect, Lain::Forge::Gh.new(account:).inspect]).to all(satisfy { |text| !text.include?("t0k") })
  end

  # Two gh children starting together must share 1 token ask. The first ask is held open until the
  # second thread has stopped, which it does at the lock; without the lock it would ask gh itself.
  it "asks gh once when 2 threads want the token at the same time" do
    entered = Queue.new
    release = Queue.new
    asks = GhParity::FakeGh.new do
      if asks.argvs.size == 1
        entered << true
        release.pop
      end
      GhParity::FakeGhShellOut.new(0, "t0k\n", "")
    end
    account = described_class.for(github("joel-fuze"), env: {}, shell_out_factory: asks, notes:)

    first = Thread.new { account.environment }
    entered.pop
    second = Thread.new { account.environment }
    Thread.pass until second.stop?
    release << true

    expect([first.value, second.value]).to all(eq("GH_TOKEN" => "t0k"))
    expect(asks.argvs.size).to eq(1)
  end

  describe ".configured" do
    around do |example|
      Dir.mktmpdir("lain-gh-configured") do |tmp|
        @tmp = tmp
        with_env("LAIN_GH_ACCOUNT" => nil) { example.run }
      end
    end

    let(:root) { File.join(@tmp, "project").tap { |dir| FileUtils.mkdir_p(dir) } }

    it "builds the account a project's config names" do
      write_config(root, "github account: \"#{GhParity::ACCOUNT}\"\n")

      account = described_class.configured(root:, notes:, shell_out_factory: factory)

      expect(account.environment).to eq("GH_TOKEN" => GhParity::TOKEN)
    end

    it "is None when no config names one" do
      account = described_class.configured(root:, notes:, shell_out_factory: factory)

      expect(account).to be_a(described_class::None)
    end
  end

  describe "no account" do
    it "is None, which lends nothing and asks nothing" do
      unset = Lain::Config::Github.resolve(project: Lain::Config::Github.empty, user: Lain::Config::Github.empty,
                                           env: {})
      account = described_class.for(unset, env: { "GH_TOKEN" => "exported" }, shell_out_factory: factory, notes:)

      expect(account).to be_a(described_class::None)
      expect(account.environment).to eq({})
      expect(factory.argvs).to be_empty
      expect(said).to be_empty
    end
  end
end
