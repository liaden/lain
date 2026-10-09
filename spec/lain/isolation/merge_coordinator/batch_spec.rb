# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::MergeCoordinator::Batch, :seam do
  around do |example|
    Dir.mktmpdir("lain-batch") do |repo|
      Dir.mktmpdir("lain-batch-state") do |state|
        @repo = File.realpath(repo)
        @state = File.realpath(state)
        FileUtils.cp_r("#{SeedRepo.at({ "f" => "a\n" })}/.", @repo)
        git("branch", "-M", "main")
        example.run
      end
    end
  end

  let(:queue_class) { Lain::Isolation::LandingQueue }
  let(:verified) { [] }
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => @state, "XDG_STATE_HOME" => @state }) }
  let(:queue_for) { -> { queue_class.new(repo_root: @repo, base:, desk:, verify:) } }
  let(:cap) { 2 }
  let(:batch) { described_class.new(queue_for:, rebuild_cap: cap) }
  let(:bad) { "none" }
  let(:races) { ->(_passes) { false } }
  let(:passes) { [] }
  let(:verify) do
    lambda do |candidate|
      verified << candidate.sha
      if File.exist?(File.join(candidate.path, bad))
        verdict(:failed, detail: "spec/#{bad}_spec.rb:4 expected true, got false")
      else
        passes << candidate.sha
        race if races.call(passes.size)
        verdict(:passed)
      end
    end
  end

  def base = Lain::Isolation::WorkingBranch.new("main", repo_root: @repo, git: Lain::Isolation::Checkout.new(@repo))

  def desk
    Lain::Isolation::CandidateDesk.new(
      repo_root: @repo, base:, journal: [], strategy: Lain::Isolation::MergeStrategy::DEFAULT,
      home: Lain::Isolation::MergeCoordinator::Home.for(repo_root: @repo, branch: "main"),
      checkout: Lain::Isolation::VerifyCheckout.for(repo_root: @repo, branch: "main", paths:, keep: []),
      shell_out_factory: Lain::Shell::Out.public_method(:new)
    )
  end

  def git(*) = SeedRepo.git(@repo, *).stdout.strip

  def tip = git("rev-parse", "refs/heads/main")

  def on_branch?(sha)
    Lain::Shell::Out.new("git", "-C", @repo, "merge-base", "--is-ancestor", sha, "refs/heads/main",
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.exitstatus.zero?
  end

  def worker(id, from: tip, files: { id => "#{id}\n" })
    git("switch", "-q", "--detach", from)
    files.each { |path, body| File.write(File.join(@repo, path), body) }
    git("add", *files.keys)
    git("commit", "-q", "-m", "#{id} work")
    sha = git("rev-parse", "HEAD")
    ref = Lain::Isolation::Worktree::Handback::Naming.new(id).ref
    git("update-ref", ref, sha)
    git("switch", "-q", "main")
    queue_class::Worker.new(id:, ref:, sha:)
  end

  def verdict(outcome, detail: "") = queue_class::Verification.new(outcome:, tip: verified.last, detail:)

  def commit(name, body)
    File.write(File.join(@repo, name), body)
    git("add", name)
    git("commit", "-q", "-m", "#{name} on main")
  end

  def race = commit("racing", "#{verified.size}\n")

  def workers(*ids) = ids.map { |id| worker(id) }

  describe "a batch with one bad commit in four" do
    let(:bad) { "w3" }

    it "finds the bad one, ejects it with the verifier's output, and lands the other three" do
      landing = workers("w1", "w2", "w3", "w4")

      outcome = batch.call(landing)

      expect(landing.map { |each| on_branch?(each.sha) }).to eq([true, true, false, true])
      expect(outcome.reports.map(&:kind)).to eq(%i[merged merged declined merged])
      expect(outcome.reports[2]).to have_attributes(ref: landing[2].ref,
                                                    detail: a_string_including("spec/w3_spec.rb:4 expected true"))
      expect(outcome.verifies).to be <= 5
      expect([outcome.verifies, outcome.rebuilds]).to eq([verified.size, 0])
    end

    it "answers, beside each report, the verification of the run that judged that worker last" do
      outcome = batch.call(workers("w1", "w2", "w3", "w4"))

      expect(outcome.verifications.map(&:outcome)).to eq(%i[passed passed failed passed])
      expect(outcome.verifications.map(&:tip)).to eq(verified.values_at(1, 1, 3, 4))
      expect(outcome.verifications[2].detail).to include("spec/w3_spec.rb:4")
    end
  end

  describe "a batch of five with the fourth bad" do
    let(:bad) { "w4" }

    it "splits the larger half first and lands the rest in 5 verifies" do
      landing = workers("w1", "w2", "w3", "w4", "w5")

      outcome = batch.call(landing)

      expect(outcome.reports.map(&:kind)).to eq(%i[merged merged merged declined merged])
      expect([outcome.verifies, landing.map { |each| on_branch?(each.sha) }])
        .to eq([5, [true, true, true, false, true]])
    end
  end

  describe "a green batch" do
    it "lands all four on one verify and no rebuild, its lists frozen" do
      landing = workers("w1", "w2", "w3", "w4")

      outcome = batch.call(landing)

      expect(landing.map { |each| on_branch?(each.sha) }).to all(be(true))
      expect(outcome.reports.map(&:kind)).to all(eq(:merged))
      expect([outcome.verifies, outcome.rebuilds, verified]).to eq([1, 0, [tip]])
      expect(outcome.verifications.map { |each| [each.outcome, each.tip] }).to all(eq([:passed, tip]))
      expect([outcome.reports, outcome.verifications]).to all(be_frozen)
    end

    context "with a worker conflicting with the tip" do
      it "records no verification for the conflicted worker, since the candidate never held it" do
        older = tip
        commit("f", "TIP\n")
        conflicted = worker("w1", from: older, files: { "f" => "B1\n" })
        clean = worker("w2")

        outcome = batch.call([conflicted, clean])

        expect(outcome.reports.map(&:kind)).to eq(%i[conflicted merged])
        expect(outcome.verifications.map { |each| each&.outcome }).to eq([nil, :passed])
      end
    end

    context "with no verifier configured" do
      let(:verify) { Lain::Isolation::Verifier::Skipped }

      it "lands them and counts no verify, since nothing judged the candidate" do
        landing = workers("w1", "w2")

        outcome = batch.call(landing)

        expect(landing.map { |each| on_branch?(each.sha) }).to all(be(true))
        expect([outcome.reports.map(&:kind), outcome.verifications, outcome.verifies])
          .to eq([%i[merged merged], [nil, nil], 0])
      end
    end
  end

  describe "a branch that moves during every verification" do
    let(:races) { ->(_passes) { true } }

    it "rebuilds up to the cap, then declines every worker naming the moving branch, their work on its ref" do
      landing = workers("w1", "w2")

      outcome = batch.call(landing)

      expect([verified.size, outcome.verifies, outcome.rebuilds]).to eq([3, 3, 2])
      expect(outcome.reports.map(&:ref)).to eq(landing.map(&:ref))
      expect(outcome.reports).to all(have_attributes(kind: :declined,
                                                     detail: "the branch moved 3 times during verification"))
      expect(landing.map { |each| [git("rev-parse", each.ref), on_branch?(each.sha)] })
        .to eq(landing.map { |each| [each.sha, false] })
    end

    context "with a rebuild cap of 0 and workers that never moved" do
      let(:cap) { 0 }

      it "keeps what the desk said of the unmoved ones and gives the moving branch only to the declined" do
        older = tip
        already = worker("w0")
        git("merge", "-q", "--ff-only", already.sha)
        commit("f", "TIP\n")
        conflicted = worker("w1", from: older, files: { "f" => "B1\n" })
        clean = worker("w2")

        outcome = batch.call([already, conflicted, clean])

        expect(outcome.reports.map(&:kind)).to eq(%i[nothing_to_do conflicted declined])
        expect(outcome.reports[1]).to have_attributes(paths: ["f"], ref: conflicted.ref)
        expect(outcome.verifications.map { |each| each&.outcome }).to eq([:passed, nil, :passed])
        expect(outcome.reports[2].detail).to eq("the branch moved once during verification")
        expect([verified.size, outcome.rebuilds]).to eq([1, 0])
      end
    end
  end

  describe "a batch that bisects and rebuilds" do
    let(:bad) { "w3" }
    let(:cap) { 1 }
    let(:races) { ->(passes) { [1, 3].include?(passes) } }

    it "spends one rebuild budget across its halves" do
      landing = workers("w1", "w2", "w3", "w4")

      outcome = batch.call(landing)

      expect(outcome.reports.map(&:kind)).to eq(%i[merged merged declined declined])
      expect(outcome.reports[3].detail).to eq("the branch moved 2 times during verification")
      expect([outcome.rebuilds, outcome.verifies]).to eq([1, 6])
    end
  end
end
