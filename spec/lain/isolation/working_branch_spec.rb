# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

# A Checkout that runs a hook once, right after a chosen git invocation: how
# a sibling's move lands in the one window a race can use.
class WorkingBranchSpecRacingCheckout < Lain::Isolation::Checkout
  def initialize(dir, after:, &hook)
    super(dir)
    @after = after
    @hook = hook
  end

  def run(*args)
    super.tap do
      fire = @hook if @after.call(args)
      @hook = nil if fire
      fire&.call
    end
  end
end

# What a process killed mid-delete looks like from outside: a git invocation
# that never runs.
class WorkingBranchSpecCrash < StandardError; end

# Operates on a THROWAWAY repo copied per example ({SeedRepo}), never the lain
# repo it runs in.
RSpec.describe Lain::Isolation::WorkingBranch, :seam do
  around do |example|
    Dir.mktmpdir("lain-working-branch") do |repo|
      @repo_root = File.realpath(repo)
      FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", @repo_root)
      run_git(@repo_root, "branch", "-M", "main")
      example.run
    end
  end

  def seed_files = { "README" => "seed\n" }

  # Scrubbed exactly as the subject scrubs, so a pre-commit hook's exported
  # GIT_INDEX_FILE cannot point these at lain's own index.
  def run_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  def try_git(dir, *args)
    Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
                    .run_command
  end

  def commit(message)
    File.write(File.join(@repo_root, "README"), "#{message}\n")
    run_git(@repo_root, "commit", "-q", "-am", message)
    sha("HEAD")
  end

  def sha(rev) = run_git(@repo_root, "rev-parse", rev).strip

  def ref?(ref) = try_git(@repo_root, "rev-parse", "--verify", "--quiet", ref).exitstatus.zero?

  def refs(prefix) = run_git(@repo_root, "for-each-ref", "--format=%(refname)", prefix).split("\n")

  describe ".checked_out" do
    it "names the branch HEAD is on" do
      run_git(@repo_root, "switch", "-q", "-c", "feat")

      expect(described_class.checked_out(repo_root: @repo_root).name).to eq("feat")
    end

    it "answers the branch's tip as a full SHA" do
      run_git(@repo_root, "switch", "-q", "-c", "feat")

      expect(described_class.checked_out(repo_root: @repo_root).tip).to eq(sha("feat")).and match(/\A\h{40}\z/)
    end

    # Read per call, never captured: a later lease must see a commit that
    # landed on the branch after launch.
    it "answers a moved tip once the branch moves" do
      run_git(@repo_root, "switch", "-q", "-c", "feat")
      branch = described_class.checked_out(repo_root: @repo_root)
      before = branch.tip

      moved = commit("landed on feat")

      expect([before, branch.tip]).to eq([sha("main"), moved])
    end

    # The branch is NAMED at launch. A human switching the parent checkout
    # afterwards does not re-point the workers at whatever HEAD became.
    it "keeps answering the named branch after HEAD switches away" do
      run_git(@repo_root, "switch", "-q", "-c", "feat")
      feat_tip = commit("feat work")
      branch = described_class.checked_out(repo_root: @repo_root)

      run_git(@repo_root, "switch", "-q", "main")

      expect(branch.tip).to eq(feat_tip)
    end

    it "refuses a detached HEAD, naming git switch as the fix" do
      run_git(@repo_root, "switch", "-q", "--detach", "HEAD")

      expect { described_class.checked_out(repo_root: @repo_root) }
        .to raise_error(described_class::Refused, /detached.*git switch <branch>/m)
    end

    it "refuses a branch with no commit to branch from, naming it" do
      Dir.mktmpdir("lain-unborn") do |empty|
        run_git(empty, "init", "-q", "-b", "fresh")

        expect { described_class.checked_out(repo_root: empty).tip }
          .to raise_error(described_class::Refused, /fresh/)
      end
    end
  end

  describe ".epic" do
    it "creates epic/<slug> at main's tip and marks it lain-owned" do
      branch = described_class.epic("demo", repo_root: @repo_root)

      expect(branch.name).to eq("epic/demo")
      expect(sha("refs/heads/epic/demo")).to eq(sha("main"))
      expect(ref?("refs/lain/owned/heads/epic/demo")).to be(true)
    end

    it "moves nothing when resolved a second time, even after main moves on" do
      described_class.epic("demo", repo_root: @repo_root)
      created = sha("refs/heads/epic/demo")
      marker = sha("refs/lain/owned/heads/epic/demo")
      commit("main moved on")

      again = described_class.epic("demo", repo_root: @repo_root)

      expect(again.tip).to eq(created)
      expect(sha("refs/lain/owned/heads/epic/demo")).to eq(marker)
    end

    # The owned marker is what lets GC delete a merged epic branch, so a branch
    # a human made must never acquire one.
    it "leaves an epic branch lain did not create unmarked" do
      run_git(@repo_root, "branch", "epic/demo")

      described_class.epic("demo", repo_root: @repo_root)

      expect(ref?("refs/lain/owned/heads/epic/demo")).to be(false)
    end

    # The old promotion model wrote per-issue branches at refs/heads/epic/<slug>/<issue>,
    # and git cannot hold a ref and a directory of refs at the same name.
    it "refuses beside per-issue branches, naming them, and deletes none" do
      run_git(@repo_root, "branch", "epic/demo/a")
      run_git(@repo_root, "branch", "epic/demo/b")

      expect { described_class.epic("demo", repo_root: @repo_root) }
        .to raise_error(described_class::Refused, %r{refs/heads/epic/demo/a.*refs/heads/epic/demo/b}m)
      expect(refs("refs/heads/epic/")).to eq(%w[refs/heads/epic/demo/a refs/heads/epic/demo/b])
    end

    it "refuses when there is no main to branch from" do
      run_git(@repo_root, "branch", "-M", "trunk")

      expect { described_class.epic("demo", repo_root: @repo_root) }
        .to raise_error(described_class::Refused, /main/)
    end

    it "refuses a slug git cannot hold in a branch name" do
      expect { described_class.epic("a..b", repo_root: @repo_root) }
        .to raise_error(described_class::Refused, /a\.\.b/)
    end

    # Creation is a compare-and-swap against "must not exist". A sibling that
    # creates the branch first wins; this resolve loses the swap, finds the
    # branch there, and answers it -- never force-moving it, never marking a
    # branch it did not create.
    it "never force-moves a branch a sibling created first, and answers that branch" do
      elsewhere = commit("elsewhere")
      run_git(@repo_root, "reset", "-q", "--hard", "HEAD~1")
      real = Lain::Shell::Out.public_method(:new)
      racing = lambda do |*args, **kwargs|
        run_git(@repo_root, "update-ref", "refs/heads/epic/demo", elsewhere) if args.include?("update-ref")
        real.call(*args, **kwargs)
      end

      branch = described_class.epic("demo", repo_root: @repo_root, shell_out_factory: racing)

      expect(branch.tip).to eq(elsewhere)
      expect(sha("refs/heads/epic/demo")).to eq(elsewhere)
      expect(ref?("refs/lain/owned/heads/epic/demo")).to be(false)
    end

    it "lets concurrent resolves all return, leaving one branch at main's tip and one marker" do
      tips = Array.new(8) { Thread.new { described_class.epic("race", repo_root: @repo_root).tip } }.map(&:value)

      expect(tips.uniq).to eq([sha("main")])
      expect(refs("refs/lain/owned/")).to eq(["refs/lain/owned/heads/epic/race"])
    end

    it "refuses beneath an existing branch it would have to nest under, naming it" do
      run_git(@repo_root, "branch", "epic")

      expect { described_class.epic("x", repo_root: @repo_root) }
        .to raise_error(described_class::Refused, %r{refs/heads/epic\b.*cannot hold})
      expect(refs("refs/heads/")).to include("refs/heads/epic")
    end

    it "refuses a nested slug beneath an existing epic branch, naming it" do
      run_git(@repo_root, "branch", "epic/demo")

      expect { described_class.epic("demo/a", repo_root: @repo_root) }
        .to raise_error(described_class::Refused, %r{refs/heads/epic/demo\b.*cannot hold})
    end
  end

  # The general owned-branch constructor: any name, established from a given
  # base, and reused only where lain's own marker says lain made it.
  describe ".owned" do
    let(:name) { "lain/issue/demo/a" }

    it "creates the branch at the base it is given and marks it lain-owned" do
      base = sha("main")

      branch = described_class.owned(name, repo_root: @repo_root, from: base)

      expect([branch.name, branch.tip]).to eq([name, base])
      expect(sha("refs/lain/owned/heads/#{name}")).to eq(base)
    end

    it "reuses a branch lain owns where it stands, moving nothing and re-marking nothing" do
      described_class.owned(name, repo_root: @repo_root, from: sha("main"))
      created = sha("refs/heads/#{name}")
      moved = commit("main moved on")

      again = described_class.owned(name, repo_root: @repo_root, from: moved)

      expect(again.tip).to eq(created)
      expect(sha("refs/lain/owned/heads/#{name}")).to eq(created)
    end

    # The marker is the only licence anything has to delete a branch later, so
    # claiming one lain did not create would put a human's branch on the
    # reaper's list.
    it "refuses a branch lain did not create, naming it, and neither moves nor marks it" do
      run_git(@repo_root, "branch", name, "main")
      standing = sha("refs/heads/#{name}")
      moved = commit("main moved on")

      expect { described_class.owned(name, repo_root: @repo_root, from: moved) }
        .to raise_error(described_class::Refused, /#{name}.*lain did not create/m)
      expect(sha("refs/heads/#{name}")).to eq(standing)
      expect(ref?("refs/lain/owned/heads/#{name}")).to be(false)
    end

    it "refuses a name git cannot hold in a branch" do
      expect { described_class.owned("lain/issue/demo/a.lock", repo_root: @repo_root, from: sha("main")) }
        .to raise_error(described_class::Refused, /a\.lock/)
    end

    it "refuses a name nested under a branch that already exists, naming it" do
      run_git(@repo_root, "branch", "lain/issue/demo")

      expect { described_class.owned(name, repo_root: @repo_root, from: sha("main")) }
        .to raise_error(described_class::Refused, %r{refs/heads/lain/issue/demo\b.*cannot hold})
    end

    # git hands stderr back as ASCII-8BIT, so a refusal interpolating it dies of
    # Encoding::CompatibilityError instead of naming itself.
    it "answers its own refusal when git's stderr carries non-ASCII bytes" do
      real = Lain::Shell::Out.public_method(:new)
      refusing = Class.new do
        def run_command = self
        def exitstatus = 1
        def stdout = ""
        def stderr = (+"fatal: refname 'ünïcode' is not valid").force_encoding(Encoding::ASCII_8BIT)
      end
      noisy = ->(*args, **kwargs) { args.include?("update-ref") ? refusing.new : real.call(*args, **kwargs) }

      expect { described_class.owned(name, repo_root: @repo_root, from: sha("main"), shell_out_factory: noisy) }
        .to raise_error(described_class::Refused, /not valid/)
    end
  end

  # A re-run of an epic may start its issues fresh, and the marker is still the
  # only licence: what is listed and what is deleted are the branches lain made.
  describe ".owned_under" do
    it "lists the branches lain marked under the prefix, and none a human made there" do
      described_class.owned("lain/issue/demo/a", repo_root: @repo_root, from: sha("main"))
      described_class.owned("lain/issue/other/a", repo_root: @repo_root, from: sha("main"))
      run_git(@repo_root, "branch", "lain/issue/demo/b", "main")

      expect(described_class.owned_under("lain/issue/demo", repo_root: @repo_root).map(&:name))
        .to eq(["lain/issue/demo/a"])
    end

    it "lists nothing for a marker whose branch is gone" do
      described_class.owned("lain/issue/demo/a", repo_root: @repo_root, from: sha("main"))
      run_git(@repo_root, "branch", "-D", "lain/issue/demo/a")

      expect(described_class.owned_under("lain/issue/demo", repo_root: @repo_root)).to be_empty
    end
  end

  # Judged first, deleted after: every refusal a delete can meet is answered
  # before anything moves, and the delete itself moves nothing.
  describe "#discardable! and #discard" do
    let(:name) { "lain/issue/demo/a" }
    let(:marker) { "refs/lain/owned/heads/#{name}" }
    let(:registry) do
      Lain::Isolation::Worktree::Registry.new(repo_root: @repo_root, shell_out_factory: Lain::Shell::Out.public_method(:new))
    end

    def holders = described_class.holders(registry)

    def branch_over(git = Lain::Isolation::Checkout.new(@repo_root))
      described_class.new(name, repo_root: @repo_root, git:)
    end

    # A commit on the branch without checking it out.
    def commit_on(branch_name, text)
      tree = sha("#{branch_name}^{tree}")
      made = run_git(@repo_root, "commit-tree", tree, "-p", sha(branch_name), "-m", text).strip
      run_git(@repo_root, "update-ref", "refs/heads/#{branch_name}", made)
      made
    end

    def owned_with_work
      described_class.owned(name, repo_root: @repo_root, from: sha("main"))
      commit_on(name, "issue work")
    end

    def discarded(branch) = branch.discard(at: branch.discardable!(holders), registry:)

    # main and the branch both change README, so `git rebase main` in `dir`
    # stops on the conflict and leaves the rebase standing.
    def rebase_stopped_in(dir)
      File.write(File.join(dir, "README"), "issue side\n")
      run_git(dir, "commit", "-q", "-am", "issue side")
      expect(try_git(dir, "rebase", "main").exitstatus).not_to eq(0)
    end

    def main_moved
      File.write(File.join(@repo_root, "README"), "main side\n")
      run_git(@repo_root, "commit", "-q", "-am", "main side")
    end

    it "anchors the tip under refs/lain/worker/, then deletes the branch and its marker" do
      tip = owned_with_work

      anchor = discarded(branch_over)

      expect(anchor).to start_with("refs/lain/worker/")
      expect(sha(anchor)).to eq(tip)
      expect([ref?("refs/heads/#{name}"), ref?(marker)]).to eq([false, false])
    end

    it "refuses a branch lain did not create, anchoring and deleting nothing" do
      run_git(@repo_root, "branch", name, "main")

      expect { branch_over.discardable!(holders) }
        .to raise_error(described_class::Refused, /#{name}.*lain did not create/m)
      expect(ref?("refs/heads/#{name}")).to be(true)
      expect(refs("refs/lain/worker/")).to be_empty
    end

    # git's own branch delete refuses a checked-out branch; update-ref does not,
    # so the rule is lain's to keep.
    it "refuses a branch a checkout has out, naming the checkout" do
      owned_with_work
      Dir.mktmpdir("lain-working-branch-held") do |dir|
        held = File.join(File.realpath(dir), "held")
        run_git(@repo_root, "worktree", "add", "-q", held, name)

        expect { branch_over.discardable!(holders) }
          .to raise_error(described_class::Refused, /#{Regexp.escape(held)}/)
        expect([ref?("refs/heads/#{name}"), ref?(marker)]).to eq([true, true])
      ensure
        run_git(@repo_root, "worktree", "remove", "--force", held)
      end
    end

    # A rebase detaches its checkout, so no porcelain names the branch there,
    # yet finishing the rebase rewrites the branch by name.
    it "refuses a branch mid-rebase in a linked checkout, whose HEAD is detached" do
      described_class.owned(name, repo_root: @repo_root, from: sha("main"))
      main_moved
      Dir.mktmpdir("lain-working-branch-rebase") do |dir|
        linked = File.join(File.realpath(dir), "linked")
        run_git(@repo_root, "worktree", "add", "-q", linked, name)
        rebase_stopped_in(linked)

        expect { branch_over.discardable!(holders) }
          .to raise_error(described_class::Refused, /being rebased at #{Regexp.escape(linked)}/)
      ensure
        try_git(linked, "rebase", "--abort")
        try_git(@repo_root, "worktree", "remove", "--force", linked)
      end
    end

    it "refuses a branch mid-rebase in the repository's own checkout" do
      described_class.owned(name, repo_root: @repo_root, from: sha("main"))
      main_moved
      run_git(@repo_root, "switch", "-q", name)
      rebase_stopped_in(@repo_root)

      expect { branch_over.discardable!(holders) }.to raise_error(described_class::Refused, /being rebased/)
    ensure
      try_git(@repo_root, "rebase", "--abort")
    end

    # Judged before anything is deleted, so a batch refuses whole rather than
    # after the branches ahead of this one are gone.
    it "judges a branch undeletable when the anchor its tip would take already holds another commit" do
      tip = owned_with_work
      anchor = Lain::Isolation::Worktree::Handback::Naming.new("#{name} #{tip}").ref
      run_git(@repo_root, "update-ref", anchor, sha("main"))

      expect { branch_over.discardable!(holders) }.to raise_error(described_class::Refused, /#{Regexp.escape(anchor)}/)
      expect([sha(name), sha(anchor)]).to eq([tip, sha("main")])
    end

    it "never overwrites an anchor written after the branch was judged, deleting nothing" do
      tip = owned_with_work
      judged = branch_over.discardable!(holders)
      anchor = Lain::Isolation::Worktree::Handback::Naming.new("#{name} #{tip}").ref
      run_git(@repo_root, "update-ref", anchor, sha("main"))

      expect { branch_over.discard(at: judged, registry:) }
        .to raise_error(described_class::Refused, /could not be written/)
      expect([sha(name), sha(anchor), ref?(marker)]).to eq([tip, sha("main"), true])
    end

    it "reuses the anchor a deletion at the same tip already wrote" do
      tip = owned_with_work
      first = discarded(branch_over)
      described_class.owned(name, repo_root: @repo_root, from: tip)

      expect(discarded(branch_over)).to eq(first)
      expect(sha(first)).to eq(tip)
    end

    it "leaves a branch that moved after it was judged where it moved to, marked, its judged tip anchored" do
      tip = owned_with_work
      judged = branch_over.discardable!(holders)
      moved = commit_on(name, "a sibling moved it")

      expect { branch_over.discard(at: judged, registry:) }
        .to raise_error(described_class::Refused, /could not be deleted/)
      expect([sha(name), ref?(marker)]).to eq([moved, true])
      expect(refs("refs/lain/worker/").map { |ref| sha(ref) }).to eq([tip])
    end

    # The marker is put back only onto a branch still standing; one another
    # hand deleted outright gets none, and the refusal says so.
    it "says the marker could not be put back when the branch it would mark is gone" do
      owned_with_work
      marker_deleted = ->(args) { args[0, 3] == ["update-ref", "-d", marker] }
      git = WorkingBranchSpecRacingCheckout.new(@repo_root, after: marker_deleted) do
        run_git(@repo_root, "update-ref", "-d", "refs/heads/#{name}")
      end

      expect { discarded(branch_over(git)) }.to raise_error(described_class::Refused) { |error|
        expect(error.message).to include("its marker could not be put back")
        expect(error.message).not_to include("still marked")
      }
      expect(ref?(marker)).to be(false)
    end

    # A crash between the marker's delete and the branch's leaves an unmarked
    # branch standing at exactly the tip its own delete anchor holds. The
    # anchor's name is derived from the branch name and that tip, so the pair
    # is the record of a delete lain left unfinished, with no file beside it.
    context "when a delete stopped between the marker and the branch" do
      def crashed_mid_delete
        tip = owned_with_work
        marker_deleted = ->(args) { args[0, 3] == ["update-ref", "-d", marker] }
        dying = WorkingBranchSpecRacingCheckout.new(@repo_root, after: marker_deleted) { raise WorkingBranchSpecCrash }
        expect { discarded(branch_over(dying)) }.to raise_error(WorkingBranchSpecCrash)
        tip
      end

      it "lists the unmarked branch as lain's, a delete left unfinished" do
        tip = crashed_mid_delete

        listed = described_class.owned_under("lain/issue/demo", repo_root: @repo_root)

        expect(listed.map { |branch| [branch.name, branch.unfinished?] }).to eq([[name, true]])
        expect([sha(name), ref?(marker)]).to eq([tip, false])
      end

      it "finishes the delete at the anchored tip" do
        tip = crashed_mid_delete

        anchor = discarded(branch_over)

        expect(sha(anchor)).to eq(tip)
        expect(ref?("refs/heads/#{name}")).to be(false)
      end

      it "reuses the branch as lain's own when it is kept, marking it again" do
        tip = crashed_mid_delete

        kept = described_class.owned(name, repo_root: @repo_root, from: sha("main"))

        expect([kept.tip, sha(marker)]).to eq([tip, tip])
      end

      it "refuses the branch as a human's once its tip has moved off the anchor" do
        crashed_mid_delete
        commit_on(name, "somebody's work")

        expect { described_class.owned(name, repo_root: @repo_root, from: sha("main")) }
          .to raise_error(described_class::Refused, /lain did not create/)
        expect(described_class.owned_under("lain/issue/demo", repo_root: @repo_root)).to be_empty
      end
    end

    # Two runs over one epic are serialised by the landing checkout's lock,
    # but a chat standing on the epic's branch takes none. So a sibling may
    # reach the branch at any point in a delete. The contract: a sibling that
    # reclaims or leases the branch before the delete lands keeps it, owned
    # and marked, and the delete refuses; one that arrives after finds it gone
    # and cuts afresh, or refuses; every tip stays anchored; and the loser says
    # so. The sibling below is lain's own launch: take the branch, check it
    # out, then confirm lain still owns it.
    context "when a sibling run reaches the branch mid-delete" do
      def sibling_leases
        taken = described_class.owned(name, repo_root: @repo_root, from: sha("main"))
        lease = File.join(@root_tmp, "sibling")
        run_git(@repo_root, "worktree", "add", "-q", lease, name)
        taken.still_owned!
        lease
      end

      around do |example|
        Dir.mktmpdir("lain-working-branch-sibling") do |dir|
          @root_tmp = File.realpath(dir)
          example.run
        ensure
          try_git(@repo_root, "worktree", "remove", "--force", File.join(@root_tmp, "sibling"))
        end
      end

      def racing(after, &sibling) = branch_over(WorkingBranchSpecRacingCheckout.new(@repo_root, after:, &sibling))

      it "refuses when the sibling leased the branch after it was judged, leaving it owned and anchored" do
        tip = owned_with_work
        anchor_written = ->(args) { args.include?("--create-reflog") && args.last == "" }
        lease = nil
        branch = racing(anchor_written) { lease = sibling_leases }

        expect { discarded(branch) }.to raise_error(described_class::Refused) { |error|
          expect(error.message).to include(lease)
        }
        expect([sha(name), ref?(marker)]).to eq([tip, true])
        expect(refs("refs/lain/worker/").map { |ref| sha(ref) }).to eq([tip])
      end

      it "refuses when the sibling reclaimed and leased the branch after its marker went, leaving it owned" do
        tip = owned_with_work
        claimed = ->(args) { args[0, 3] == ["update-ref", "-d", marker] }
        branch = racing(claimed) { sibling_leases }

        expect { discarded(branch) }.to raise_error(described_class::Refused, /another run/)
        expect([sha(name), ref?(marker)]).to eq([tip, true])
        expect(refs("refs/lain/worker/").map { |ref| sha(ref) }).to eq([tip])
      end

      it "refuses when the sibling reclaimed the branch without yet leasing it, leaving it owned" do
        tip = owned_with_work
        claimed = ->(args) { args[0, 3] == ["update-ref", "-d", marker] }
        branch = racing(claimed) { described_class.owned(name, repo_root: @repo_root, from: sha("main")) }

        expect { discarded(branch) }.to raise_error(described_class::Refused, /another run/)
        expect([sha(name), ref?(marker)]).to eq([tip, true])
      end

      # A sibling that checked the branch out and then finds lain's marker gone
      # is the one that lost: it stops before doing anything on the branch.
      it "makes a sibling that checked the branch out as its marker went refuse in words" do
        owned_with_work
        taken = described_class.owned(name, repo_root: @repo_root, from: sha("main"))
        run_git(@repo_root, "update-ref", "-d", marker)

        expect { taken.still_owned! }.to raise_error(described_class::Refused, /another run is deleting it/)
      end

      it "makes a sibling reclaiming an unfinished delete refuse once that delete lands, leaving no marker behind" do
        tip = owned_with_work
        marker_deleted = ->(args) { args[0, 3] == ["update-ref", "-d", marker] }
        dying = WorkingBranchSpecRacingCheckout.new(@repo_root, after: marker_deleted) { raise WorkingBranchSpecCrash }
        expect { discarded(branch_over(dying)) }.to raise_error(WorkingBranchSpecCrash)
        anchor_read = ->(args) { args[0, 2] == ["rev-parse", "--verify"] && args.last.start_with?("refs/lain/worker/") }
        sibling = WorkingBranchSpecRacingCheckout.new(@repo_root, after: anchor_read) { discarded(branch_over) }

        reclaiming = described_class.new(name, repo_root: @repo_root, git: sibling)

        expect { reclaiming.establish(from: sha("main"), owned_only: true) }
          .to raise_error(described_class::Refused, /another run deleted it/)
        expect([ref?("refs/heads/#{name}"), ref?(marker)]).to eq([false, false])
        expect(refs("refs/lain/worker/").map { |ref| sha(ref) }).to eq([tip])
      end

      # The reclaim reads the branch's tip and marks it in one transaction that
      # verifies that tip, so a delete landing between the read and the mark
      # still leaves no marker naming nothing.
      it "makes a sibling refuse whose reclaim read the tip just before the delete landed" do
        tip = owned_with_work
        marker_deleted = ->(args) { args[0, 3] == ["update-ref", "-d", marker] }
        dying = WorkingBranchSpecRacingCheckout.new(@repo_root, after: marker_deleted) { raise WorkingBranchSpecCrash }
        expect { discarded(branch_over(dying)) }.to raise_error(WorkingBranchSpecCrash)
        anchor_seen = false
        tip_read_to_mark = lambda do |args|
          anchor_seen ||= args.last.to_s.start_with?("refs/lain/worker/")
          anchor_seen && args.last == "refs/heads/#{name}"
        end
        sibling = WorkingBranchSpecRacingCheckout.new(@repo_root, after: tip_read_to_mark) { discarded(branch_over) }

        expect { described_class.new(name, repo_root: @repo_root, git: sibling).establish(from: tip, owned_only: true) }
          .to raise_error(described_class::Refused, /another run deleted it/)
        expect([ref?("refs/heads/#{name}"), ref?(marker)]).to eq([false, false])
      end

      it "lets a sibling arriving after the delete cut the branch afresh, marked, the old tip still anchored" do
        tip = owned_with_work
        discarded(branch_over)

        fresh = described_class.owned(name, repo_root: @repo_root, from: sha("main"))

        expect([fresh.tip, sha(marker)]).to eq([sha("main"), sha("main")])
        expect(refs("refs/lain/worker/").map { |ref| sha(ref) }).to eq([tip])
      end
    end
  end

  describe ".epic_name" do
    it "names the epic's branch without creating anything" do
      expect(described_class.epic_name("demo")).to eq("epic/demo")
      expect(ref?("refs/heads/epic/demo")).to be(false)
    end
  end

  describe "#current_in?" do
    let(:checkout) { Lain::Isolation::Checkout.new(@repo_root) }

    it "is true only while the checkout's HEAD is on the branch" do
      run_git(@repo_root, "switch", "-q", "-c", "feat")
      feat = described_class.checked_out(repo_root: @repo_root)
      on_feat = feat.current_in?(checkout)
      run_git(@repo_root, "switch", "-q", "main")
      on_main = feat.current_in?(checkout)
      run_git(@repo_root, "switch", "-q", "--detach", "HEAD")

      expect([on_feat, on_main, feat.current_in?(checkout)]).to eq([true, false, false])
    end
  end

  describe "NONE" do
    it "refuses to answer a tip, saying no working branch was given" do
      expect { described_class::NONE.tip }.to raise_error(described_class::Refused, /no working branch/)
    end

    # It names no branch, so it has none to enforce: a handback built without
    # one merges into whatever is checked out, as every caller did before.
    it "counts whatever a checkout has checked out as current" do
      run_git(@repo_root, "switch", "-q", "--detach", "HEAD")

      expect(described_class::NONE.current_in?(Lain::Isolation::Checkout.new(@repo_root))).to be(true)
    end
  end
end
