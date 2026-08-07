# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# `:seam` here marks the examples that depend on a real local resource beyond an
# ordinary temp tree: a `git` subprocess whose OWN answer is asserted, or a
# genuinely distinct mount point. Everywhere else `git init` merely builds a
# fixture on disk -- a real `.git` entry is what several rungs are about -- and
# the assertion is only ever on this resolver's reading of the filesystem, which
# every example drives for real. A fixture is not a collaborator.
RSpec.describe Lain::Project::Resolver do
  # One temp tree per example. `realpath` because every path this resolver
  # produces is kernel-resolved, so a spec comparing against the raw mktmpdir
  # string would fail on any host where /tmp is itself a symlink.
  around do |example|
    Dir.mktmpdir("lain-resolver") do |dir|
      @tmp = File.realpath(dir)
      example.run
    end
  end

  # The one directory on a normal Linux host that is a mount point an
  # unprivileged process can write to, whose parent is a DIFFERENT filesystem.
  let(:shm) { "/dev/shm" }

  let(:tmp) { @tmp }
  let(:home) { mkdir("home") }
  let(:paths) do
    Lain::Paths.new(env: { "XDG_CONFIG_HOME" => "#{tmp}/xdg/config",
                           "XDG_CACHE_HOME" => "#{tmp}/xdg/cache",
                           "XDG_STATE_HOME" => "#{tmp}/xdg/state" })
  end
  let(:resolver) { described_class.new(home:, paths:) }

  def mkdir(*names)
    path = File.join(tmp, *names)
    FileUtils.mkdir_p(path)
    path
  end

  def write(path, contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  # Every variable that can point git at a repository other than the one named
  # on the command line, mapped to nil so `spawn` unsets it in the child.
  #
  # **Scrub by reflex when you build a git fixture in this repo.** `git` exports
  # these into the environment of every HOOK it runs, so under `pre-commit` a
  # fixture repo inherits `GIT_INDEX_FILE` and commits against LAIN'S index --
  # observed as `error: invalid object … / error: Error building trees` while
  # committing an empty tree in a tmpdir. Outside a hook the variables are
  # unset, so the example passes everywhere except the one moment that matters.
  #
  # This card's own subject, turned on itself: T2 exists to stop inherited git
  # environment from deciding a project root, and its spec was itself being
  # decided by inherited git environment.
  #
  # `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG_COUNT` and
  # `GIT_CONFIG_PARAMETERS` are the ones measured to actually redirect git (a
  # command-line `--git-dir` already defeats `GIT_DIR`); the rest cost nothing.
  def git_env
    %w[
      GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_GLOBAL
      GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_PREFIX GIT_NAMESPACE
    ].to_h { |name| [name, nil] }
  end

  def git(*args, chdir:)
    out, err, status = Open3.capture3(git_env, "git", *args, chdir:)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def init_repo(path)
    FileUtils.mkdir_p(path)
    git("init", "-q", "-b", "main", ".", chdir: path)
    path
  end

  # Reports a device of -1 for `boundary` and every directory ABOVE it, and the
  # real device for everything below.
  #
  # Faked HERE only so the boundary can be placed at an arbitrary depth, which
  # is what pins the above/below discrimination: a marker below it must still
  # win, and a marker above it must be unreachable. A real mount cannot be moved
  # around a fixture tree like that. It emphatically does NOT take a real
  # cross-mount ancestry to be unbuildable -- "stops at a REAL mount boundary"
  # below builds one over `/dev/shm` with no privileges and nothing stubbed.
  def filesystem_stopping_at(boundary)
    stat = Struct.new(:dev)
    real_filesystem.tap do |fs|
      fs.define_singleton_method(:stat) do |path|
        boundary == path || boundary.start_with?(File.join(path, "")) ? stat.new(-1) : File.stat(path)
      end
    end
  end

  def filesystem_denying_stat_at(denied)
    real_filesystem.tap do |fs|
      fs.define_singleton_method(:stat) do |path|
        raise Errno::EACCES, path if path == denied

        File.stat(path)
      end
    end
  end

  def real_filesystem
    fs = Object.new
    fs.define_singleton_method(:exist?) { |path| File.exist?(path) }
    fs.define_singleton_method(:directory?) { |path| File.directory?(path) }
    fs.define_singleton_method(:realpath) { |path| File.realpath(path) }
    fs
  end

  describe "rung 4, a .git entry" do
    it "resolves a monorepo subtree to the repository top" do
      repo = init_repo(File.join(tmp, "work", "repo"))
      cwd = mkdir("work", "repo", "services", "ingest")

      project = resolver.call(cwd:).project

      expect(project).to have_attributes(root: repo, cwd:, kind: :project, detected_by: :git)
    end

    it "counts a linked worktree's one-line pointer file as a .git entry" do
      repo = init_repo(File.join(tmp, "work", "repo"))
      git("-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "seed",
          chdir: repo)
      linked = File.join(tmp, "work", "linked")
      git("worktree", "add", "-q", linked, "-b", "side", chdir: repo)
      cwd = mkdir("work", "linked", "deep")

      project = resolver.call(cwd:).project

      # The discriminator: an implementation reaching for `directory?` here
      # would walk straight past a linked worktree and land on the primary repo.
      expect(File.file?(File.join(linked, ".git"))).to be(true)
      expect(project).to have_attributes(root: File.realpath(linked), detected_by: :git)
    end
  end

  describe "rung 3, a .lain directory" do
    it "beats the repository top below it" do
      init_repo(File.join(tmp, "work", "repo"))
      marked = mkdir("work", "repo", "services", "ingest", ".lain")
      cwd = mkdir("work", "repo", "services", "ingest", "src")

      project = resolver.call(cwd:).project

      expect(project).to have_attributes(root: File.dirname(marked), detected_by: :lain_dir)
    end

    it "beats a .git entry that sits DEEPER than it does" do
      mkdir("work", "repo", ".lain")
      init_repo(File.join(tmp, "work", "repo", "services", "ingest"))
      cwd = mkdir("work", "repo", "services", "ingest", "src")

      project = resolver.call(cwd:).project

      # Rung-major, not directory-major: an explicit marker outranks an
      # inferred one anywhere in the ancestry, not merely at the same depth.
      expect(project).to have_attributes(root: File.join(tmp, "work", "repo"), detected_by: :lain_dir)
    end
  end

  describe "rung 2, a root= in .lain/config.toml" do
    it "takes the declared root over the .lain directory holding the declaration" do
      write(File.join(tmp, "work", "repo", "services", ".lain", "config.toml"), %(root = ".."\n))
      cwd = mkdir("work", "repo", "services", "ingest")

      project = resolver.call(cwd:).project

      expect(project).to have_attributes(root: File.join(tmp, "work", "repo"), detected_by: :config)
    end

    it "reads a self-naming root as the declaring directory" do
      write(File.join(tmp, "work", "repo", ".lain", "config.toml"), %(root = "."\n))
      cwd = mkdir("work", "repo", "src")

      expect(resolver.call(cwd:).project).to have_attributes(root: File.join(tmp, "work", "repo"),
                                                             detected_by: :config)
    end

    it "declines a declared root that is not an ancestor-or-self of cwd, falling to the next rung" do
      init_repo(File.join(tmp, "work", "repo"))
      elsewhere = mkdir("work", "elsewhere")
      write(File.join(tmp, "work", "repo", "services", ".lain", "config.toml"), %(root = "#{elsewhere}"\n))
      cwd = mkdir("work", "repo", "services", "ingest")

      report = resolver.call(cwd:)

      # Rung 3 then matches on the very directory that declared the root, which
      # is the nearest rung below rung 2 -- never `elsewhere`, and never a raise.
      expect(report.project)
        .to have_attributes(root: File.join(tmp, "work", "repo", "services"), detected_by: :lain_dir)
      # A decline that names somewhere OTHER than the boundary must not rename
      # the boundary's own rung.
      expect(report.refusal.rung).to eq(:none)
    end

    it "declines a declared root above the refusal boundary, and the report names that rung" do
      write(File.join(home, "code", ".lain", "config.toml"), %(root = ".."\n))
      cwd = mkdir("home", "code", "app")

      report = resolver.call(cwd:)

      # `..` is `$HOME`, which the walk never admits as a candidate, so the
      # config cannot reach past the stop rule that governs every other rung.
      expect(report.project).to have_attributes(root: File.join(home, "code"), detected_by: :lain_dir)
      # The walk genuinely evaluated a rung-2 declaration and turned it down.
      # `rung: :none` here would report a bare unmarked $HOME, which is not what
      # happened -- a user wrote an explicit `root =` and it was declined.
      expect(report.refusal).to have_attributes(directory: home, reason: :home, rung: :config)
    end

    it "does not carry a declined declaration from one resolution into the next" do
      write(File.join(home, "code", ".lain", "config.toml"), %(root = ".."\n))
      declining = mkdir("home", "code", "app")
      innocent = mkdir("home", "notes")

      expect(resolver.call(cwd: declining).refusal).to have_attributes(directory: home, rung: :config)

      # The SAME resolver, a second call, and deliberately the same boundary:
      # nothing was declined this time, so a report still naming the first
      # call's config is the scan's own state leaking across resolutions.
      expect(resolver.call(cwd: innocent).refusal).to have_attributes(directory: home, rung: :none)
    end

    it "names rung 2 in the refusal even when $HOME carries no marker of its own" do
      write(File.join(home, "code", "app", ".lain", "config.toml"), %(root = "#{home}"\n))
      cwd = mkdir("home", "code", "app")

      report = resolver.call(cwd:)

      expect(report.project).to have_attributes(root: cwd, detected_by: :lain_dir)
      expect(report.refusal).to have_attributes(directory: home, reason: :home, rung: :config)
    end

    it "refuses a home-relative declared root lexically, naming the file and the value" do
      path = write(File.join(tmp, "work", "repo", ".lain", "config.toml"), %(root = "~/elsewhere"\n))
      cwd = mkdir("work", "repo", "src")

      expect { resolver.call(cwd:) }
        .to raise_error(Lain::Project::Resolver::UnusableConfiguredRoot, %r{#{Regexp.escape(path)}.*"~/elsewhere"})
    end

    it "refuses a declared root that is not a string" do
      write(File.join(tmp, "work", "repo", ".lain", "config.toml"), %(root = 7\n))
      cwd = mkdir("work", "repo", "src")

      expect { resolver.call(cwd:) }.to raise_error(Lain::Project::Resolver::UnusableConfiguredRoot, /7/)
    end

    it "raises Config::Malformed on a config.toml that will not parse, naming the path" do
      path = write(File.join(tmp, "work", "repo", ".lain", "config.toml"), %(root = "unterminated\n))
      cwd = mkdir("work", "repo", "src")

      expect { resolver.call(cwd:) }.to raise_error(Lain::Config::Malformed, /#{Regexp.escape(path)}/)
    end

    it "leaves a broken config.toml above the one that answered unopened" do
      write(File.join(tmp, "work", ".lain", "config.toml"), %(root = "unterminated\n))
      write(File.join(tmp, "work", "repo", ".lain", "config.toml"), %(root = "."\n))
      cwd = mkdir("work", "repo", "src")

      # "First match wins" has to mean the scan STOPS. One stale
      # `~/work/.lain/config.toml` must not refuse to start every project below it.
      expect(resolver.call(cwd:).project)
        .to have_attributes(root: File.join(tmp, "work", "repo"), detected_by: :config)
    end

    it "leaves an unusable declared root above the one that answered unopened" do
      write(File.join(tmp, "work", ".lain", "config.toml"), %(root = 7\n))
      write(File.join(tmp, "work", "repo", ".lain", "config.toml"), %(root = "."\n))
      cwd = mkdir("work", "repo", "src")

      expect(resolver.call(cwd:).project).to have_attributes(detected_by: :config)
    end

    it "opens exactly one config.toml however many sit above the one that answered" do
      write(File.join(tmp, "work", ".lain", "config.toml"), %(root = "."\n))
      write(File.join(tmp, "work", "repo", ".lain", "config.toml"), %(root = "."\n))
      write(File.join(tmp, "work", "repo", "src", ".lain", "config.toml"), %(root = "."\n))
      cwd = mkdir("work", "repo", "src")

      expect(Tomlrb).to receive(:load_file).once.and_call_original

      resolver.call(cwd:)
    end

    it "still raises on a broken config above when no nearer one answers" do
      path = write(File.join(tmp, "work", ".lain", "config.toml"), %(root = "unterminated\n))
      mkdir("work", "repo", ".lain")
      cwd = mkdir("work", "repo", "src")

      # Inherent to rung-major, and deliberate: rung 2 scans the whole REACHABLE
      # ancestry before rung 3 is tried, so a config.toml the walk can reach and
      # cannot parse is a real error a user has to see. Only the files ABOVE an
      # answer go unopened.
      expect { resolver.call(cwd:) }.to raise_error(Lain::Config::Malformed, /#{Regexp.escape(path)}/)
    end

    it "ignores a config.toml that declares no root at all" do
      write(File.join(tmp, "work", "repo", "services", ".lain", "config.toml"), %([epics]\nhome = "repo"\n))
      cwd = mkdir("work", "repo", "services", "ingest")

      expect(resolver.call(cwd:).project)
        .to have_attributes(root: File.join(tmp, "work", "repo", "services"), detected_by: :lain_dir)
    end
  end

  describe "rung 1, an explicit root" do
    it "may be $HOME, and is not subject to the refusal set" do
      cwd = home

      project = resolver.call(cwd:, root: home).project

      expect(project).to have_attributes(root: home, cwd: home, kind: :home, detected_by: :flag)
    end

    it "may be $HOME with cwd deep inside it" do
      cwd = mkdir("home", "notes", "drafts")

      expect(resolver.call(cwd:, root: home).project)
        .to have_attributes(root: home, cwd:, kind: :home, detected_by: :flag)
    end

    it "outranks every marker the walk would have found" do
      init_repo(File.join(tmp, "work", "repo"))
      mkdir("work", "repo", "services", ".lain")
      cwd = mkdir("work", "repo", "services", "ingest")

      expect(resolver.call(cwd:, root: File.join(tmp, "work", "repo", "services", "ingest")).project)
        .to have_attributes(root: cwd, detected_by: :flag)
    end
  end

  describe "the refusal set" do
    it "refuses $HOME even when a .git directory sits directly in it" do
      mkdir("home", ".git")
      cwd = mkdir("home", "notes")

      report = resolver.call(cwd:)

      expect(report.project).to have_attributes(root: cwd, cwd:, detected_by: :none)
      # The stop rule fires AFTER the rung matched, which is what makes it
      # general rather than a special case inside the git detector: the report
      # can still name which rung the refused directory would have produced.
      expect(report.refusal).to have_attributes(directory: home, reason: :home, rung: :git)
    end

    it "refuses $HOME when a .lain directory sits in it, naming that rung" do
      mkdir("home", ".lain")
      cwd = mkdir("home", "notes")

      expect(resolver.call(cwd:).refusal).to have_attributes(directory: home, reason: :home, rung: :lain_dir)
    end

    it "refuses $HOME carrying a config.toml without parsing its contents" do
      write(File.join(home, ".lain", "config.toml"), %(root = "unterminated\n))
      cwd = mkdir("home", "notes")

      report = resolver.call(cwd:)

      expect(report.project.detected_by).to eq(:none)
      expect(report.refusal).to have_attributes(directory: home, reason: :home, rung: :config)
    end

    it "still finds a project root BELOW $HOME" do
      init_repo(File.join(tmp, "home", "code", "app"))
      cwd = mkdir("home", "code", "app", "lib")

      expect(resolver.call(cwd:).project)
        .to have_attributes(root: File.join(home, "code", "app"), detected_by: :git)
    end

    it "refuses the shared temp directories, wherever TMPDIR happens to point" do
      # Anchored on the literal directories rather than on `Dir.mktmpdir`'s
      # default: `TMPDIR=/dev/shm` is a setting CLAUDE.md records having tried
      # for suite speed, and it would otherwise silently move this example's
      # subject out from under it.
      %w[/tmp /var/tmp].each do |base|
        Dir.mktmpdir("lain-resolver", base) do |dir|
          cwd = File.join(dir, "scratch")
          FileUtils.mkdir_p(cwd)

          expect(resolver.call(cwd:).refusal)
            .to have_attributes(directory: File.realpath(base), reason: :temp)
        end
      end
    end

    it "refuses an XDG base directory, and the lain directory under it" do
      base = mkdir("xdg", "config")
      init_repo(File.join(base, "lain"))
      cwd = mkdir("xdg", "config", "lain", "inner")

      report = resolver.call(cwd:)

      expect(report.project).to have_attributes(root: cwd, detected_by: :none)
      expect(report.refusal).to have_attributes(directory: File.join(base, "lain"), reason: :xdg, rung: :git)
    end

    it "refuses the XDG base itself, one level above the lain directory" do
      base = mkdir("xdg", "state")
      init_repo(base)
      cwd = mkdir("xdg", "state", "notes")

      expect(resolver.call(cwd:).refusal).to have_attributes(directory: base, reason: :xdg, rung: :git)
    end

    it "does not refuse an ordinary sibling of a refused directory" do
      repo = init_repo(File.join(tmp, "xdg", "configuration"))
      cwd = mkdir("xdg", "configuration", "src")

      # `/tmp` vs `/tmp-other`: a prefix match rather than an exact one would
      # swallow this whole subtree.
      expect(resolver.call(cwd:).project).to have_attributes(root: repo, detected_by: :git)
    end

    it "stops the walk at a mount boundary and ignores every marker above it" do
      boundary = mkdir("work")
      mkdir("work", ".lain")
      cwd = mkdir("work", "repo", "src")
      init_repo(File.join(tmp, "work", "repo"))

      report = described_class.new(home:, paths:, filesystem: filesystem_stopping_at(boundary)).call(cwd:)

      expect(report.project).to have_attributes(root: File.join(tmp, "work", "repo"), detected_by: :git)
      expect(report.refusal).to have_attributes(directory: boundary, reason: :mount_boundary, rung: :lain_dir)
    end

    it "stops at a REAL mount boundary, with nothing stubbed", :seam do
      unless File.exist?(shm) && File.stat(shm).dev != File.stat(File.dirname(shm)).dev
        skip "#{shm} is not a mount point separate from #{File.dirname(shm)} on this host"
      end

      Dir.mktmpdir("lain-resolver", shm) do |dir|
        cwd = File.join(dir, "scratch")
        FileUtils.mkdir_p(cwd)

        report = resolver.call(cwd:)

        # /dev/shm is tmpfs and /dev is devtmpfs, so the device genuinely
        # changes at /dev with no privileges needed -- which is what makes this
        # the one example where the reading the rule depends on is not faked.
        expect(report.project).to have_attributes(root: cwd, detected_by: :none)
        expect(report.refusal).to have_attributes(directory: File.dirname(shm), reason: :mount_boundary)
      end
    end

    it "refuses a directory it cannot stat rather than walking through it" do
      opaque = mkdir("work")
      mkdir("work", ".lain")
      cwd = mkdir("work", "repo", "src")

      report = described_class.new(home:, paths:, filesystem: filesystem_denying_stat_at(opaque)).call(cwd:)

      # Fail closed: an ancestor whose metadata is unreadable is a boundary, not
      # an ordinary directory to continue past, so the `.lain/` sitting on it is
      # never reached.
      expect(report.project).to have_attributes(root: cwd, detected_by: :none)
      expect(report.refusal).to have_attributes(directory: opaque, reason: :unreadable, rung: :lain_dir)
    end

    it "falls through to cwd when the only marker is above a mount boundary" do
      boundary = mkdir("work")
      mkdir("work", ".lain")
      cwd = mkdir("work", "repo", "src")

      report = described_class.new(home:, paths:, filesystem: filesystem_stopping_at(boundary)).call(cwd:)

      expect(report.project).to have_attributes(root: cwd, cwd:, detected_by: :none)
      expect(report.refusal).to have_attributes(directory: boundary, reason: :mount_boundary)
    end
  end

  describe "inherited git environment" do
    it "does not let a bare dotfiles repo make $HOME the root", :seam do
      bare = init_bare(File.join(tmp, "dotfiles.git"))
      cwd = mkdir("home", "scratch")

      with_env("GIT_DIR" => bare, "GIT_WORK_TREE" => home) do
        # Control: the trap IS armed -- git itself, asked from this cwd, answers
        # $HOME. A resolver that shelled out would inherit exactly this. The two
        # variables are passed EXPLICITLY rather than left to the ambient
        # environment, so the control proves what it claims even under a hook
        # that exports git variables of its own.
        expect(shell_toplevel(cwd, "GIT_DIR" => bare, "GIT_WORK_TREE" => home)).to eq(home)

        report = resolver.call(cwd:)

        expect(report.project).to have_attributes(root: cwd, cwd:, detected_by: :none)
        expect(report.refusal).to have_attributes(directory: home, reason: :home, rung: :none)
      end
    end

    it "scrubs the four git root-override variables from a child", :seam do
      bare = init_bare(File.join(tmp, "dotfiles.git"))
      cwd = mkdir("home", "scratch")

      with_env("GIT_DIR" => bare, "GIT_WORK_TREE" => home) do
        _out, _err, status = Open3.capture3(described_class::GIT_ENV_SCRUB, "git", "rev-parse", "--show-toplevel",
                                            chdir: cwd)

        expect(status).not_to be_success
      end
    end

    it "names every variable git reads to override root detection, each mapped to nil" do
      # `nil` VALUES, not a list of names: an absent key still leaks from the
      # parent -- {Lain::WorkerEnv}'s explicit-nil-scrubs rule.
      expect(described_class::GIT_ENV_SCRUB)
        .to eq("GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil, "GIT_CEILING_DIRECTORIES" => nil)
    end

    it "survives a round trip through WorkerEnv as a scrub rather than an omission" do
      env = Lain::WorkerEnv.new(cwd: tmp, env: { "GIT_DIR" => "/somewhere" }.merge(described_class::GIT_ENV_SCRUB)).env

      expect(env).to include("GIT_DIR" => nil, "GIT_WORK_TREE" => nil)
    end

    def init_bare(path)
      FileUtils.mkdir_p(path)
      git("init", "-q", "--bare", ".", chdir: path)
      path
    end

    # Scrubbed first, then the overrides this example is deliberately arming, so
    # the child's git environment is exactly what the example says it is and
    # nothing the parent happened to be carrying.
    def shell_toplevel(cwd, overrides)
      Open3.capture3(git_env.merge(overrides), "git", "rev-parse", "--show-toplevel", chdir: cwd).first.strip
    end
  end

  describe "the home directory it is handed" do
    it "refuses a home that is not absolute, naming the value" do
      expect { described_class.new(home: "relative/home", paths:) }
        .to raise_error(described_class::UnusableHome, %r{"relative/home"})
    end

    it "refuses an empty home rather than silently disabling the refusal set" do
      expect { described_class.new(home: "", paths:) }.to raise_error(described_class::UnusableHome)
    end

    it "refuses a home of / rather than refusing every directory there is" do
      expect { described_class.new(home: "/", paths:) }.to raise_error(described_class::UnusableHome)
    end

    it "refuses a tilde home lexically, never resolving it through getpwnam" do
      expect { described_class.new(home: "~", paths:) }.to raise_error(described_class::UnusableHome)
    end

    it "refuses a nil home" do
      expect { described_class.new(home: nil, paths:) }.to raise_error(described_class::UnusableHome)
    end

    it "reads $HOME from nothing but the injected value" do
      cwd = mkdir("elsewhere", "notes")
      mkdir("elsewhere", ".git")

      # The real process HOME is not this tree, so a resolver reading ENV would
      # accept `<tmp>/elsewhere` as a root; the injected home refuses it.
      report = described_class.new(home: File.join(tmp, "elsewhere"), paths:).call(cwd:)

      expect(report.project).to have_attributes(root: cwd, detected_by: :none)
      expect(report.refusal.reason).to eq(:home)
    end
  end

  describe "the Project it produces" do
    it "names cwd as :home kind when the walk falls back onto the home directory itself" do
      project = resolver.call(cwd: home).project

      expect(project).to have_attributes(root: home, cwd: home, kind: :home, detected_by: :none)
    end

    it "renames an unresolvable cwd to Project::Unresolvable rather than leaking an Errno" do
      expect { resolver.call(cwd: File.join(tmp, "nowhere")) }
        .to raise_error(Lain::Project::Unresolvable, /cwd/)
    end

    it "renames an unresolvable explicit root the same way, naming the root role" do
      expect { resolver.call(cwd: tmp, root: File.join(tmp, "nowhere")) }
        .to raise_error(Lain::Project::Unresolvable, /root/)
    end

    it "lets Project refuse an explicit root that does not contain cwd" do
      cwd = mkdir("work", "a")
      mkdir("work", "b")

      expect { resolver.call(cwd:, root: File.join(tmp, "work", "b")) }
        .to raise_error(ArgumentError, /must lie under root/)
    end

    it "reports a deeply frozen, Ractor-shareable value" do
      report = resolver.call(cwd: mkdir("work", "repo"))

      expect(Ractor.shareable?(report)).to be(true)
      expect(report.refusal.directory).to be_frozen
    end

    it "only ever reports a detected_by the Project value object accepts" do
      expect(described_class::WALKED_RUNGS + %i[flag none]).to match_array(Lain::Project::DETECTED_BY)
    end

    it "tries the walked rungs in the order Project documents them" do
      expect(described_class::WALKED_RUNGS)
        .to eq(Lain::Project::DETECTED_BY - %i[flag none])
    end

    it "only ever reports a refusal reason it declares" do
      cwd = mkdir("scratch")

      expect(Lain::Project::Resolver::Refusal::REASONS).to include(resolver.call(cwd:).refusal.reason)
    end
  end
end
