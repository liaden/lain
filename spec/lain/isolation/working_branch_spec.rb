# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

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
