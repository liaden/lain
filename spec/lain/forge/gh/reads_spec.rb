# frozen_string_literal: true

RSpec.describe Lain::Forge::Gh::Reads do
  let(:account) { instance_double(Lain::Forge::Gh::Account, environment: { "GH_TOKEN" => "t0k" }) }
  let(:calls) { [] }
  let(:answer) { Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }.new("out", "", 0) }
  let(:factory) do
    lambda do |*argv, **options|
      calls << [argv, options]
      answer
    end
  end
  let(:reads) { described_class.new(cwd: "/work", account:, timeout: 7, shell_out_factory: factory) }

  describe "#pr_refs" do
    it "asks gh for the three ref fields as the account, in the caller's directory" do
      reads.pr_refs(ref: "12")

      expect(calls).to eq([[%w[gh pr view 12 --json baseRefName,baseRefOid,headRefOid],
                            { cwd: "/work", timeout: 7, environment: { "GH_TOKEN" => "t0k" } }]])
    end

    it "hands back the finished subprocess whatever its exit" do
      expect(reads.pr_refs(ref: "12")).to be(answer)
    end
  end

  describe "#pr_diff" do
    it "asks gh for the combined diff as the account" do
      reads.pr_diff(ref: "https://github.com/o/r/pull/12")

      expect(calls.first).to eq([%w[gh pr diff https://github.com/o/r/pull/12],
                                 { cwd: "/work", timeout: 7, environment: { "GH_TOKEN" => "t0k" } }])
    end
  end

  it "runs under the parent's environment when no account is configured" do
    described_class.new(cwd: "/work", account: Lain::Forge::Gh::Account::None.new,
                        shell_out_factory: factory).pr_diff(ref: "1")

    expect(calls.first.last).to include(environment: {}, timeout: Lain::Forge::Gh::DEFAULT_TIMEOUT)
  end

  it "lets an account gh cannot lend a token for raise, spawning nothing" do
    allow(account).to receive(:environment).and_raise(Lain::Forge::Gh::Account::Refused, "no token for nobody")

    expect { reads.pr_refs(ref: "12") }.to raise_error(Lain::Forge::Gh::Account::Refused, /nobody/)
    expect(calls).to be_empty
  end

  it "never lets the token reach its own inspect" do
    expect(reads.inspect).not_to include("t0k")
  end
end
