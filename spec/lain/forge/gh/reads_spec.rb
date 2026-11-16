# frozen_string_literal: true

require "stringio"

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

  describe "#review_requests" do
    let(:fixture) { File.read("spec/fixtures/gh/review_requests.json") }
    let(:answer) do
      Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }.new(fixture, "", 0)
    end
    let(:query) { "is:open is:pr review-requested:@me archived:false" }

    it "parses the one response into requests, drafts dropped" do
      expect(reads.review_requests(query:).map(&:number)).to eq([11, 12, 13, 15, 16])
    end

    it "keeps a request of a team I only administer, org-qualified" do
      expect(reads.review_requests(query:).last).to have_attributes(number: 16, via: :team, team: "acme/leads")
    end

    it "runs exactly 1 gh process, a graphql call carrying the search as a variable" do
      reads.review_requests(query:)

      expect(calls.size).to eq(1)
      argv, options = calls.first
      expect(argv.first(3)).to eq(%w[gh api graphql])
      expect(argv).to include("q=#{query}")
      expect(options).to eq(cwd: "/work", timeout: 7, environment: { "GH_TOKEN" => "t0k" })
    end

    it "keeps the token out of argv" do
      reads.review_requests(query:)

      expect(calls.first.first.join).not_to include("t0k")
    end

    it "keeps the token out of a refusal" do
      limited = Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }.new("", "bad credentials", 1)
      reads = described_class.new(cwd: "/work", account:, shell_out_factory: ->(*, **) { limited })

      expect { reads.review_requests(query:) }.to raise_error(Lain::Forge::Gh::Reads::Refused) { |e|
        expect(e.message).not_to include("t0k")
      }
    end

    it "refuses with gh's own message when gh exits non-zero" do
      limited = Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }
                    .new("", "GraphQL: API rate limit exceeded", 1)
      reads = described_class.new(cwd: "/work", account:, shell_out_factory: ->(*, **) { limited })

      expect { reads.review_requests(query:) }
        .to raise_error(Lain::Forge::Gh::Reads::Refused, /rate limit exceeded/)
    end

    it "refuses when GraphQL answers with errors" do
      errored = Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }
                    .new('{"errors":[{"message":"Bad credentials"}]}', "", 0)
      reads = described_class.new(cwd: "/work", account:, shell_out_factory: ->(*, **) { errored })

      expect { reads.review_requests(query:) }.to raise_error(Lain::Forge::Gh::Reads::Refused, /Bad credentials/)
    end
  end

  describe "#matches" do
    let(:fixture) { File.read("spec/fixtures/gh/review_requests.json") }
    let(:answer) do
      Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }.new(fixture, "", 0)
    end
    let(:query) { "is:open is:pr archived:false org:acme" }

    it "returns every open PR the search names, asked of me or not, as a match" do
      found = reads.matches(query:)

      expect(found.map(&:number)).to eq([11, 12, 13, 15, 16])
      expect(found.map(&:via).uniq).to eq([:match])
    end

    it "runs exactly 1 gh process carrying the search as a variable" do
      reads.matches(query:)

      expect(calls.map { |argv, _| argv.first(3) }).to eq([%w[gh api graphql]])
      expect(calls.first.first).to include("q=#{query}")
    end

    it "does not fetch my organizations and teams, which a match never reads" do
      reads.matches(query:)
      reads.review_requests(query:)

      sent = calls.map { |argv, _| argv.find { |arg| arg.start_with?("query=") } }
      expect([sent.first.include?("organizations("), sent.last.include?("organizations(")]).to eq([false, true])
    end

    it "notes how many matches the search cap hid" do
      capped = JSON.parse(fixture).tap { |doc| doc["data"]["search"]["issueCount"] = 120 }
      shell = Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }.new(JSON.dump(capped), "", 0)
      notes = StringIO.new
      described_class.new(cwd: "/work", account:, shell_out_factory: ->(*, **) { shell }).matches(query:, notes:)

      expect(notes.string).to eq("search matched 120 pull requests and showed 6; 114 not shown\n")
    end

    it "notes nothing when the search showed every match" do
      full = JSON.parse(fixture).tap { |doc| doc["data"]["search"]["issueCount"] = 6 }
      shell = Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }.new(JSON.dump(full), "", 0)
      notes = StringIO.new
      described_class.new(cwd: "/work", account:, shell_out_factory: ->(*, **) { shell }).matches(query:, notes:)

      expect(notes.string).to eq("")
    end

    it "refuses with gh's own message when gh exits non-zero" do
      limited = Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }.new("", "rate limited", 1)
      reads = described_class.new(cwd: "/work", account:, shell_out_factory: ->(*, **) { limited })

      expect { reads.matches(query:) }.to raise_error(Lain::Forge::Gh::Reads::Refused, /rate limited/)
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
