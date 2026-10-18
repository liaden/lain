# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::Verifier do
  around do |example|
    Dir.mktmpdir("lain-verifier") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @dir, "HOME" => @dir }) }

  def isolation(**table) = Lain::Config::Isolation.from(table.transform_keys(&:to_s), path: nil)

  def verification_of(**) = Lain::Isolation::LandingQueue::Verification.new(**)

  def git(repo, *) = SeedRepo.git(repo, *).stdout.strip

  describe "the command strategy", :seam do
    it "passes the candidate it was given when the command exits 0 in the checkout" do
      checkout = File.join(@dir, "checkout")
      FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED.merge("ok" => ""))}/.", FileUtils.mkdir_p(checkout).first)
      sha = git(checkout, "rev-parse", "HEAD")
      verifier = described_class.from(isolation(verify: ["sh", "-c", "test -f ok"]), paths:)

      verification = verifier.call(Lain::Isolation::Candidate.new(sha:, path: checkout))

      expect([verification.outcome, verification.tip]).to eq([:passed, sha])
    end
  end

  it "skips when no verify argv is configured, saying so" do
    candidate = Lain::Isolation::Candidate.new(sha: "c" * 40, path: @dir)

    verification = described_class.from(isolation, paths:).call(candidate)

    expect(verification).to eq(verification_of(outcome: :skipped, tip: "c" * 40,
                                               detail: "no verification is configured"))
  end

  describe "a third strategy", :seam do
    let(:answered) { verification_of(outcome: :passed, tip: "p" * 40) }
    let(:judged) { [] }
    let(:probe) do
      answer = answered
      sink = judged
      lambda do |table, paths:, shell_out_factory:|
        sink << [table.verifier, paths, shell_out_factory]
        ->(_candidate) { answer }
      end
    end
    let(:table) { instance_double(Lain::Config::Isolation, verifier: "probe") }

    it "is built by its registered name and lands a queue as its verify" do
      repo = File.join(@dir, "repo")
      FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", FileUtils.mkdir_p(repo).first)
      git(repo, "switch", "-q", "-c", "epic/demo")
      git(repo, "switch", "-q", "--detach")
      File.write(File.join(repo, "w"), "work\n")
      git(repo, "add", "w")
      git(repo, "commit", "-q", "-m", "w1 work")
      sha = git(repo, "rev-parse", "HEAD")
      ref = Lain::Isolation::Worktree::Handback::Naming.new("w1").ref
      git(repo, "update-ref", ref, sha)
      git(repo, "switch", "-q", "epic/demo")
      base = Lain::Isolation::WorkingBranch.new("epic/demo", repo_root: repo,
                                                             git: Lain::Isolation::Checkout.new(repo))

      verify = described_class.from(table, paths:, strategies: { "probe" => probe })
      queue = Lain::Isolation::LandingQueue.candidate(root: repo, base:, journal: [], paths:, verify:,
                                                      isolation: isolation(verify: %w[true]))
      result = queue.call([Lain::Isolation::LandingQueue::Worker.new(id: "w1", ref:, sha:)])

      expect([result.verification, judged])
        .to eq([answered, [["probe", paths, Lain::Shell::Out.public_method(:new)]]])
    end
  end
end
