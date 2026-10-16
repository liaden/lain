# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Shell::Executable::RunFiles do
  around do |example|
    Dir.mktmpdir("run-files-root") do |root|
      @root = File.realpath(root)
      example.run
    end
  end

  attr_reader :root

  let(:fresh_paths) { [] }
  let(:fresh) { Struct.new(:paths) { def fresh?(path) = paths.include?(path) }.new(fresh_paths) }
  let(:resolver) { Lain::Shell::Executable::Resolver.new(root:, fresh:, host_env: {}) }

  def touch(relative, mode: 0o644)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x\n")
    File.chmod(mode, path)
    path
  end

  def stage(*argvs, path: "/usr/bin:/bin")
    worker_env = Lain::WorkerEnv.new(cwd: root, env: { "PATH" => path })
    resolver.for(worker_env).call(Lain::Shell::Term.of(*argvs)).last
  end

  def run_paths(*argv) = stage(argv).run_files.map(&:path)

  describe "an interpreter's script operand" do
    it "is a run file, classed by where it sits" do
      script = touch("scripts/x.rb")

      expect(stage(%w[ruby scripts/x.rb]).run_files)
        .to contain_exactly(have_attributes(path: script, klass: :project, fresh: false))
    end

    it "is found past options that take a value" do
      script = touch("t.py")
      touch("lib/unrelated.py")

      expect(run_paths("python3", "-W", "ignore", "t.py")).to eq([script])
    end

    it "is found for a shell" do
      expect(run_paths("sh", "x.sh")).to eq([File.join(root, "x.sh")])
    end

    it "carries the freshness of the file" do
      script = touch("t.py")
      fresh_paths << script

      expect(stage(%w[python3 t.py]).run_files).to contain_exactly(have_attributes(path: script, fresh: true))
    end

    it "is a run file even when missing, but unclassifiable" do
      expect(stage(%w[sh x.sh]).run_files).to contain_exactly(have_attributes(klass: :unresolved, fresh: false))
    end

    it "is absent for inline code" do
      expect(run_paths("ruby", "-e", "puts 1")).to eq([])
      expect(run_paths("sh", "-c", "true")).to eq([])
    end
  end

  describe "an interpreter that reads its program from stdin" do
    it "makes the stage :unresolved for a pipe" do
      expect(stage(%w[cat], %w[ruby])).to have_attributes(klass: :unresolved)
    end

    it "makes the stage :unresolved for a dash operand" do
      expect(stage(%w[ruby -])).to have_attributes(klass: :unresolved, run_files: [])
    end

    it "does not mistake a version query for stdin" do
      expect(stage(%w[ruby -v])).to have_attributes(klass: :system, run_files: [])
    end

    it "keeps the wrapper that ran it" do
      expect(stage(%w[nice ruby -]).wrappers.map(&:name)).to eq(["nice"])
    end
  end

  describe "a test runner" do
    it "runs the spec files and directories it is given" do
      spec = touch("spec/x_spec.rb")
      tests = File.join(root, "tests")
      FileUtils.mkdir_p(tests)

      expect(run_paths("bundle", "exec", "rspec", "spec/x_spec.rb")).to include(spec)
      expect(run_paths("pytest", "tests/")).to eq([tests])
    end

    it "ignores a line suffix and flags" do
      spec = touch("spec/x_spec.rb")

      expect(run_paths("rspec", "--format", "doc", "spec/x_spec.rb:12")).to eq([spec])
    end

    it "does not treat a plain tool's operands as run files" do
      touch("README.md")

      expect(run_paths("cat", "README.md")).to eq([])
    end
  end

  describe "a build tool" do
    it "runs the Makefile that exists" do
      makefile = touch("Makefile")

      expect(run_paths("make")).to eq([makefile])
    end

    it "runs the file make -f names" do
      touch("Makefile")
      other = touch("other.mk")

      expect(run_paths("make", "-f", "other.mk")).to eq([other])
    end

    it "cannot classify make reading its makefile from stdin" do
      expect(stage(%w[make -f -])).to have_attributes(klass: :unresolved)
    end

    it "runs the Rakefile, and bundle exec its Gemfile and lock" do
      touch("Rakefile")
      touch("Gemfile")
      touch("Gemfile.lock")
      files = %w[Rakefile Gemfile Gemfile.lock].map { |name| File.join(root, name) }

      expect(run_paths("rake")).to eq([File.join(root, "Rakefile")])
      expect(run_paths("bundle", "exec", "rake")).to match_array(files)
    end

    it "names only the config that exists" do
      touch("package.json")

      expect(run_paths("npm", "run", "build")).to eq([File.join(root, "package.json")])
      expect(run_paths("bundle", "exec", "true")).to eq([])
    end

    it "runs Cargo.toml and build.rs for cargo" do
      toml = touch("Cargo.toml")
      build = touch("build.rs")

      expect(run_paths("cargo", "build")).to contain_exactly(toml, build)
    end

    it "classes a config file the project owns as :project and notes its freshness" do
      makefile = touch("Makefile")
      fresh_paths << makefile

      expect(stage(%w[make]).run_files).to contain_exactly(have_attributes(klass: :project, fresh: true))
    end
  end

  describe "direnv" do
    it "runs the project's .envrc" do
      envrc = touch(".envrc")

      expect(run_paths("direnv", "exec", ".", "rspec")).to eq([envrc])
    end

    it "leaves the wrapped program unresolved" do
      touch(".envrc")

      expect(stage(%w[direnv exec . rspec])).to have_attributes(klass: :unresolved)
    end
  end

  describe "git" do
    it "runs the config and every hook that exists" do
      config = touch(".git/config")
      hook = touch(".git/hooks/pre-commit", mode: 0o755)
      sample = touch(".git/hooks/pre-push.sample")

      expect(run_paths("git", "commit")).to contain_exactly(config, hook, sample)
    end

    it "finds the git directory above the cwd" do
      config = touch(".git/config")
      worker_env = Lain::WorkerEnv.new(cwd: File.join(root, "sub"), env: { "PATH" => "/usr/bin" })
      FileUtils.mkdir_p(File.join(root, "sub"))

      found = resolver.for(worker_env).call(Lain::Shell::Term.of(%w[git status])).sole.run_files.map(&:path)

      expect(found).to eq([config])
    end

    it "has no run files outside a repository" do
      expect(stage(%w[git status])).to have_attributes(klass: :system, run_files: [])
    end
  end

  describe "a shell told to read its program from stdin" do
    it "is :unresolved for -s and for a cluster holding s" do
      expect(stage(%w[sh -s x.sh])).to have_attributes(klass: :unresolved)
      expect(stage(%w[bash -s -- a])).to have_attributes(klass: :unresolved)
      expect(stage(%w[bash -is x.sh])).to have_attributes(klass: :unresolved)
    end
  end

  describe "options that take a value" do
    it "skips a shell's -o, -O and rcfile values" do
      script = touch("x.sh")

      expect(run_paths("bash", "-o", "posix", "x.sh")).to eq([script])
      expect(run_paths("bash", "-O", "extglob", "x.sh")).to eq([script])
      expect(run_paths("bash", "--rcfile", "rc", "x.sh")).to eq([script])
      expect(run_paths("bash", "--init-file", "rc", "x.sh")).to eq([script])
      expect(run_paths("bash", "+o", "posix", "x.sh")).to eq([script])
    end

    it "cannot place a ruby script after -C, -x or -S" do
      touch("x.rb")

      expect(stage(%w[ruby -C sub x.rb])).to have_attributes(klass: :unresolved)
      expect(stage(%w[ruby -Csub x.rb])).to have_attributes(klass: :unresolved)
      expect(stage(%w[ruby -x x.rb])).to have_attributes(klass: :unresolved)
      expect(stage(%w[ruby -S x.rb])).to have_attributes(klass: :unresolved)
    end

    it "takes the operand after a bare --" do
      script = touch("x.rb")

      expect(run_paths("ruby", "--", "x.rb")).to eq([script])
    end
  end

  describe "python -m" do
    it "cannot place an arbitrary module, which imports from the cwd" do
      expect(stage(%w[python3 -m mymod])).to have_attributes(klass: :unresolved)
      expect(stage(%w[python3 -mmymod])).to have_attributes(klass: :unresolved)
    end

    it "treats pytest as a test runner" do
      tests = File.join(root, "tests")
      FileUtils.mkdir_p(tests)

      expect(run_paths("python3", "-m", "pytest", "tests/")).to eq([tests])
    end
  end

  describe "make -C" do
    it "names the makefile in that directory" do
      touch("Makefile")
      sub = touch("sub/Makefile")

      expect(run_paths("make", "-C", "sub")).to eq([sub])
      expect(run_paths("make", "--directory=sub")).to eq([sub])
    end

    it "falls back to the cwd when that directory has none" do
      makefile = touch("Makefile")
      FileUtils.mkdir_p(File.join(root, "sub"))

      expect(run_paths("make", "-C", "sub")).to eq([makefile])
    end

    it "prefers GNUmakefile, then makefile, then Makefile" do
      gnu = touch("GNUmakefile")
      touch("makefile")

      expect(run_paths("make")).to eq([gnu])
    end
  end

  describe "a test runner given no operand" do
    it "runs the conventional tree" do
      spec = touch("spec/a_spec.rb").then { File.join(root, "spec") }
      rspec = touch(".rspec")

      expect(run_paths("rspec")).to contain_exactly(spec, rspec)
    end

    it "lists pytest's tree" do
      names = %w[pytest.ini conftest.py pyproject.toml setup.cfg].map { |name| touch(name) }
      tests = File.join(root, "tests")
      FileUtils.mkdir_p(tests)

      expect(run_paths("pytest")).to contain_exactly(*names, tests)
    end

    it "lists jest's package.json and config" do
      package = touch("package.json")
      config = touch("jest.config.js")

      expect(run_paths("jest")).to contain_exactly(package, config)
    end
  end

  describe "git beyond a plain checkout" do
    def worktree(name)
      common = File.join(root, "main/.git")
      gitdir = File.join(common, "worktrees", name)
      FileUtils.mkdir_p([gitdir, File.join(common, "hooks"), File.join(root, name)])
      File.write(File.join(root, name, ".git"), "gitdir: #{gitdir}\n")
      File.write(File.join(gitdir, "commondir"), "../..\n")
      File.write(File.join(common, "config"), "[core]\n")
      [File.join(root, name), common]
    end

    def git_in(cwd, *args)
      worker_env = Lain::WorkerEnv.new(cwd:, env: { "PATH" => "/usr/bin" })
      resolver.for(worker_env).call(Lain::Shell::Term.of(["git", *args])).sole
    end

    it "follows a linked worktree to the common config and hooks" do
      dir, common = worktree("wt")
      hook = File.join(common, "hooks/pre-commit")
      File.write(hook, "#!/bin/sh\n")

      expect(git_in(dir, "commit").run_files.map(&:path)).to contain_exactly(File.join(common, "config"), hook)
    end

    it "is :unresolved when the .git file cannot be read" do
      FileUtils.mkdir_p(File.join(root, "wt"))
      File.write(File.join(root, "wt/.git"), "garbage\n")

      expect(git_in(File.join(root, "wt"), "status")).to have_attributes(klass: :unresolved)
    end

    it "never walks past a .git file into a parent repository" do
      touch(".git/config")
      FileUtils.mkdir_p(File.join(root, "sub"))
      File.write(File.join(root, "sub/.git"), "garbage\n")

      expect(git_in(File.join(root, "sub"), "status")).to have_attributes(klass: :unresolved)
    end

    it "follows core.hooksPath from the config" do
      touch(".git/config")
      File.write(File.join(root, ".git/config"), "[core]\n\thooksPath = githooks\n")
      hook = touch("githooks/pre-commit")
      touch(".git/hooks/pre-commit")

      expect(git_in(root, "commit").run_files.map(&:path)).to contain_exactly(File.join(root, ".git/config"), hook)
    end

    it "is :unresolved when the config redirects hooks somewhere unreadable" do
      touch(".git/config")
      File.write(File.join(root, ".git/config"), "[core]\n\thooksPath = ~/hooks\n")

      expect(git_in(root, "commit")).to have_attributes(klass: :unresolved)
    end

    it "is :unresolved when the config includes another file" do
      touch(".git/config")
      File.write(File.join(root, ".git/config"), "[include]\n\tpath = ../other\n")

      expect(git_in(root, "commit")).to have_attributes(klass: :unresolved)
    end

    it "is :unresolved when hooksPath uses git config syntax this does not parse" do
      ['"githooks"', "githooks # mine", "githooks; mine", "git\\\nhooks"].each do |value|
        touch(".git/config")
        File.write(File.join(root, ".git/config"), "[core]\n\thooksPath = #{value}\n")

        expect(git_in(root, "commit")).to have_attributes(klass: :unresolved)
      end
    end

    it "reads hooksPath and includes from config.worktree too" do
      dir, common = worktree("wt")
      gitdir = File.join(common, "worktrees/wt")
      File.write(File.join(gitdir, "config.worktree"), "[core]\n\thooksPath = elsewhere\n")
      hook = touch("wt/elsewhere/pre-commit")

      expect(git_in(dir, "commit").run_files.map(&:path)).to contain_exactly(File.join(common, "config"),
                                                                             File.join(gitdir, "config.worktree"), hook)
      File.write(File.join(gitdir, "config.worktree"), "[include]\n\tpath = x\n")
      expect(git_in(dir, "commit")).to have_attributes(klass: :unresolved)
    end

    it "lists config.worktree of a linked worktree" do
      dir, common = worktree("wt")
      extra = File.join(common, "worktrees/wt/config.worktree")
      File.write(extra, "[core]\n")

      expect(git_in(dir, "status").run_files.map(&:path)).to include(extra)
    end

    it "is :unresolved when options move the repository or the config" do
      touch(".git/config")

      expect(git_in(root, "-C", "elsewhere", "commit")).to have_attributes(klass: :unresolved)
      expect(git_in(root, "-c", "core.hooksPath=/x", "commit")).to have_attributes(klass: :unresolved)
      expect(git_in(root, "--git-dir=/x", "commit")).to have_attributes(klass: :unresolved)
    end
  end

  it "is deeply frozen on the Executable" do
    touch("Makefile")

    expect(Ractor.shareable?(stage(%w[make]))).to be(true)
  end

  it "journals each run file" do
    touch("Makefile")

    expect(stage(%w[make]).to_journal["run_files"])
      .to eq([{ "path" => File.join(root, "Makefile"), "klass" => "project", "fresh" => false }])
  end
end
