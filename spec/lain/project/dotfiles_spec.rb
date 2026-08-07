# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "pathname"

# A seam, not a unit: the bare arm's answer IS git's answer, and a fake git
# would test the fake (CLAUDE.md, Testing). Every fixture is built under
# `Dir.mktmpdir` and the home directory is injected, so nothing here can reach
# the developer's real `$HOME` -- which is also the only home a dotfiles
# detector would otherwise be tempted to read.
RSpec.describe Lain::Project::Dotfiles, :seam do
  around do |example|
    Dir.mktmpdir("lain-dotfiles") do |dir|
      @home = File.realpath(dir)
      example.run
    end
  end

  attr_reader :home

  # A dotfiles home is not ASCII-only, and a newline is a legal byte in a path.
  # Both stay in the DEFAULT fixture rather than in one example of their own --
  # the `DivergedRepo` guard (CLAUDE.md): a fixture that quietly stopped
  # producing them would delete the coverage that pins `ls-files -z` and stay
  # green, because git quotes the first and splits the second under any
  # newline-delimited reading.
  def awkward_names = [".café.conf", "we\nird.txt"]

  def tracked_names = [".zshrc", *awkward_names]

  def in_home(*names) = File.join(home, *names)

  def tracked_paths(names = tracked_names) = names.map { |name| in_home(name) }

  # The USER's git, driven against the fixture only. `-C home` because
  # `Shell::Out` has no `cwd:` and a pathspec resolves against the process
  # directory, which is this repository. Scrubbed for the same reason the
  # subject scrubs: a suite run from a pre-commit hook inherits GIT_DIR and
  # GIT_INDEX_FILE aimed at lain's own repository.
  def git(*argv)
    shell = Lain::Shell::Out.new("git", "-C", home, *argv, environment: described_class::GIT_CONTEXT_SCRUB)
    shell.run_command
    raise "git #{argv.join(" ")} failed: #{shell.stderr}" unless shell.exitstatus.zero?

    shell.stdout
  end

  def write(relative, body = "# fixture\n")
    path = in_home(relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  # The `~/.cfg` convention: a bare repository sitting in the home directory it
  # tracks. `core.worktree` is set because the acceptance criterion names it;
  # git answers `rev-parse` with a warning on stderr for that pairing and works
  # regardless, which is why nothing reads stderr here. `work_tree: nil` builds
  # the TUTORIAL's arrangement instead, which declares no work tree at all and
  # keeps it in a shell alias.
  def bare_repo(name: ".cfg", tracked: tracked_names, work_tree: home)
    repo = in_home(name)
    git("init", "--bare", "--quiet", repo)
    git("--git-dir", repo, "config", "core.worktree", work_tree) unless work_tree.nil?
    tracked.each { |relative| write(relative) }
    git("--git-dir", repo, "--work-tree", home, "add", *tracked) unless tracked.empty?
    repo
  end

  # The `shell_out_factory` seam, standing in for a git that cannot be made to
  # fail on demand -- CLAUDE.md describes the seam as existing for exactly this
  # failure injection, and the heavy specs already use it that way. It answers
  # per SUBCOMMAND so one example can break one step and leave the rest honest.
  # Anonymous rather than a named constant: a spec-local stand-in has no
  # business in the global namespace.
  def fake_git_class
    @fake_git_class ||= Struct.new(:stdout, :stderr, :exitstatus, :raises, keyword_init: true) do
      def run_command
        raise raises unless raises.nil?

        self
      end
    end
  end

  def fake_git(**attrs) = fake_git_class.new(stdout: "", stderr: "", exitstatus: 0, **attrs)

  def git_stub(rev_parse: {}, config: {}, ls_files: {})
    lambda do |*argv, **|
      answer = if argv.include?("rev-parse") then rev_parse
               elsif argv.include?("config") then config
               else ls_files
               end
      fake_git(**answer)
    end
  end

  def detect_with(factory) = described_class.detect(home:, shell_out_factory: factory)

  # Asks the subject, in a fresh Ruby, whether it covers the spelling THAT
  # process's own `Dir.children` gives the non-ASCII fixture file.
  def c_locale_script
    <<~RUBY
      $LOAD_PATH.unshift #{File.expand_path("lib").inspect}
      require "lain"
      home = #{home.inspect}
      child = Dir.children(home).find { |entry| entry.b.include?("caf") }
      print Lain::Project::Dotfiles.detect(home:).covers?(File.join(home, child))
    RUBY
  end

  # `~/dotfiles/<pkg>/<entry>` linked into place at `at`.
  def stow_link(package: "zsh", entry: ".zshrc", at: nil, root: "dotfiles")
    target = write(File.join(root, package, entry))
    link = in_home(at || entry)
    FileUtils.mkdir_p(File.dirname(link))
    File.symlink(target, link)
    target
  end

  def detect = described_class.detect(home:)

  describe "a bare repository whose work-tree is the home root" do
    it "reports :bare and names the repository directory" do
      repo = bare_repo

      expect(detect).to have_attributes(flavour: :bare, repository: repo)
      expect(detect.to_s).to include(repo)
    end

    it "offers the tracked file set as the editable surface, never the home directory" do
      bare_repo(tracked: [*tracked_names, ".config/git/config"])

      expected = [*tracked_paths, in_home(".config/git/config")]

      expect(detect.editable_surface).to match_array(expected)
    end

    # `ls-files -z` is doing real work: without it git returns a non-ASCII name
    # as the literal 18-character string ".caf\303\251.conf" under
    # `core.quotePath`, and a newline in a name splits into two surface entries
    # pointing at nothing.
    it "reports an awkward tracked path byte for byte, and at a path that exists" do
      bare_repo

      expect(detect.editable_surface).to include(*tracked_paths(awkward_names))
      expect(tracked_paths(awkward_names).select { |path| File.exist?(path) }).to eq(tracked_paths(awkward_names))
    end

    it "detects the tutorial arrangement, which declares no work tree at all" do
      bare_repo(work_tree: nil)

      expect(detect.flavour).to eq(:bare)
    end

    # `core.worktree` comes back from a subprocess as ASCII-8BIT and the home it
    # is compared against carries the filesystem encoding: same bytes, different
    # tag, unequal. The default fixture sets `core.worktree`, so this IS the
    # acceptance criterion's own arrangement -- just never before with a home
    # whose name needs more than ASCII.
    it "detects a bare home whose own name is not ASCII" do
      nested = in_home("maisón")
      FileUtils.mkdir_p(nested)
      repo = File.join(nested, ".cfg")
      git("init", "--bare", "--quiet", repo)
      git("--git-dir", repo, "config", "core.worktree", nested)

      expect(described_class.detect(home: nested).flavour).to eq(:bare)
    end

    it "labels every surface path with the filesystem's own encoding" do
      bare_repo

      expect(detect.editable_surface.map(&:encoding).uniq).to eq([Encoding.find("filesystem")])
    end

    # `git ls-files` reports the subtree below the CURRENT directory: run from
    # `~/sub` it names `deep.txt` rather than `sub/deep.txt`, which is both a
    # truncated surface and a set of paths that join back to the wrong place.
    it "reports the same surface whichever directory the process is in" do
      bare_repo(tracked: [".zshrc", "sub/deep.txt"])

      surface = Dir.chdir(in_home("sub")) { detect.editable_surface }

      expect(surface).to contain_exactly(in_home(".zshrc"), in_home("sub/deep.txt"))
    end

    it "does not report :bare for an ordinary repository at the same name" do
      git("init", "--quiet", in_home(".cfg"))

      expect(detect.flavour).to eq(:plain)
    end

    it "does not report :bare when the declared work-tree is somewhere else" do
      bare_repo(work_tree: File.join(home, "elsewhere"))

      expect(detect.flavour).to eq(:plain)
    end
  end

  describe "a stow package linked into the home root" do
    it "reports :stow and joins the package tree to the editable surface" do
      target = stow_link

      expect(detect.flavour).to eq(:stow)
      expect(detect.editable_surface).to include(in_home("dotfiles"), in_home("dotfiles", "zsh"))
      expect(detect.editable_surface).not_to include(target)
    end

    it "keeps the home root in the surface alongside the packages" do
      stow_link

      expect(detect.editable_surface).to include(home)
    end

    it "follows a known link that sits below the first level" do
      stow_link(package: "nvim", entry: ".config/nvim/init.lua", at: ".config/nvim")

      expect(detect.flavour).to eq(:stow)
      expect(detect.editable_surface).to include(in_home("dotfiles", "nvim"))
    end

    it "ignores a symlink that lands outside any package tree" do
      File.symlink(write("notes/actual.md"), in_home(".zshrc"))

      expect(detect.flavour).to eq(:plain)
    end

    it "ignores a symlink into the package tree ROOT rather than into a package" do
      FileUtils.mkdir_p(in_home("dotfiles"))
      File.symlink(in_home("dotfiles"), in_home(".zshrc"))

      expect(detect.flavour).to eq(:plain)
    end

    # Stow's layout is `<tree>/<pkg>/<entry>`, so a file lying loose in the tree
    # has no package to name -- and answering the file itself would put a
    # regular file in a surface whose members are places an edit lands.
    it "ignores a symlink to a file lying loose in the package tree" do
      File.symlink(write("dotfiles/README.md"), in_home(".zshrc"))

      expect(detect.flavour).to eq(:plain)
    end

    it "survives a dangling symlink at the first level" do
      FileUtils.mkdir_p(in_home("dotfiles", "zsh"))
      File.symlink(in_home("dotfiles", "zsh", "gone"), in_home(".zshrc"))

      expect { detect }.not_to raise_error
      expect(detect.flavour).to eq(:plain)
    end

    # The bound the card names: a recursive hunt for symlinks would stat every
    # file under `~/.cache`, so a link buried below the first level and not on
    # the known list is simply not seen.
    it "does not walk below the first level to find a link" do
      target = write(File.join("dotfiles", "zsh", ".zshrc"))
      FileUtils.mkdir_p(in_home(".cache", "deep", "nest"))
      File.symlink(target, in_home(".cache", "deep", "nest", ".zshrc"))

      expect(detect.flavour).to eq(:plain)
    end

    # Enough packages that `readdir` order cannot pass for sorted order by
    # accident -- with two, ext4's hashed ordering matched the sort and an
    # unsorted implementation survived. The subject's claim is that two runs
    # against one home answer identically, and only sorting delivers it.
    it "orders the packages by link name, so two runs against one home answer alike" do
      names = (0..11).map { |n| format("%02d", n) }
      names.reverse_each { |n| stow_link(package: "pkg#{n}", entry: ".rc#{n}") }

      expect(detect.packages).to eq(names.map { |n| in_home("dotfiles", "pkg#{n}") })
    end

    # `~/dotfiles` being a symlink to the real repository is a common
    # arrangement, and {Project} resolves root and cwd precisely so a prefix
    # comparison means ONE thing. A surface holding the unresolved join would
    # not contain the resolved path of the file an edit targets.
    it "reports the resolved package directory when the tree is itself a symlink" do
      FileUtils.mkdir_p(in_home("store", "zsh"))
      File.write(in_home("store", "zsh", ".zshrc"), "x")
      File.symlink(in_home("store"), in_home("dotfiles"))
      File.symlink(in_home("dotfiles", "zsh", ".zshrc"), in_home(".zshrc"))

      expect(detect.editable_surface).to include(in_home("store"), in_home("store", "zsh"))
      expect(detect).to be_covers(File.realpath(in_home(".zshrc")))
    end

    # THE widening the card forbids. `~/dotfiles` pointing at a directory ABOVE
    # home, plus one link into a sibling of home, put that ancestor and its
    # children in the surface -- two symlinks the running user can create, and
    # the agent can create them through an ordinary write.
    it "refuses a package tree that contains the home root" do
      nested = in_home("h")
      FileUtils.mkdir_p(nested)
      outside = write("outside/notes.txt")
      File.symlink(home, File.join(nested, "dotfiles"))
      File.symlink(outside, File.join(nested, ".zshrc"))

      flavour = described_class.detect(home: nested)

      expect(flavour).to have_attributes(flavour: :plain, editable_surface: [nested])
      expect(flavour).not_to be_covers(outside)
    end

    # The guard has to resolve BOTH sides. `.detect` builds its home with
    # `File.expand_path`, never `realpath`, so a home handed over by a symlinked
    # spelling compared its link path against the tree's resolved one, found no
    # ancestry, and admitted the real home's own parent. The identical tree,
    # spelled by realpath, was refused.
    it "refuses a tree that contains the home root's REAL location" do
      real = in_home("A", "home")
      FileUtils.mkdir_p(real)
      victim = write("A/victim/secret.txt")
      FileUtils.mkdir_p(in_home("B"))
      spelled = in_home("B", "link")
      File.symlink(real, spelled)
      File.symlink(in_home("A"), File.join(real, "dotfiles"))
      File.symlink(victim, File.join(real, ".zshrc"))

      flavour = described_class.detect(home: spelled)

      expect(flavour).to have_attributes(flavour: :plain, editable_surface: [spelled])
      expect(flavour).not_to be_covers(victim)
    end

    # The equality arm of the guard, which the ancestor cases above cannot
    # reach: `~/dotfiles -> ~` resolves to home itself, not to something above
    # it.
    it "refuses a tree that resolves to the home root itself" do
      write("sub/notes.md")
      File.symlink(home, in_home("dotfiles"))
      File.symlink(in_home("sub", "notes.md"), in_home(".zshrc"))

      expect(detect).to have_attributes(flavour: :plain, editable_surface: [home])
    end

    # The `"//"` trap again, this time in the guard: `"#{real}/"` at the
    # filesystem root builds `"//"`, which no home starts with, so the one tree
    # that must always be refused would be the one that got through.
    it "refuses a tree that resolves to the filesystem root" do
      File.symlink(File::SEPARATOR, in_home("dotfiles"))
      File.symlink("/etc/hosts", in_home(".zshrc"))

      expect(detect.flavour).to eq(:plain)
      expect(detect).not_to be_covers("/etc/hosts")
    end

    # Every other stow fixture here is ASCII, which is exactly the shape the
    # `-z` defect had: a spelling nobody exercised. With a non-ASCII TREE the
    # prefix is non-ASCII bytes, and an unlabelled target compared against it
    # raises `Encoding::CompatibilityError` out of `start_with?` -- which
    # `package_for` does not rescue, because it is not a `SystemCallError`.
    it "follows a link whose tree, package and entry are all non-ASCII" do
      nested = in_home("maisón")
      package = File.join(nested, "dotfiles", "café")
      FileUtils.mkdir_p(package)
      target = File.join(package, ".zshrc")
      File.write(target, "x")
      File.symlink(target, File.join(nested, ".zshrc"))

      flavour = described_class.detect(home: nested)

      expect(flavour.flavour).to eq(:stow)
      expect(flavour.editable_surface).to include(package)
      expect(flavour).to be_covers(target)
    end

    # The guard is ANCESTRY, not "outside home" -- a tree on a mount somewhere
    # else is the arrangement worth keeping, and it keeps working.
    it "keeps a package tree that lives outside home without containing it" do
      nested = in_home("h")
      FileUtils.mkdir_p(nested)
      target = write("nas/dots/zsh/.zshrc")
      File.symlink(in_home("nas", "dots"), File.join(nested, "dotfiles"))
      File.symlink(target, File.join(nested, ".zshrc"))

      flavour = described_class.detect(home: nested)

      expect(flavour.flavour).to eq(:stow)
      expect(flavour.editable_surface).to include(in_home("nas", "dots"), in_home("nas", "dots", "zsh"))
    end

    # `Dir.children` raises rather than answering for a home whose mode denies
    # a read. The module comment promises every arm reduces the surface rather
    # than failing, and a raw `SystemCallError` escaping `exe/lain`'s
    # `rescue Lain::Error` is what {Project::Unresolvable} exists to prevent.
    it "reports :plain rather than raising when the home directory cannot be listed" do
      FileUtils.chmod(0o000, home)

      expect { described_class.detect(home:) }.not_to raise_error
      expect(described_class.detect(home:).flavour).to eq(:plain)
    ensure
      FileUtils.chmod(0o755, home)
    end
  end

  describe "neither convention" do
    it "reports :plain with the root alone as the editable surface" do
      write(".zshrc")
      FileUtils.mkdir_p(in_home("src"))

      expect(detect).to have_attributes(flavour: :plain, editable_surface: [home])
    end
  end

  describe "a flavour that is wrong about its own evidence" do
    it "offers an empty surface when the named repository is not one" do
      FileUtils.mkdir_p(in_home(".cfg"))
      bare = described_class::Bare.new(home:, repository: in_home(".cfg"))

      expect(bare.flavour).to eq(:bare)
      expect(bare.editable_surface).to be_empty
    end

    it "offers an empty surface when the named repository does not exist" do
      bare = described_class::Bare.new(home:, repository: in_home(".cfg"))

      expect(bare.editable_surface).to be_empty
    end
  end

  # Three inherited git variables, each a different way for a leaked context to
  # change this answer. The subject scrubs them all; without the scrub the
  # first two below flip the answer outright.
  describe "an inherited git context" do
    it "does not let GIT_INDEX_FILE name another repository's files as editable" do
      bare_repo
      git("init", "--quiet", in_home("other"))
      write("other/leaked_from_other.txt")
      git("-C", in_home("other"), "add", "leaked_from_other.txt")

      with_env("GIT_INDEX_FILE" => in_home("other", ".git", "index")) do
        expect(detect.editable_surface).to match_array(tracked_paths)
      end
    end

    # GIT_COMMON_DIR and GIT_WORK_TREE are the two that reach this answer, and
    # both do it the same way: `rev-parse --is-bare-repository` answers FALSE
    # for the very repository the command line named, so a real dotfiles home
    # reports :plain. Measured, unscrubbed, against a repository that is bare.
    #
    # There is deliberately no GIT_CONFIG_* example here any more. It used to
    # sit in this group and passed with the scrub, without those two entries,
    # and with no scrub at all -- `--local` had made it vacuous, and the entries
    # it appeared to hold were not the ones doing the work.
    it "does not let GIT_COMMON_DIR make a bare repository report as ordinary" do
      bare_repo
      git("init", "--quiet", in_home("other"))

      with_env("GIT_COMMON_DIR" => in_home("other", ".git")) do
        expect(detect.flavour).to eq(:bare)
      end
    end

    it "does not let GIT_WORK_TREE make a bare repository report as ordinary" do
      bare_repo
      FileUtils.mkdir_p(in_home("other"))

      with_env("GIT_WORK_TREE" => in_home("other")) do
        expect(detect.flavour).to eq(:bare)
        expect(detect.editable_surface).to match_array(tracked_paths)
      end
    end

    it "does not let GIT_DIR make a home holding no repository :bare" do
      elsewhere = in_home("elsewhere.git")
      git("init", "--bare", "--quiet", elsewhere)

      with_env("GIT_DIR" => elsewhere) do
        expect(detect.flavour).to eq(:plain)
      end
    end

    # GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM are deliberately NOT scrubbed --
    # honouring the user's real global config is what makes their settings
    # apply. So the work-tree read has to be confined to the repository
    # instead: `core.worktree` in a user's own `~/.gitconfig` is legal, and
    # would otherwise answer for a repository that declares no such key.
    it "reads core.worktree from the repository, not from the user's global config" do
      bare_repo(work_tree: nil)
      global = write("global.gitconfig", "[core]\n\tworktree = /elsewhere\n")

      with_env("GIT_CONFIG_GLOBAL" => global) do
        expect(detect.flavour).to eq(:bare)
      end
    end
  end

  # Every way git can fail to deliver an answer, injected through the
  # `shell_out_factory` seam because a real git cannot be asked to be absent,
  # signalled or slow. All of them mean "no repository", never an exception out
  # of a session start and never an answer read from a failed run.
  describe "a git that does not answer" do
    before { FileUtils.mkdir_p(in_home(".cfg")) }

    it "does not read an answer out of a run that exited non-zero" do
      factory = git_stub(rev_parse: { stdout: "true\n", exitstatus: 128 },
                         config: { stdout: "#{home}\n" }, ls_files: { stdout: ".zshrc\0" })

      expect(detect_with(factory).flavour).to eq(:plain)
    end

    # A child killed by a signal reports a NIL exit status, and `nil.zero?` is
    # a NoMethodError in place of the refusal ({ShadowGit::Failed} names the
    # same trap). The OOM killer reaping a `ls-files` over a large tree is the
    # realistic case.
    it "does not read an answer out of a run a signal killed" do
      factory = git_stub(rev_parse: { stdout: "true\n", exitstatus: nil },
                         config: { stdout: "#{home}\n" }, ls_files: { stdout: ".zshrc\0" })

      expect(detect_with(factory).flavour).to eq(:plain)
    end

    it "treats a git that is not installed as no repository" do
      factory = git_stub(rev_parse: { raises: Errno::ENOENT.new("git") })

      expect { detect_with(factory) }.not_to raise_error
      expect(detect_with(factory).flavour).to eq(:plain)
    end

    it "treats a git that outlived its bound as no repository" do
      factory = git_stub(rev_parse: { raises: Lain::Shell::Out::Timeout.new("git timed out") })

      expect { detect_with(factory) }.not_to raise_error
      expect(detect_with(factory).flavour).to eq(:plain)
    end

    it "hands a forced Bare an empty surface when ls-files never answers" do
      factory = git_stub(rev_parse: { stdout: "true\n" }, config: { stdout: "#{home}\n" },
                         ls_files: { raises: Lain::Shell::Out::Timeout.new("git timed out") })
      bare = described_class::Bare.new(home:, repository: in_home(".cfg"), shell_out_factory: factory)

      expect(bare.editable_surface).to be_empty
    end

    # The `File.directory?` guard doing real work: five names times one
    # `rev-parse` each is five processes at every session start, paid by every
    # user who keeps their dotfiles some other way -- which is most of them.
    it "spawns no git at all for a home holding no repository" do
      FileUtils.rmdir(in_home(".cfg"))
      calls = []
      factory = lambda do |*argv, **|
        calls << argv
        fake_git(exitstatus: 1)
      end

      detect_with(factory)

      expect(calls).to be_empty
    end

    # The bound is the point: this runs while a session is starting, so a
    # wedged filesystem must not hold it for the ten minutes `Shell::Out`
    # defaults to.
    it "bounds every call well under the default, and scrubs every one of them" do
      calls = []
      factory = lambda do |*_argv, environment:, timeout:|
        calls << { environment:, timeout: }
        fake_git(exitstatus: 1)
      end

      detect_with(factory)

      expect(calls).not_to be_empty
      expect(calls.map { |call| call[:timeout] }).to all(eq(described_class::GIT_TIMEOUT))
      expect(calls.map { |call| call[:environment] }).to all(eq(described_class::GIT_CONTEXT_SCRUB))
      expect(described_class::GIT_TIMEOUT).to be < Lain::Shell::Out::DEFAULT_TIMEOUT
    end
  end

  # The join predicate the surface exists for. Shipped on the flavour rather
  # than left to every consumer, because this repository has got that exact
  # prefix test wrong before -- {Project}'s own `cwd_under_root` built `"//"`
  # at the filesystem root and refused every cwd under it.
  describe "#covers?" do
    it "answers for a bare home from the tracked set alone" do
      bare_repo

      expect(detect).to be_covers(in_home(".zshrc"))
      expect(detect).not_to be_covers(in_home("Downloads", "report.pdf"))
    end

    it "answers for a stow home from the package tree and from the root" do
      stow_link

      expect(detect).to be_covers(in_home("dotfiles", "zsh", ".zshrc"))
      expect(detect).to be_covers(in_home("notes.md"))
      expect(detect).not_to be_covers(File.join(File.dirname(home), "elsewhere", "notes.md"))
    end

    it "answers for a plain home from the root alone" do
      expect(detect).to be_covers(in_home("notes.md"))
      expect(detect).to be_covers(home)
    end

    it "does not cover a sibling that merely shares the root's name" do
      expect(detect).not_to be_covers("#{home}-other/notes.md")
    end

    # The `"//"` trap, which is a real root on a real machine.
    it "covers a path under the filesystem root when that is the whole surface" do
      expect(described_class::Plain.new(home: "/")).to be_covers("/etc/hosts")
    end

    # A bare surface holds FILES, so only the equality arm may fire: a tracked
    # file has no children, and a prefix match on one claims paths that cannot
    # exist.
    it "does not cover a path below a tracked file" do
      bare_repo

      expect(detect).not_to be_covers(in_home(".zshrc", "evil"))
    end

    # Every path in this neighbourhood comes from a subprocess at some point --
    # the surface itself did. Comparing tags rather than bytes raised
    # `Encoding::CompatibilityError`, which is not a {Lain::Error} and so
    # escapes `exe/lain`'s rescue.
    it "answers for a path handed over as raw filesystem bytes" do
      bare_repo

      expect(detect).to be_covers(in_home(".café.conf").b)
    end

    it "answers false rather than raising when asked about nothing at all" do
      expect(detect.covers?(nil)).to be(false)
    end

    it "accepts a Pathname, as any path-shaped argument in this codebase may be" do
      expect(detect).to be_covers(Pathname(in_home("notes.md")))
    end

    # {Sensitivity} folds `..` through `Pathname#cleanpath` before matching, and
    # this cites it as the model, so it has to do the same or stop citing it.
    it "folds `..` before comparing, as the classifier it cites does" do
      expect(detect).not_to be_covers(in_home("..", "etc", "passwd"))
    end

    # `Encoding.find("filesystem")` is fixed at process start, so a non-UTF-8
    # locale can only be exercised in a CHILD. Under `LC_ALL=C` Ruby hands back
    # `Dir.children` in ASCII-8BIT while the surface is labelled US-ASCII, and
    # comparing tags made `covers?` raise for the process's own natural spelling
    # of its own file.
    it "answers under a C locale, where the filesystem encoding is not UTF-8" do
      bare_repo
      shell = Lain::Shell::Out.new("ruby", "-e", c_locale_script,
                                   environment: { "LC_ALL" => "C", "LANG" => "C" })
      shell.run_command

      expect(shell.stdout).to eq("true"), -> { "exit #{shell.exitstatus}: #{shell.stderr}" }
    end
  end

  # `--git-dir` resolves against the PROCESS directory while `-C d` resolves
  # against `d`, so a relative home read two different directories: `:bare`
  # with an empty surface, which is the shape of a detection that half worked.
  describe "a relative home" do
    it "answers exactly as the absolute spelling does" do
      bare_repo

      surface = Dir.chdir(File.dirname(home)) do
        described_class.detect(home: File.basename(home)).editable_surface
      end

      expect(surface).to match_array(tracked_paths)
    end
  end

  describe "both conventions at once" do
    it "answers :bare, and answers the same way every time" do
      bare_repo(tracked: [".bashrc"])
      stow_link

      expect(Array.new(3) { detect.flavour }).to eq(%i[bare bare bare])
    end
  end

  describe ".for a Project" do
    def project(kind:) = Lain::Project.new(root: home, cwd: home, kind:, detected_by: :flag)

    it "detects behind a home-kind root" do
      bare_repo

      expect(described_class.for(project(kind: :home)).flavour).to eq(:bare)
    end

    it "reports :plain for a project-kind root, whatever sits in it" do
      bare_repo

      expect(described_class.for(project(kind: :project))).to have_attributes(flavour: :plain,
                                                                              editable_surface: [home])
    end
  end
end
