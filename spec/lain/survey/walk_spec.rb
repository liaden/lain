# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The admission half of a survey: which paths under a root may be read at all.
#
# Every fixture is built under `Dir.mktmpdir` and the classifier's home is
# INJECTED at a path nothing here creates, so no example can reach the
# developer's real `$HOME` -- the one home a sensitivity table would otherwise
# be tempted to read. The secret-shaped fixtures below are literal and obviously
# fake; none of them is harvested from this machine.
RSpec.describe Lain::Survey::Walk do
  subject(:walk) { described_class.new(root:, sensitivity:) }

  # No IO is done against this, and none may be: the classifier is lexical by
  # contract, so a home that does not exist is a home.
  let(:home) { "/home/surveyor" }
  let(:sensitivity) { Lain::Sensitivity.new(home:, cwd: root) }
  let(:root) { @root }

  # Obviously fake, and literal: a fixture sliced from the detector's own tables
  # cannot fail when those tables are wrong.
  let(:private_key) do
    "-----BEGIN OPENSSH PRIVATE KEY-----\n" \
      "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAM0ZBS0U\n" \
      "-----END OPENSSH PRIVATE KEY-----\n"
  end
  let(:dotenv) { "API_KEY=sk-ant-api03-NOT0A0REAL0KEY0000000000000000\n" }
  # A PNG signature and a run of NULs: binary by any reading, and short enough
  # that the bounded sniff below is what finds it.
  let(:png) { "\x89PNG\r\n\x1a\n#{"\0" * 32}".b }

  around do |example|
    Dir.mktmpdir("lain-survey-walk") { |made| @root = File.realpath(made) and example.run }
  end

  def write(relative, body = "# fixture\n")
    File.join(root, relative).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, body)
    end
  end

  def paths = walk.files.map(&:path)

  def withheld_paths = walk.withheld.map(&:path)

  def listing(relative) = walk.files.find { |file| file.path == relative }

  describe "what enters the corpus" do
    it "keeps a denied path out and says why it is out" do
      write(".ssh/id_ed25519", private_key)
      write("app.rb")

      expect(paths).to eq(["app.rb"])
      expect(walk.withheld).to contain_exactly(
        an_object_having_attributes(path: ".ssh/id_ed25519", reason: :denied,
                                    explanation: "a protected path")
      )
    end

    # The routing is two-way, not three. Withholding a gated file wholesale
    # would make a survey STRICTER than the read path over the same file, which
    # projects it to its released regions instead.
    it "lists a gated path, carrying the verdict that says why it will arrive masked" do
      write(".env", dotenv)

      expect(paths).to eq([".env"])
      expect(listing(".env")).to have_attributes(gated?: true, explanation: "a credential-shaped name")
    end

    it "leaves an ordinary path ordinary, so nothing downstream has to ask twice" do
      write("app.rb")

      expect(listing("app.rb").verdict).to have_attributes(ordinary?: true, gated?: false)
    end

    it "withholds binary content and lists the text beside it" do
      write("logo.png", png)
      write("app.rb")

      expect(paths).to eq(["app.rb"])
      expect(walk.withheld).to contain_exactly(
        an_object_having_attributes(path: "logo.png", reason: :binary)
      )
    end

    # The order is the whole point: classification answers from the NAME, before
    # anything is opened. A denied file whose bytes are binary would be reported
    # as binary by a walk that sniffed first -- so this pins the sequence
    # without mocking `File.open`.
    it "classifies before it opens, so a denied path's bytes are never read" do
      write(".aws/credentials", "[default]\naws_secret_access_key=\0\0\0FAKE\n".b)

      expect(walk.withheld.map(&:reason)).to eq([:denied])
    end
  end

  # A link is TWO names for one file, and classifying only the one the walk
  # discovered is how a `.netrc` reaches a corpus wearing the name `notes.txt`.
  # The amplification is what makes this the walk's problem and not the read
  # path's: `read_file` needs a model to NAME a path, while a survey discovers
  # and follows every link in a tree unasked.
  describe "a symbolic link" do
    let(:outside) { @outside }

    around do |example|
      Dir.mktmpdir("lain-survey-outside") { |made| @outside = File.realpath(made) and example.run }
    end

    def outside_file(name, body)
      File.join(outside, name).tap { |path| File.write(path, body) }
    end

    def link(relative, target)
      File.join(root, relative).tap { |path| File.symlink(target, path) }
    end

    it "withholds a link to a denied file, though the link's own name is ordinary" do
      link("notes.txt", outside_file(".netrc", "machine example.com login sam password NOTAREALPASSWORD\n"))

      expect(paths).to be_empty
      expect(walk.withheld).to contain_exactly(
        an_object_having_attributes(path: "notes.txt", reason: :denied, explanation: "a protected path")
      )
    end

    it "withholds a link to a private key, so its bytes never reach the projection" do
      FileUtils.mkdir_p(File.join(outside, ".ssh"))
      link("reference.txt", outside_file(".ssh/id_rsa", private_key))

      expect(paths).to be_empty
      expect(walk.withheld.map(&:reason)).to eq([:denied])
    end

    # The probe's own case: a key file whose NAME no rule matches, linked in
    # from outside. Denial cannot see it, and containment is what stops it --
    # which is why both tests exist and not just the first.
    it "withholds a link to a key the classifier cannot name, on containment alone" do
      link("reference.txt", outside_file("id_rsa", private_key))

      expect(paths).to be_empty
      expect(walk.withheld.map(&:reason)).to eq([:outside])
    end

    # Denied or not, a link out of the tree is content the human did not point
    # at, so it is disclosed rather than silently surveyed.
    it "withholds a link that leaves the surveyed tree, whatever it points at" do
      link("elsewhere.md", outside_file("ordinary.md", "# notes\n"))

      expect(paths).to be_empty
      expect(walk.withheld).to contain_exactly(
        an_object_having_attributes(path: "elsewhere.md", reason: :outside)
      )
    end

    it "lists a link that stays inside the tree, because that is one of the tree's own files" do
      write("chapter.tex", "\\section{One}\n")
      link("latest.tex", File.join(root, "chapter.tex"))

      expect(paths).to eq(%w[chapter.tex latest.tex])
    end

    it "takes the stricter of the two names, so a link to a gated file arrives gated" do
      write(".env", dotenv)
      link("settings.txt", File.join(root, ".env"))

      expect(listing("settings.txt")).to have_attributes(gated?: true, explanation: "a credential-shaped name")
    end

    # Containment is by SEGMENT, so a sibling directory whose path merely
    # starts with the root's is outside it. `<root>-backup` is the shape that
    # matters: a plain prefix test reads it as inside and surveys somebody's
    # backup copy.
    it "withholds a link into a sibling directory whose path starts with the root's" do
      sibling = "#{root}-backup"
      FileUtils.mkdir_p(sibling)
      File.write(File.join(sibling, "secrets.md"), "# copied notes\n")
      link("backup.md", File.join(sibling, "secrets.md"))

      expect(paths).to be_empty
      expect(walk.withheld.map(&:reason)).to eq([:outside])
    ensure
      FileUtils.remove_entry(sibling, true)
    end

    # The root's OWN spelling may be a link -- `/tmp` on a Mac, a checkout
    # reached through one -- and containment judged against the unresolved
    # spelling would then declare every file in the tree outside the tree.
    # Without this fixture that claim is only a comment: every other example
    # here roots at a `realpath`, so the case is never built.
    it "contains its own tree when the root itself is reached through a link" do
      through_link = "#{root}-via-link"
      File.symlink(root, through_link)
      write("chapter.tex", "\\section{One}\n")
      link("latest.tex", File.join(root, "chapter.tex"))

      walked = described_class.new(root: through_link, sensitivity:)

      expect(walked.files.map(&:path)).to eq(%w[chapter.tex latest.tex])
      expect(walked.withheld).to be_empty
    ensure
      FileUtils.rm_f(through_link)
    end

    it "skips a broken link rather than dying on it" do
      link("dangling.md", File.join(root, "never-written.md"))
      write("app.rb")

      expect(paths).to eq(["app.rb"])
      expect(walk.withheld).to be_empty
    end

    it "lists nothing for a linked directory, the same as for a real one" do
      FileUtils.mkdir_p(File.join(outside, "docs"))
      link("docs", File.join(outside, "docs"))
      write("app.rb")

      expect(paths).to eq(["app.rb"])
    end
  end

  describe "the size it reports" do
    it "carries a byte size for every listed path" do
      bodies = Array.new(50) { |index| "#{"x" * index}\n" }
      bodies.each_with_index { |body, index| write("file#{format("%02d", index)}.txt", body) }

      expect(walk.files.map(&:size)).to eq(bodies.map(&:bytesize))
      expect(walk.files.size).to eq(50)
    end

    # A full read is not permitted, and this is what says so behaviourally: a
    # NUL past the sniff bound is not seen, so the file is text as far as the
    # walk is concerned. The divergence from grep's semantics is deliberate.
    #
    # The offsets are LITERAL and not derived from {Walk::SNIFF}: a fixture
    # sized from the constant it exists to pin grows with the constant, so an
    # unbounded sniff would pass it (measured -- that mutant survived until
    # these numbers were written out).
    it "sniffs a bounded prefix, so a NUL past the bound does not make a file binary" do
      write("big.txt", "#{"a" * 20_000}\0tail\n")

      expect(paths).to eq(["big.txt"])
      expect(listing("big.txt").size).to eq(20_006)
    end

    it "does see a NUL inside the bound, so the sniff is a sniff and not a formality" do
      write("small.bin", "#{"a" * 100}\0tail\n")

      expect(paths).to be_empty
      expect(walk.withheld.map(&:reason)).to eq([:binary])
    end
  end

  describe "determinism" do
    it "returns the same paths in the same order, and the same withheld, twice over" do
      write("b.rb")
      write("a/deep.rb")
      write("logo.png", png)
      write(".ssh/id_rsa", private_key)

      first = described_class.new(root:, sensitivity:)
      second = described_class.new(root:, sensitivity:)

      expect(second.files.map(&:path)).to eq(first.files.map(&:path))
      expect(second.withheld).to eq(first.withheld)
    end

    it "sorts what it lists, so a filesystem's own order never reaches a reviewer" do
      %w[z.rb m.rb a.rb].each { write(_1) }

      expect(paths).to eq(%w[a.rb m.rb z.rb])
    end
  end

  # The containment rule itself, as a function of two paths. It answers here
  # rather than only through a walk because the case that matters most cannot
  # be built as a fixture: a survey rooted at `/` would walk the filesystem.
  # The prefix-versus-segment bug is the one a mutant found, so this is the
  # expression worth pinning directly.
  describe ".contains?" do
    it "holds a file directly inside the tree" do
      expect(described_class.contains?("/repo", "/repo/app.rb")).to be(true)
    end

    it "holds a file deep inside the tree" do
      expect(described_class.contains?("/repo", "/repo/a/b/c.rb")).to be(true)
    end

    it "holds the tree itself" do
      expect(described_class.contains?("/repo", "/repo")).to be(true)
    end

    # A whole SEGMENT, so a sibling whose path merely starts with the root's is
    # outside it -- somebody's backup copy is not part of the survey.
    it "refuses a sibling whose path merely starts with the root's" do
      expect(described_class.contains?("/repo", "/repo-backup/secrets.md")).to be(false)
    end

    it "refuses a path above the tree" do
      expect(described_class.contains?("/repo/docs", "/repo/app.rb")).to be(false)
    end

    # The filesystem root is the one tree whose spelling already ends in the
    # separator, so appending another gives `//`, which nothing starts with --
    # and every link in the tree would be withheld as outside it.
    it "holds everything when the tree is the filesystem root" do
      expect(described_class.contains?("/", "/etc/passwd")).to be(true)
      expect(described_class.contains?("/", "/")).to be(true)
    end
  end

  describe "a root it cannot walk" do
    it "refuses a path naming nothing, as a Lain::Error a frontend can render" do
      expect { described_class.new(root: File.join(root, "absent"), sensitivity:) }
        .to raise_error(described_class::Refused, /absent/)
      expect(described_class::Refused).to be < Lain::Error
    end

    it "refuses a file, because a corpus is a body of files and not one of them" do
      expect { described_class.new(root: write("app.rb"), sensitivity:) }
        .to raise_error(described_class::Refused)
    end
  end

  describe "a listing" do
    it "resolves each path against the root, so a reader never rejoins it by hand" do
      write("a/deep.rb")

      expect(listing("a/deep.rb").absolute).to eq(File.join(root, "a/deep.rb"))
    end

    it "is deeply frozen, so it crosses a Ractor as it stands" do
      write("app.rb")

      expect(Ractor.shareable?(listing("app.rb"))).to be(true)
    end
  end

  describe "what it walks" do
    it "reaches nested directories and lists their files relative to the root" do
      write("a/b/c.rb")

      expect(paths).to eq(["a/b/c.rb"])
    end

    it "lists dotfiles, which is where a survey's most interesting prose lives" do
      write(".rubocop.yml", "AllCops:\n")

      expect(paths).to eq([".rubocop.yml"])
    end

    it "lists no directory, only what can be read" do
      write("a/b/c.rb")

      expect(walk.files.map(&:absolute)).to all(satisfy { File.file?(_1) })
    end

    it "is enumerable over its listings, so a caller composes rather than indexes" do
      write("a.rb")
      write("b.rb")

      expect(walk.map(&:path)).to eq(%w[a.rb b.rb])
    end

    # A latin-1 filename is ordinary in a real documents or LaTeX tree, and
    # `String#split` raises `ArgumentError` on one -- which took the whole
    # survey down with a backtrace rather than a `Lain::Error`. Every path
    # comparison here is on BYTES for that reason.
    it "survives a filename that is not valid UTF-8, which a documents tree has" do
      write("caf\xE9.tex".b, "\\section{Café}\n")

      expect(paths.map(&:bytes)).to eq(["caf\xE9.tex".b.bytes])
    end

    # The candidate is judged by the part BELOW the root: a root whose own path
    # holds a `.git` component would otherwise skip every file under it.
    it "skips git's admin data by the path below the root, not by the root's own spelling" do
      inside_dot_git = File.join(root, ".git", "notes")
      FileUtils.mkdir_p(inside_dot_git)
      File.write(File.join(inside_dot_git, "a.md"), "# rooted under a .git component\n")

      walked = described_class.new(root: inside_dot_git, sensitivity:)

      expect(walked.files.map(&:path)).to eq(["a.md"])
    end
  end

  # A repository answers the ignore question itself. Re-implementing gitignore
  # in Ruby is what the crate-survey rule exists to prevent, so the walk asks
  # git -- one spawn -- and a non-repository root walks everything.
  describe "inside a git repository", :seam do
    # The subject's own scrub, for the subject's own reason: a suite run from a
    # pre-commit hook inherits GIT_INDEX_FILE and GIT_DIR aimed at lain's
    # repository, and an unscrubbed fixture would build against it.
    def git(*argv)
      shell = Lain::Shell::Out.new("git", "-C", root, *argv,
                                   environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
      shell.run_command
      raise "git #{argv.join(" ")} failed: #{shell.stderr}" unless shell.exitstatus.zero?

      shell.stdout
    end

    before do
      git("init", "--quiet")
      write(".gitignore", "tmp/\n*.log\n")
    end

    it "lists neither an ignored path nor its withholding, because ignored is not withheld" do
      write("tmp/junk.txt")
      write("debug.log")
      write("keep.rb")

      expect(paths).to include("keep.rb", ".gitignore")
      expect(paths).not_to include("tmp/junk.txt", "debug.log")
      expect(withheld_paths).to be_empty
    end

    it "lists a tracked file and an untracked one alike, because a survey reads the tree" do
      write("tracked.rb")
      git("add", "tracked.rb")
      write("untracked.rb")

      expect(paths).to include("tracked.rb", "untracked.rb")
    end

    it "never lists git's own admin data" do
      write("keep.rb")

      expect(paths.grep(%r{\A\.git/})).to be_empty
    end

    it "still withholds a denied path an ignore rule does not cover" do
      write(".ssh/id_ed25519", private_key)

      expect(withheld_paths).to eq([".ssh/id_ed25519"])
    end

    # The scrub and the bound are asserted here rather than merely passed: a
    # suite run from a pre-commit hook inherits GIT_INDEX_FILE and GIT_DIR
    # aimed at lain's own repository, and `-C` does NOT beat those. Dropping
    # the `environment:` survived the entire suite until this example held it.
    it "asks git exactly once, scrubbed and bounded, so an open is one spawn and not one per file" do
      write("a.rb")
      write("b.rb")
      spawned = []
      factory = lambda do |*argv, **options|
        spawned << [argv, options]
        Lain::Shell::Out.new(*argv, **options)
      end

      described_class.new(root:, sensitivity:, shell_out_factory: factory)

      expect(spawned.size).to eq(1)
      expect(spawned.first.last).to eq(environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB,
                                       timeout: described_class::GIT_TIMEOUT)
      expect(spawned.first.first.first(3)).to eq(["git", "-C", root])
    end

    # `ls-files` exits 0 with EMPTY output when the root is itself ignored, so
    # a survey of `<repo>/tmp/notes` silently listed nothing at all. git having
    # no answer and git answering "nothing" are the same thing here, and both
    # fall through to walking the directory the human actually named.
    it "walks a root that is itself ignored, rather than presenting an empty corpus" do
      write(".gitignore", "tmp/\n")
      write("tmp/notes/one.md", "# one\n")
      write("tmp/notes/two.md", "# two\n")

      walked = described_class.new(root: File.join(root, "tmp", "notes"), sensitivity:)

      expect(walked.files.map(&:path)).to eq(%w[one.md two.md])
      expect(walked.withheld).to be_empty
    end
  end

  describe "outside a git repository" do
    it "walks everything, which is what a directory of prose wants" do
      write("chapter.tex")
      write("build/chapter.aux")

      expect(paths).to eq(%w[build/chapter.aux chapter.tex])
    end

    it "falls back rather than refusing when git cannot answer" do
      write("a.rb")
      shell = instance_double(Lain::Shell::Out, run_command: nil, stdout: "", stderr: "fatal", exitstatus: 128)

      walked = described_class.new(root:, sensitivity:, shell_out_factory: ->(*, **) { shell })

      expect(walked.files.map(&:path)).to eq(["a.rb"])
    end

    it "falls back when git is not installed at all, rather than escaping as an Errno" do
      write("a.rb")
      absent = ->(*, **) { raise Errno::ENOENT, "git" }

      expect(described_class.new(root:, sensitivity:, shell_out_factory: absent).files.map(&:path)).to eq(["a.rb"])
    end
  end
end
