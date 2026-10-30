# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Operates on a THROWAWAY repo copied from {SeedRepo}, never the lain repo.
RSpec.describe Lain::Isolation::Checkout, :seam do
  subject(:checkout) { described_class.new(@dir) }

  around do |example|
    Dir.mktmpdir("lain-checkout") do |dir|
      @dir = File.realpath(dir)
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @dir)
      example.run
    end
  end

  def run_git(*args)
    SeedRepo.git(@dir, *args).stdout.strip
  end

  describe "#symbolic_head" do
    it "names the branch HEAD is on" do
      expect(checkout.symbolic_head).to eq("refs/heads/#{run_git("branch", "--show-current")}")
    end

    it "answers empty for a detached HEAD, never a nil to guard" do
      run_git("switch", "-q", "--detach", "HEAD")

      expect(checkout.symbolic_head).to eq("")
    end
  end

  describe "#trunk" do
    def rename_to(name) = run_git("branch", "-M", name)

    it "names the branch origin/HEAD points at" do
      rename_to("develop")
      run_git("update-ref", "refs/remotes/origin/develop", "HEAD")
      run_git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop")

      expect(checkout.trunk).to eq("develop")
    end

    it "names init.defaultBranch when that branch exists" do
      rename_to("trunk")
      run_git("config", "init.defaultBranch", "trunk")

      expect(checkout.trunk).to eq("trunk")
    end

    it "finds a repo whose only trunk is master" do
      rename_to("master")

      expect(checkout.trunk).to eq("master")
    end

    it "falls back to main when nothing names a trunk" do
      rename_to("feature")

      expect(checkout.trunk).to eq(Lain::Isolation::WorkingBranch::TRUNK)
    end
  end

  describe "#update_ref" do
    it "writes a ref only over the value it expects, and stamps its reflog" do
      head = run_git("rev-parse", "HEAD")

      first = checkout.update_ref("refs/lain/probe", head, "", reason: "lain probe")
      second = checkout.update_ref("refs/lain/probe", head, "", reason: "lain probe")

      expect([first.exitstatus, second.exitstatus.zero?]).to eq([0, false])
      expect(run_git("reflog", "refs/lain/probe")).to include("lain probe")
    end
  end

  # Every shape of "git is half way through something", because a reader that
  # only knew about merges answered false for four of the five and read a
  # partial or empty diff as the truth.
  describe "#operation_in_progress?" do
    # Two commits touching the same line from a common base, which is what a
    # merge, a rebase, a cherry-pick and a revert each need in order to stop.
    def diverge!
      seed = run_git("rev-parse", "HEAD")
      trunk = run_git("branch", "--show-current")
      commit!("ours")
      run_git("checkout", "-q", "-b", "other", seed)
      commit!("theirs")
      run_git("checkout", "-q", trunk)
      [trunk, seed]
    end

    def commit!(body)
      File.write(File.join(@dir, "a.rb"), body)
      run_git("add", "-A")
      run_git("commit", "-q", "-m", body)
    end

    # Each of these STOPS on a conflict, so a nonzero status is the point of
    # the call rather than a failure of the example.
    def attempt(*args, **environment)
      Lain::Shell::Out.new("git", "-C", @dir, *args,
                           environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB.merge(environment)).run_command
    end

    it "answers false for a checkout git has finished with" do
      expect(checkout.operation_in_progress?).to be(false)
    end

    # The one in-between state that is NOT a refusal: a commit-to-commit diff
    # cannot see the working tree, so uncommitted edits cannot change it.
    it "answers false for a tree that is merely dirty" do
      File.write(File.join(@dir, "a.rb"), "uncommitted\n")

      expect(checkout.operation_in_progress?).to be(false)
    end

    it "answers true for a conflicted merge" do
      diverge!
      attempt("merge", "other")

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true for a conflicted rebase" do
      trunk, = diverge!
      run_git("checkout", "-q", "other")
      attempt("rebase", trunk)

      expect(checkout.operation_in_progress?).to be(true)
    end

    # The state with no pseudo-ref of any kind: nothing conflicted, HEAD simply
    # parked, and the diff it would answer with is empty.
    it "answers true for a rebase stopped at a break, which leaves no pseudo-ref to find" do
      seed = run_git("rev-parse", "HEAD")
      commit!("two")
      attempt("rebase", "-i", seed, "GIT_SEQUENCE_EDITOR" => "sed -i '1i break'")

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true for a conflicted cherry-pick" do
      diverge!
      attempt("cherry-pick", "other")

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true for a conflicted revert" do
      commit!("one")
      commit!("two")
      attempt("revert", "--no-edit", "HEAD~1")

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true for a patch series git am stopped on" do
      diverge!
      patches = File.join(@dir, "patches")
      run_git("format-patch", "-q", "-1", "-o", patches, "other")
      attempt("am", *Dir[File.join(patches, "*.patch")])

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true during a bisect, whose HEAD is some commit nobody asked about" do
      seed = run_git("rev-parse", "HEAD")
      commit!("one")
      commit!("two")
      run_git("bisect", "start")
      run_git("bisect", "bad", "HEAD")
      run_git("bisect", "good", seed)

      expect(checkout.operation_in_progress?).to be(true)
    end
  end

  # A git hook exports `-c` config to its children as GIT_CONFIG_PARAMETERS, and
  # GIT_CONFIG_COUNT/KEY_n/VALUE_n carry the same thing another way. Either
  # would let the hook's settings steer every git call lain makes.
  describe "under a hook's exported config" do
    around do |example|
      polluted = { "GIT_CONFIG_PARAMETERS" => "'lain.probe'='leaked'", "GIT_CONFIG_COUNT" => "1",
                   "GIT_CONFIG_KEY_0" => "lain.other", "GIT_CONFIG_VALUE_0" => "leaked" }
      saved = ENV.to_h.slice(*polluted.keys)
      ENV.update(polluted)
      example.run
    ensure
      polluted.each_key { |key| ENV.delete(key) }
      ENV.update(saved)
    end

    it "reaches none of its git calls" do
      probes = %w[lain.probe lain.other].map { |key| checkout.run("config", "--get", key).exitstatus }

      expect(probes).to eq([1, 1])
    end
  end

  describe "#run options" do
    let(:calls) { [] }
    let(:factory) do
      lambda do |*argv, **options|
        calls << [argv, options]
        instance_double(Lain::Shell::Out, run_command: nil)
      end
    end
    let(:recorded) { described_class.new("/repo", shell_out_factory: factory) }
    let(:scrub) { Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB }

    it "sends only the scrub when no option is given" do
      recorded.run("status")

      expect(calls).to eq([[%w[git -C /repo status], { environment: scrub }]])
    end

    it "merges env over the scrub" do
      recorded.run("status", env: { "GIT_INDEX_FILE" => "/x" })

      expect(calls.first.last).to eq(environment: scrub.merge("GIT_INDEX_FILE" => "/x"))
    end

    it "forwards timeout and input only when given" do
      recorded.run("update-ref", "--stdin", timeout: 5, input: "x\n")

      expect(calls.first.last).to eq(environment: scrub, timeout: 5, input: "x\n")
    end

    it "spells each pin as -c before the subcommand" do
      recorded.run("diff", pins: %w[core.quotePath=false a.b=c])

      expect(calls.first.first).to eq(%w[git -C /repo -c core.quotePath=false -c a.b=c diff])
    end
  end

  describe "#run!" do
    let(:boom) { Class.new(StandardError) }

    it "answers the shell of a command that passed" do
      expect(checkout.run!("rev-parse", "HEAD", error: boom).stdout.strip).to eq(run_git("rev-parse", "HEAD"))
    end

    it "raises the caller's error with the verb, the directory, the status and stderr" do
      expect { checkout.run!("rev-parse", "--verify", "nope^{commit}", error: boom) }
        .to raise_error(boom, /\Agit rev-parse failed in #{Regexp.escape(@dir)} \(exit 128\): .+/)
    end

    it "lets a block word the message from the failed shell" do
      expect { checkout.run!("rev-parse", "nope", error: boom) { |shell| "exit #{shell.exitstatus}" } }
        .to raise_error(boom, "exit 128")
    end
  end

  describe "#fold_in" do
    def clone_with_commit
      clone = File.join(File.dirname(@dir), "#{File.basename(@dir)}-clone")
      SeedRepo.git(@dir, "clone", "-q", "--shared", @dir, clone)
      File.write(File.join(clone, "README"), "work\n")
      SeedRepo.git(clone, "-c", "user.name=w", "-c", "user.email=w@e", "commit", "-q", "-am", "work")
      [clone, SeedRepo.git(clone, "rev-parse", "HEAD").stdout.strip]
    end

    def present?(commit) = Lain::Shell::Out.ok?(checkout.run("cat-file", "-e", "#{commit}^{commit}"))

    it "fetches a commit only another repository holds, leaving no ref and no FETCH_HEAD" do
      clone, commit = clone_with_commit
      before = present?(commit)
      folded = checkout.fold_in(clone, commit)

      expect([before, Lain::Shell::Out.ok?(folded), present?(commit)]).to eq([false, true, true])
      expect(File.exist?(File.join(@dir, ".git", "FETCH_HEAD"))).to be(false)
    ensure
      FileUtils.rm_rf(clone) if clone
    end

    it "refuses a commit that fails fsck, since an agent wrote the objects" do
      clone, = clone_with_commit
      tree = SeedRepo.git(clone, "rev-parse", "HEAD^{tree}").stdout.strip
      bad = SeedRepo.git(clone, "hash-object", "-t", "commit", "--literally", "-w", "--stdin",
                         input: "tree #{tree}\nauthor nobody 0 +0000\ncommitter nobody 0 +0000\n\nbad\n").stdout.strip

      expect([Lain::Shell::Out.ok?(checkout.fold_in(clone, bad)), present?(bad)]).to eq([false, false])
    ensure
      FileUtils.rm_rf(clone) if clone
    end

    it "fetches nothing from a clone lain cut whose git dir holds a planted commondir" do
      root = File.join(Lain::Paths.new.state_home, "worktrees", Lain::Paths.new.project_hash(@dir))
      FileUtils.mkdir_p(root)
      registry = Lain::Isolation::Clone::Registry.new(repo_root: @dir, root:,
                                                      shell_out_factory: Lain::Shell::Out.public_method(:new))
      registry.add(clone = File.join(root, "a"), run_git("rev-parse", "HEAD"), reason: "held")
      File.write(File.join(clone, "README"), "work\n")
      SeedRepo.git(clone, "-c", "user.name=w", "-c", "user.email=w@e", "commit", "-q", "-am", "work")
      commit = SeedRepo.git(clone, "rev-parse", "HEAD").stdout.strip
      FileUtils.mkdir_p(evil = File.join(clone, "evil"))
      FileUtils.cp_r([File.join(clone, ".git", "objects"), File.join(clone, ".git", "refs")], evil)
      File.write(File.join(evil, "config"), "[core]\n\trepositoryformatversion = 0\n")
      File.write(File.join(clone, ".git", "commondir"), "../evil\n")

      expect([Lain::Shell::Out.ok?(checkout.fold_in(clone, commit)), present?(commit)]).to eq([false, false])
    ensure
      FileUtils.rm_rf(root) if root
    end

    it "fetches nothing for a commit it already holds" do
      expect(Lain::Shell::Out.ok?(checkout.fold_in("/nonexistent", run_git("rev-parse", "HEAD")))).to be(true)
    end

    it "answers the failed fetch when the source cannot give the commit" do
      expect(Lain::Shell::Out.ok?(checkout.fold_in(@dir, "0" * 40))).to be(false)
    end
  end

  describe "#fold_in!" do
    let(:boom) { Class.new(StandardError) }

    it "answers the shell of a commit it already holds" do
      shell = checkout.fold_in!("/nonexistent", run_git("rev-parse", "HEAD"), error: boom)

      expect(Lain::Shell::Out.ok?(shell)).to be(true)
    end

    it "raises the caller's error naming the commit and the source when the fetch fails" do
      expect { checkout.fold_in!(@dir, "0" * 40, error: boom) }
        .to raise_error(boom, /\A#{"0" * 40} could not be fetched from #{Regexp.escape(@dir)}: .+/)
    end
  end
end
