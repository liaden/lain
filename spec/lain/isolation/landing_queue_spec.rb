# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Drives real git in a throwaway repository it creates itself, never the lain
# repository it runs in: an epic branch the parent checkout stands on, and
# workers whose commits are anchored where a handback anchors them.
RSpec.describe Lain::Isolation::LandingQueue, :seam do
  include HeldParentLock

  subject(:queue) { queue_with(retries:, verify:) }

  around do |example|
    Dir.mktmpdir("lain-landing-queue") do |repo|
      @repo = File.realpath(repo)
      FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", @repo)
      git("switch", "-q", "-c", "epic/demo")
      File.write(File.join(@repo, ".git", "info", "exclude"), ".state/\n")
      example.run
    end
  end

  let(:journal) { [] }
  let(:retries) { 1 }
  let(:verified) { [] }
  let(:verify) do
    lambda do |candidate|
      verified << candidate
      described_class::Verification.new(outcome: :passed, tip: candidate.sha)
    end
  end
  # Built by name rather than read off HEAD, so an example that switches the
  # parent away still holds the queue to the epic branch.
  let(:base) do
    Lain::Isolation::WorkingBranch.new("epic/demo", repo_root: @repo, git: Lain::Isolation::Checkout.new(@repo))
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@repo, ".state"), "HOME" => @repo }) }

  def queue_with(retries: 1, verify: Lain::Isolation::Verifier::Skipped, **)
    desk = Lain::Isolation::CandidateDesk.new(
      repo_root: @repo, base:, journal:, strategy: Lain::Isolation::MergeStrategy::DEFAULT,
      home: Lain::Isolation::MergeCoordinator::Home.for(repo_root: @repo, branch: "epic/demo"),
      checkout: Lain::Isolation::VerifyCheckout.for(repo_root: @repo, branch: "epic/demo", paths:, keep: []),
      shell_out_factory: Lain::Shell::Out.public_method(:new)
    )
    described_class.new(repo_root: @repo, base:, desk:, retries:, verify:, **)
  end

  def seed_files = { "f" => "a\nb\nc\n", "h" => "x\n" }

  # Scrubbed exactly as the subject scrubs, so a pre-commit hook's
  # GIT_INDEX_FILE never points these calls at lain's own index.
  def shell(*args)
    Lain::Shell::Out.new("git", "-C", @repo, *args,
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command
  end

  def git(*) = SeedRepo.git(@repo, *).stdout.strip

  def tip = git("rev-parse", "refs/heads/epic/demo")

  def contains?(sha) = shell("merge-base", "--is-ancestor", sha, "refs/heads/epic/demo").exitstatus.zero?

  def merging? = shell("rev-parse", "--verify", "--quiet", "MERGE_HEAD").exitstatus.zero?

  # A worker's committed work, cut from the branch tip and anchored under the
  # ref a handback would write, with the parent put back on the epic branch.
  def worker(id, from: tip, **files)
    git("switch", "-q", "--detach", from)
    files.each { |path, body| File.write(File.join(@repo, path), body) }
    git("add", *files.keys)
    git("commit", "-q", "-m", "#{id} work")
    sha = git("rev-parse", "HEAD")
    ref = Lain::Isolation::Worktree::Handback::Naming.new(id).ref
    git("update-ref", ref, sha)
    git("switch", "-q", "epic/demo")
    described_class::Worker.new(id:, ref:, sha:)
  end

  def handbacks = journal.grep(Lain::Telemetry::Handback)

  describe "re-sync waits until the queue drains" do
    it "lands w2 before w3 is asked, asks w3 once and verifies once" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w2 = worker("w2", "h" => "y\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")
      asked = []
      resync = lambda do |stale, tip:|
        asked << { id: stale.id, tip: }
        nil
      end

      result = queue.call([w1, w2, w3], resync:)

      expect(asked).to eq([{ id: "w3", tip: result.report("w2").sha }])
      expect(verified.map(&:sha)).to eq([tip])
      expect([w1, w2].map(&:sha)).to all(satisfy { |sha| contains?(sha) })
      expect(result.report("w3").kind).to eq(:conflicted)
    end

    # The reports and the journal are asserted off ONE run: they are two
    # projections of the same landing, and driving real git twice to read each
    # separately cost a merge and some twenty git spawns per suite run for
    # facts already established.
    it "measures each landing -- a fast-forward, then a merge -- and journals one record per landing" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w2 = worker("w2", "h" => "y\n")

      result = queue.call([w1, w2])

      expect(result.report("w1")).to have_attributes(kind: :merged, sha: w1.sha, fast_forward: true, ref: w1.ref)
      expect(result.report("w2")).to have_attributes(kind: :merged, sha: tip, fast_forward: false, ref: w2.ref)
      expect(handbacks.map { |record| [record.worker_key, record.outcome, record.fast_forward] })
        .to eq([["w1", :merged, true], ["w2", :merged, false]])
      expect(handbacks.map(&:ref)).to eq([w1.ref, w2.ref])
      expect(handbacks.map(&:sha)).to eq([w1.sha, tip])
      expect(handbacks.map(&:strategy)).to all(eq(Lain::Isolation::MergeStrategy::DEFAULT.to_s))
      expect(verified.map(&:sha)).to eq([tip])
    end
  end

  # A worker's commits are never optional, so one the queue could not anchor
  # anywhere is refused before it is queued.
  describe "a worker is always anchored" do
    it "refuses a worker with no ref" do
      expect { described_class::Worker.new(id: "w", sha: "a" * 40) }.to raise_error(ArgumentError, /ref/)
      expect { described_class::Worker.new(id: "w", sha: "a" * 40, ref: nil) }.to raise_error(ArgumentError, /ref/)
    end
  end

  describe "what does not integrate" do
    it "answers nothing_to_do for a commit the branch already holds, and verifies nothing" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      git("merge", "-q", "--ff-only", w1.sha)

      result = queue.call([w1])

      expect(result.report("w1").kind).to eq(:nothing_to_do)
      expect(handbacks).to be_empty
      expect(verified).to be_empty
    end

    it "leaves a standing conflict anchored and the parent untouched, by default" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")

      result = queue.call([w1, w3])

      expect(result.report("w3"))
        .to have_attributes(kind: :conflicted, ref: w3.ref, paths: ["f"], detail: Lain::Isolation::CandidateDesk::STANDS)
      expect(tip).to eq(w1.sha)
      expect(merging?).to be(false)
      expect(git("rev-parse", w3.ref)).to eq(w3.sha)
    end

    it "asks nobody to re-sync when rebase_retries is 0" do
      queue = queue_with(retries: 0, verify:)
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")
      asked = []

      result = queue.call([w1, w3], resync: ->(stale, tip:) { asked << [stale.id, tip] })

      expect(asked).to be_empty
      expect(result.report("w3").kind).to eq(:conflicted)
    end

    it "asks a stale worker up to rebase_retries times" do
      queue = queue_with(retries: 3, verify:)
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")
      asked = []

      resync = lambda do |stale, tip:|
        asked << [stale.id, tip]
        nil
      end

      result = queue.call([w1, w3], resync:)

      expect(asked.map(&:first)).to eq(%w[w3 w3 w3])
      expect(result.report("w3").kind).to eq(:conflicted)
    end

    it "stops asking once a re-sync integrates" do
      queue = queue_with(retries: 3, verify:)
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")
      asked = 0
      resync = lambda do |_stale, tip:|
        asked += 1
        worker("w3-rebased", "f" => "a\nB1 then B3\nc\n", from: tip).sha if asked == 2
      end

      expect(queue.call([w1, w3], resync:).report("w3").kind).to eq(:merged)
      expect(asked).to eq(2)
    end

    it "lands a re-synced commit that now integrates, and moves the anchor to it" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")
      rebased = nil
      resync = lambda do |_stale, tip:|
        rebased = worker("w3-rebased", "f" => "a\nB1 then B3\nc\n", from: tip).sha
      end

      result = queue.call([w1, w3], resync:)

      expect(result.report("w3")).to have_attributes(kind: :merged, sha: rebased, fast_forward: true)
      expect(git("rev-parse", w3.ref)).to eq(rebased)
    end
  end

  describe "verification" do
    it "is skipped, saying so, when no verify is given" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")

      result = queue_with.call([w1])

      expect(result.verification).to eq(described_class::Verification.new(
                                          outcome: :skipped, tip:, detail: Lain::Isolation::Verifier::Skipped::DETAIL
                                        ))
      expect(result.stale_tip).to be(false)
    end
  end

  describe "building a queue" do
    it "needs a desk" do
      expect { described_class.new(repo_root: @repo, base:) }.to raise_error(ArgumentError, /desk/)
    end

    it "refuses a working branch that names nothing" do
      nameless = Lain::Isolation::WorkingBranch::NONE
      desk = instance_double(Lain::Isolation::CandidateDesk)

      expect { described_class.new(repo_root: @repo, base: nameless, desk:) }
        .to raise_error(described_class::Refused, /working branch/)
    end
  end

  # The queue the epic landings and the drainer build: the batch is a
  # candidate commit verified in the project's scratch checkout, and the
  # branch moves only once verification has not failed.
  describe ".candidate" do
    def isolation(command) = Lain::Config::Isolation.from({ "verify" => ["sh", "-c", command] }, path: nil)

    def candidate(command, root: @repo, **)
      described_class.candidate(root:, base:, journal:, isolation: isolation(command), paths:, **)
    end

    def verify_tree = Lain::Isolation::VerifyCheckout.for(repo_root: @repo, branch: "epic/demo", paths:, keep: []).path

    it "lands a verified batch as one candidate, checked in the project's scratch checkout" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      git("commit", "-q", "--allow-empty", "-m", "a sibling landed")

      result = candidate("exit 0").call([w1])

      expect(result.verification.outcome).to eq(:passed)
      expect(contains?(w1.sha)).to be(true)
      expect(git("worktree", "list", "--porcelain")).to include("worktree #{verify_tree}\n")
      expect(handbacks.map { |record| record.outcome.to_s }).to eq(["merged"])
    end

    it "leaves the branch and the journal alone when verification fails" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      before = tip

      result = candidate("exit 1").call([w1])

      expect(result.report("w1").kind).to eq(:declined)
      expect(tip).to eq(before)
      expect(handbacks).to be_empty
    end

    it "hands the desk a lock it was given, and none of its own otherwise" do
      lock = Lain::FileLock.new(File.join(@repo, ".git", "held.lock"))
      built = []
      desk = instance_double(Lain::Isolation::CandidateDesk, strategy: Lain::Isolation::MergeStrategy::DEFAULT)
      recorder = Class.new do
        define_singleton_method(:new) do |**keywords|
          built << keywords
          desk
        end
      end
      stub_const("Lain::Isolation::CandidateDesk", recorder)

      candidate("exit 0", lock:)
      candidate("exit 0")

      expect(built.map { |keywords| keywords[:lock] }).to eq([lock, nil])
      expect(built.last).not_to have_key(:lock)
    end
  end

  describe ".candidate run from a linked worktree" do
    it "verifies in the scratch checkout keyed by the main worktree" do
      linked = File.join(@repo, ".state", "linked")
      git("worktree", "add", "-q", "--detach", linked)
      w1 = worker("w1", "f" => "a\nB1\nc\n")

      described_class.candidate(root: linked, base:, journal:, paths:,
                                isolation: Lain::Config::Isolation.from({ "verify" => %w[true] }, path: nil))
                     .call([w1])

      keyed = Lain::Isolation::VerifyCheckout.for(repo_root: @repo, branch: "epic/demo", paths:, keep: []).path
      expect(git("worktree", "list", "--porcelain")).to include("worktree #{keyed}\n")
    end

    it "judges the candidate by a verify it is given in place of the configured one" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      judged = []
      verify = lambda do |candidate|
        judged << candidate.sha
        Lain::Isolation::LandingQueue::Verification.new(outcome: :passed, tip: candidate.sha)
      end

      described_class.candidate(root: @repo, base:, journal:, paths:, verify:,
                                isolation: Lain::Config::Isolation.from({ "verify" => %w[false] }, path: nil))
                     .call([w1])

      expect([judged.size, contains?(w1.sha)]).to eq([1, true])
    end
  end

  describe "the landing lock" do
    it "waits while another process -- a chat's handback, say -- holds the parent checkout" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      landing = nil

      while_held_elsewhere(@repo) do
        landing = Thread.new { queue.call([w1]) }
        expect(landing.join(0.5)).to be_nil
        expect(contains?(w1.sha)).to be(false)
      end

      expect(landing.value.report("w1").kind).to eq(:merged)
    end

    def free?
      Lain::Isolation::MergeCoordinator::Home.for(repo_root: @repo, branch: "epic/demo").drain_lock.try { nil }
    end

    it "holds the branch's drain lock for the whole run, and releases it after" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      during = nil
      queue = queue_with(verify: lambda { |candidate|
        during = free?
        described_class::Verification.new(outcome: :passed, tip: candidate.sha)
      })

      queue.call([w1])

      expect(during).to be(false)
      expect(free?).to be(true)
    end
  end
end
