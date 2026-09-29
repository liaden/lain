# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "tmpdir"

# Drives real git in a throwaway repository it creates itself, never the lain
# repository it runs in: an epic branch the parent checkout stands on, and
# workers whose commits are anchored where a handback anchors them.
RSpec.describe Lain::Isolation::LandingQueue, :seam do
  include HeldParentLock

  subject(:queue) { described_class.new(repo_root: @repo, base:, journal:, retries:, resolver:, verify:) }

  around do |example|
    Dir.mktmpdir("lain-landing-queue") do |repo|
      @repo = File.realpath(repo)
      FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", @repo)
      git("switch", "-q", "-c", "epic/demo")
      example.run
    end
  end

  let(:journal) { [] }
  let(:retries) { 1 }
  let(:resolver) { described_class::Resolver::Standing }
  let(:verified) { [] }
  let(:verify) do
    lambda do |tip|
      verified << tip
      described_class::Verification.new(outcome: :passed, tip:)
    end
  end
  # Built by name rather than read off HEAD, so an example that switches the
  # parent away still holds the queue to the epic branch.
  let(:base) do
    Lain::Isolation::WorkingBranch.new("epic/demo", repo_root: @repo, git: Lain::Isolation::Checkout.new(@repo))
  end

  def seed_files = { "f" => "a\nb\nc\n", "h" => "x\n" }

  # Scrubbed exactly as the subject scrubs, so a pre-commit hook's
  # GIT_INDEX_FILE never points these calls at lain's own index.
  def shell(*args)
    Mixlib::ShellOut.new("git", "-C", @repo, *args,
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command
  end

  def git(*) = shell(*).tap(&:error!).stdout.strip

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

  describe "re-sync waits until the queue drains, and leftovers share one resolver" do
    let(:spawned) { [] }
    let(:resolver) { described_class::Resolver::Spawned.new(spawn:) }
    # What a merge_resolver child does with its file tools: rewrite the
    # conflicted file with both sides kept and every marker gone.
    let(:spawn) do
      lambda do |role, mode, prompt|
        spawned << { role:, mode:, prompt: }
        File.write(File.join(@repo, "f"), "a\nB1 and B3\nc\n")
        Lain::Tool::Result.ok("kept both sides")
      end
    end

    it "lands w2 before w3 is asked, asks w3 once, spawns one resolver and verifies once" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w2 = worker("w2", "h" => "y\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")
      asked = []
      resync = lambda do |stale, tip:|
        asked << { id: stale.id, tip:, holding_w2: contains?(w2.sha) }
        nil
      end

      result = queue.call([w1, w2, w3], resync:)

      expect(asked).to eq([{ id: "w3", tip: result.report("w2").sha, holding_w2: true }])
      expect(spawned.size).to eq(1)
      expect(spawned.first).to include(role: :merge_resolver, mode: :fresh)
      expect(verified).to eq([tip])
      expect([w1, w2, w3].map(&:sha)).to all(satisfy { |sha| contains?(sha) })
      expect(result.report("w3").kind).to eq(:resolved)
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
    end

    it "gives the one resolver every leftover, in the intended order" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")
      w4 = worker("w4", "f" => "a\nB4\nc\n")

      queue.call([w1, w3, w4])

      prompt = spawned.first[:prompt]
      expect(prompt.index(w3.ref)).to be < prompt.index(w4.ref)
      expect(prompt).to include(File.join(@repo, "f").inspect)
    end

    # The one resolver is ONE: a second leftover that still conflicts once the
    # first is resolved stands, anchored, with the parent put back.
    # A record's ref names where the work is anchored; the commit rides `sha`.
    it "journals every record of a resolved worker under its anchor ref, never its commit" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")

      queue.call([w1, w3])

      expect(handbacks.select { |record| record.worker_key == "w3" }.map(&:ref).uniq).to eq([w3.ref])
    end

    it "spawns once for two leftovers, and the second stands with the parent clean" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")
      w4 = worker("w4", "f" => "a\nB4\nc\n")

      result = queue.call([w1, w3, w4])

      expect(spawned.size).to eq(1)
      expect(result.report("w3").kind).to eq(:resolved)
      expect(result.report("w4")).to have_attributes(kind: :conflicted, ref: w4.ref)
      expect(merging?).to be(false)
      expect(git("rev-parse", w4.ref)).to eq(w4.sha)
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

  describe "the parent must be standing on the working branch" do
    it "refuses, naming both branches, and lands nothing" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      git("switch", "-q", "-c", "other")

      expect { queue.call([w1]) }.to raise_error(described_class::Refused) { |error|
        expect(error.message).to include("other").and include("epic/demo")
      }
      expect(contains?(w1.sha)).to be(false)
    end

    it "refuses a working branch that names nothing" do
      expect { described_class.new(repo_root: @repo, base: Lain::Isolation::WorkingBranch::NONE) }
        .to raise_error(described_class::Refused, /working branch/)
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

      expect(result.report("w3")).to have_attributes(kind: :conflicted, ref: w3.ref, paths: ["f"])
      expect(tip).to eq(w1.sha)
      expect(merging?).to be(false)
      expect(git("rev-parse", w3.ref)).to eq(w3.sha)
    end

    it "asks nobody to re-sync when rebase_retries is 0" do
      queue = described_class.new(repo_root: @repo, base:, journal:, retries: 0, verify:)
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      w3 = worker("w3", "f" => "a\nB3\nc\n")
      asked = []

      result = queue.call([w1, w3], resync: ->(stale, tip:) { asked << [stale.id, tip] })

      expect(asked).to be_empty
      expect(result.report("w3").kind).to eq(:conflicted)
    end

    it "asks a stale worker up to rebase_retries times" do
      queue = described_class.new(repo_root: @repo, base:, journal:, retries: 3, verify:)
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
      queue = described_class.new(repo_root: @repo, base:, journal:, retries: 3, verify:)
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

    def lock_path
      File.join(git("rev-parse", "--path-format=absolute", "--git-common-dir"), Lain::Isolation::ParentLock::NAME)
    end

    def free?
      File.open(lock_path, File::RDWR | File::CREAT) { |file| file.flock(File::LOCK_EX | File::LOCK_NB) }
    end

    it "is held for the whole run, under the repository's git dir, and released after" do
      w1 = worker("w1", "f" => "a\nB1\nc\n")
      during = nil
      queue = described_class.new(repo_root: @repo, base:, journal:,
                                  verify: lambda { |tip|
                                    during = free?
                                    described_class::Verification.new(outcome: :passed, tip:)
                                  })

      queue.call([w1])

      expect(during).to be(false)
      expect(free?).to be_truthy
    end
  end
end
