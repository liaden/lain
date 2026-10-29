# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::Clone::Guard, :seam do
  around do |example|
    Dir.mktmpdir("lain-clone-guard") do |base|
      @base = File.realpath(base)
      example.run
    end
  end

  after { Array(@leases).each { _1.release(discard: true) } }

  def seeded(main)
    FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", main.tap { FileUtils.mkdir_p(_1) })
    SeedRepo.git(main, "branch", "-M", "main")
    main
  end

  def cut(main)
    lease = Lain::CLI::IsolationBackend.resolve("worktree", root: main).acquire("lease")
    @leases = [*@leases, lease]
    lease.origin.path
  end

  describe ".upstream" do
    it "answers the worktree a clone was cut from" do
      main = seeded(File.join(@base, "main"))

      expect(described_class.upstream(cut(main))).to eq(main)
    end

    # git itself names the git dir as the main worktree of such a repository, so lain answers what git does.
    it "answers the git dir for an upstream whose git dir is kept apart from its worktree" do
      main = File.join(@base, "apart")
      git_dir = File.join(@base, "apart.git")
      SeedRepo.git(@base, "init", "-q", "-b", "main", "--separate-git-dir", git_dir, main)
      SeedRepo.git(main, "-c", "user.name=a", "-c", "user.email=a@b", "commit", "-q", "--allow-empty", "-m", "seed")

      expect(described_class.upstream(cut(main))).to eq(git_dir)
    end

    it "answers nil for a clone lain did not cut" do
      main = seeded(File.join(@base, "main"))
      plain = File.join(@base, "plain")
      SeedRepo.git(@base, "clone", "-q", "--shared", main, plain)

      expect(described_class.upstream(plain)).to be_nil
    end

    it "answers nil for a cut clone whose record names no object store" do
      clone = cut(seeded(File.join(@base, "main")))
      record = described_class.record(clone)
      File.write(record, "\n#{File.readlines(record, chomp: true)[1]}\n")

      expect(described_class.upstream(clone)).to be_nil
    end
  end
end
