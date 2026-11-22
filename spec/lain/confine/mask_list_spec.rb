# frozen_string_literal: true

require "fileutils"
require "open3"
require "timeout"
require "tmpdir"

RSpec.describe Lain::Confine::MaskList, :seam do
  around do |example|
    Dir.mktmpdir("lain-mask-list") do |dir|
      @base = File.realpath(dir)
      @root = File.join(@base, "project")
      FileUtils.mkdir_p([File.join(@root, "config"), File.join(@base, "home")])
      example.run
    end
  end

  let(:root) { @root }
  let(:policy) do
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: File.join(@base, "home"), cwd: root))
  end
  let(:asked) { [] }
  let(:recorder) do
    Class.new(SimpleDelegator) do
      def initialize(policy, asked)
        super(policy)
        @asked = asked
      end

      def mask_paths(files, **) = @asked.push(files.to_a).then { super }
    end
  end
  let(:recording) { recorder.new(policy, asked) }
  let(:list) { described_class.new(root:, policy: -> { recording }) }
  let(:stat_at) { Struct.new(:mtime, :ctime, :ino, :dev, :dir) { def directory? = dir } }

  # Every directory's times read a minute back, so each change lands outside an ask's tick without a sleep.
  def aged(path)
    stat = described_class.const_get(:DIRECTORY_STAT).call(path)
    stat_at.new(stat.mtime - 60, stat.ctime - 60, stat.ino, stat.dev, stat.directory?)
  end

  def write(name, body = "x\n") = File.write(File.join(root, name), body)

  before { git("init", "-q") }

  it "answers the session's policy on a path outside the project, as its masks do inside it" do
    home = File.join(@base, "home")

    expect([list.classify(File.join(home, ".ssh", "id_ed25519")).level, list.classify(File.join(home, "notes")).level])
      .to eq(%i[denied ordinary])
  end

  def git(*args) = SeedRepo.git(root, *args)

  def paths = list.masks.map(&:path)

  describe "the paths a run tainted" do
    let(:taint) { Lain::Sensitivity::Taint.new }
    let(:secrets) { Struct.new(:known) { def for_reads(_context) = known }.new(["synthetic-leaf-4f9a2c"]) }
    let(:tainted) { described_class.new(root:, policy: -> { policy }, taint: -> { taint }, stat: method(:aged)) }

    def taint_now
      taint.scan(root:, since: Time.now - 60, refs: {}, secrets:)
    end

    it "masks a tainted file whose listing and inode did not change since the last ask" do
      write("app.log", "leaf=synthetic-leaf-4f9a2c\n")
      before = tainted.masks.map(&:path)
      taint_now

      expect(before).not_to include(File.join(root, "app.log"))
      expect(tainted.masks.map { [_1.path, _1.reason] }).to include([File.join(root, "app.log"), :tainted])
    end

    it "masks nothing more, and answers the same masks, while nothing is tainted" do
      write(".env", "A=1\n")
      first = tainted.masks

      expect(tainted.masks).to equal(first)
    end

    it "masks a tainted path whose name is not valid UTF-8 once, though the listing masks it too" do
      bad = File.join(root, "d\xff").b.force_encoding(Lain::FILESYSTEM)
      Dir.mkdir(bad)
      File.write(File.join(bad, "k"), "x")
      taint.hold_whole(File.join(bad, "k").b)

      masked = tainted.masks.map(&:path).select { _1.b.include?("d\xff".b) }

      expect(masked.map(&:b)).to eq([File.join(bad, "k").b])
    end

    it "drops a tainted file that is gone, since a mask needs a file to bind over" do
      write("app.log", "synthetic-leaf-4f9a2c")
      taint_now
      File.delete(File.join(root, "app.log"))

      expect(tainted.masks.map(&:path)).not_to include(File.join(root, "app.log"))
    end
  end

  # The listing runs before every call, outside the sandbox, over a tree the last call wrote.
  it "runs no fsmonitor the checkout's config names" do
    marker = File.join(@base, "fsmonitor-ran")
    git("config", "core.fsmonitor", "touch #{marker}; false")
    write(".env", "A=1\n")

    list.masks

    expect(File.exist?(marker)).to be(false)
  end

  it "masks an untracked secret at its resolved path" do
    write(".env", "A=1\n")
    write("README.md")

    expect(paths).to eq([File.join(root, ".env")])
  end

  it "masks gitignored secrets, which are the usual kind" do
    write(".gitignore", ".env\nconfig/master.key\n")
    write(".env")
    write("config/master.key")

    expect(paths).to contain_exactly(File.join(root, ".env"), File.join(root, "config", "master.key"))
  end

  it "does not look inside build and dependency directories" do
    FileUtils.mkdir_p(File.join(root, "node_modules", "pkg"))
    write(".gitignore", "node_modules/\n")
    File.write(File.join(root, "node_modules", "pkg", ".env"), "x\n")

    expect(paths).to be_empty
  end

  describe "a project whose listing does not answer" do
    let(:plain) { File.join(@base, "plain").tap { FileUtils.mkdir_p(File.join(_1, "config")) } }
    let(:plain_policy) do
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: File.join(@base, "home"), cwd: plain))
    end

    let(:gitless) do
      lambda do |*argv, **opts|
        Lain::Shell::Out.new(*(argv.first == "git" ? ["/nonexistent/git", *argv.drop(1)] : argv), **opts)
      end
    end

    def plant(dir)
      FileUtils.mkdir_p(File.join(dir, "config"))
      %w[.env config/master.key README.md].each { File.write(File.join(dir, _1), "x\n") }
    end

    it "masks the secrets of a directory that is not a repository" do
      plant(plain)

      masks = described_class.new(root: plain, policy: -> { plain_policy }).masks.map(&:path)

      expect(masks).to contain_exactly(File.join(plain, ".env"), File.join(plain, "config", "master.key"))
    end

    it "masks every path the policy gates when git is missing from PATH" do
      write(".gitignore", ".env\nconfig/master.key\n")
      plant(root)
      expected = paths

      masks = described_class.new(root:, policy: -> { policy }, shell_out: gitless).masks.map(&:path)

      expect([masks, expected]).to match([match_array(expected), include(File.join(root, ".env"))])
    end

    # git's own excludes skip them, so the walk standing in for git skips them too; the policy
    # drops a mask inside .git, so only the names it is asked about show the .git walk.
    it "walks neither the top-level .git nor a top-level .venv when git is missing from PATH" do
      %w[.git .venv].each { FileUtils.mkdir_p(File.join(root, _1)) }
      %w[.env .git/.env .venv/.env].each { write(_1) }

      masks = described_class.new(root:, policy: -> { recording }, shell_out: gitless).masks.map(&:path)

      expect([masks, asked.flatten.grep(/\A\.(git|venv)/)]).to eq([[File.join(root, ".env")], []])
    end

    it "keeps the masks it has when the walk cannot read the root either" do
      plant(plain)
      FileUtils.mkdir_p(File.join(plain, "deep", "a"))
      File.write(File.join(plain, "deep", "a", ".env"), "x\n")
      walked = described_class.new(root: plain, policy: -> { plain_policy })
      before = walked.masks.map(&:path)
      allow(Dir).to receive(:children).and_call_original
      allow(Dir).to receive(:children).with(plain).and_raise(Errno::EACCES)

      expect([walked.masks.map(&:path), before]).to match([before, include(File.join(plain, "deep", "a", ".env"))])
    end
  end

  it "masks a new secret from the next ask on" do
    write("README.md")
    expect(paths).to be_empty

    write(".env.local")

    expect(paths).to eq([File.join(root, ".env.local")])
  end

  it "does not classify again when the listing is unchanged" do
    write(".env")
    list.masks
    asked.clear

    list.masks

    expect(asked).to be_empty
  end

  it "classifies only the new name when the tree changes, and keeps the earlier masks" do
    write(".env")
    list.masks
    write("notes.txt")
    asked.clear

    expect(paths).to eq([File.join(root, ".env")])
    expect(asked).to eq([["notes.txt"]])
  end

  it "drops a mask whose file is gone" do
    write(".env")
    write(".env.local")
    list.masks
    FileUtils.rm(File.join(root, ".env"))

    expect(paths).to eq([File.join(root, ".env.local")])
  end

  it "masks the landing of a link, never the link" do
    write(".env")
    File.symlink(".env", File.join(root, "settings.txt"))

    expect(paths).to eq([File.join(root, ".env")])
  end

  it "carries the policy's exec rules with what a call may read beyond the project" do
    sensitivity = Lain::Sensitivity.new(home: File.join(@base, "home"), cwd: root)
    rooted = Lain::Sensitivity::Policy.new(sensitivity:, root:)
    list = described_class.new(root:, policy: -> { rooted })

    expect(list.related.execs).to eq(rooted.bounds.execs)
    expect([list.related.execs.exec?(File.join(root, "target/debug/x")), described_class::Related::NONE.execs])
      .to eq([true, Lain::Confine::ExecRules::NONE])
  end

  it "reads the policy only when first asked" do
    built = []
    lazy = described_class.new(root:, policy: -> { built.push(1).then { policy } })

    expect { lazy.masks }.to change { built.size }.from(0).to(1)
  end

  it "masks a tracked secret again when it is restored after a delete" do
    write(".env")
    git("add", ".env")
    expect(paths).to eq([File.join(root, ".env")])
    FileUtils.rm(File.join(root, ".env"))
    expect(paths).to be_empty

    write(".env")

    expect(paths).to eq([File.join(root, ".env")])
  end

  it "masks a secret at the top of a pruned directory and not below it" do
    FileUtils.mkdir_p(%w[tmp/deep vendor sub/node_modules/pkg].map { File.join(root, _1) })
    %w[tmp/.env vendor/.env sub/node_modules/.env].each { write(_1) }
    %w[tmp/deep/.env sub/node_modules/pkg/.env].each { write(_1) }

    expect(paths).to match_array(%w[tmp/.env vendor/.env sub/node_modules/.env].map { File.join(root, _1) })
  end

  it "masks nothing in an ignored Python environment at any depth, and still masks the root's .env and tmp/.env" do
    write(".gitignore", ".venv/\n__pycache__/\n")
    FileUtils.mkdir_p(%w[.venv/lib/x sub/venv/lib sub/__pycache__ tmp].map { File.join(root, _1) })
    %w[.venv/.env .venv/lib/x/.env sub/venv/.env sub/__pycache__/.env .env tmp/.env].each { write(_1) }
    listed = git("ls-files", "-z", "-co", "--", ".", *described_class::EXCLUDES).stdout.split("\0")

    expect([paths, listed.grep(/venv|__pycache__/)])
      .to eq([%w[.env tmp/.env].map { File.join(root, _1) }, []])
  end

  it "lists and masks neither .venv nor venv when they are links" do
    elsewhere = File.join(@base, "elsewhere").tap { FileUtils.mkdir_p(_1) }
    File.write(File.join(elsewhere, ".env"), "x\n")
    %w[.venv venv].each { File.symlink(elsewhere, File.join(root, _1)) }
    listed = git("ls-files", "-z", "-co", "--", ".", *described_class::EXCLUDES).stdout.split("\0")

    expect([paths, listed]).to eq([[], []])
  end

  it "masks what judge masks over this checkout's listing, the files in its submodules included" do
    checkout = File.expand_path("../../..", __dir__)
    home = File.join(@base, "home")
    judging = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: checkout, root: checkout),
                                            home:, root: checkout)
    listed = SeedRepo.git(checkout, "ls-files", "-z", "-co", "--", ".", *described_class::EXCLUDES).stdout.split("\0")
    beneath = listed.select { File.directory?(File.join(checkout, _1)) }.flat_map do |leaf|
      Dir.glob("**/*", File::FNM_DOTMATCH, base: File.join(checkout, leaf))
         .reject { _1.split(File::SEPARATOR).include?(".git") || File.directory?(File.join(checkout, leaf, _1)) }
         .map { File.join(leaf, _1) }
    end
    judged = (listed + beneath).filter_map do |name|
      verdict = judging.judge(name, cwd: checkout)
      Lain::Sensitivity::Policy.masks?(verdict) ? [File.realpath(name, checkout), verdict.reason] : nil
    end

    masks = described_class.new(root: checkout, policy: -> { judging }).masks

    expect(masks.map { [_1.path, _1.reason] }).to match_array(judged.uniq(&:first).select { File.exist?(_1.first) })
  end

  describe "a related directory" do
    let(:home) { File.join(@base, "home") }
    let(:sibling) { File.join(@base, "sibling").tap { FileUtils.mkdir_p(_1) } }
    let(:policy) { relating(sibling) }

    def relating(*related)
      rules = Lain::Sensitivity::Rules.new(related:)
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, rules:))
    end

    def secret(dir) = File.join(dir, ".env").tap { File.write(_1, "KEY=value\n") }

    def config_of(dir) = File.join(dir, ".git", "config")

    def related_after_masks(listing = list)
      listing.masks
      listing.related
    end

    it "names a related repository readable together with its masks, and keeps them apart from the project's" do
      SeedRepo.git(sibling, "init", "-q")
      File.write(File.join(sibling, "notes.md"), "x\n")
      hidden = secret(sibling)
      write(".env")

      related = related_after_masks

      expect([related.roots, related.masks.map(&:path)]).to eq([[sibling], [hidden, config_of(sibling)]])
      expect(paths).to eq([File.join(root, ".env")])
    end

    it "names no related directory readable before its masks are listed" do
      SeedRepo.git(sibling, "init", "-q")

      expect(list.related).to eq(described_class::Related::NONE)
    end

    it "walks a related directory that is not a repository, and names it readable with the masks the walk found" do
      hidden = secret(sibling)
      nested = secret(File.join(sibling, "hub").tap { FileUtils.mkdir_p(_1) })
      File.write(File.join(sibling, "hub", "config.json"), "{}\n")

      related = related_after_masks

      expect(related.roots).to eq([sibling])
      expect(related.masks.map(&:path)).to contain_exactly(hidden, nested)
    end

    it "masks each directory below a pruned one whole in a walked related directory" do
      FileUtils.mkdir_p(File.join(sibling, "tmp", "x"))
      File.write(File.join(sibling, "tmp", "x", "creds.txt"), "x\n")

      expect(related_after_masks.masks.map(&:path)).to eq([File.join(sibling, "tmp", "x")])
    end

    it "refuses a related directory whose walk runs past the bound, naming why, and never reads it unmasked" do
      secret(File.join(sibling, "hub").tap { FileUtils.mkdir_p(_1) })
      ticks = 0
      bounded = described_class.new(root:, policy: -> { policy }, walk_bound: 0, clock: -> { ticks += 1 })

      answers = Array.new(2) { related_after_masks(bounded) }

      expect(answers.map { [_1.roots, _1.masks] }).to eq([[[], []]] * 2)
      expect(answers.last.refused).to match(sibling => /walk .* longer than 0s/)
    end

    # Each answer is 1 value, so a refresh between 2 asks cannot grant a root without its masks.
    it "names a root that became listable between 2 refreshes only with the masks listed for it" do
      hidden = secret(sibling)
      list.masks
      SeedRepo.git(sibling, "init", "-q")
      list.masks

      related = list.related

      expect([related.roots, related.masks.map(&:path)]).to eq([[sibling], [hidden, config_of(sibling)]])
    end

    it "masks a tooling directory at the top of a walked related directory whole, which the walk skips" do
      %w[.venv/.env __pycache__/id_rsa].each do |name|
        File.join(sibling, name).tap { FileUtils.mkdir_p(File.dirname(_1)) }.then { File.write(_1, "x\n") }
      end

      expect(related_after_masks.masks.map(&:path))
        .to include(File.join(sibling, ".venv"), File.join(sibling, "__pycache__"))
    end

    it "masks each .git/config under a related root whole, its own and a nested repository's" do
      SeedRepo.git(sibling, "init", "-q")
      nested = File.join(sibling, "nested").tap { FileUtils.mkdir_p(_1) }
      SeedRepo.git(nested, "init", "-q")
      File.write(File.join(nested, "a.txt"), "x\n")

      expect(related_after_masks.masks.map(&:path))
        .to include(File.join(sibling, ".git", "config"), File.join(nested, ".git", "config"))
    end

    it "masks a nested repository's .git/config in a walked related directory" do
      nested = File.join(sibling, "nested").tap { FileUtils.mkdir_p(_1) }
      SeedRepo.git(nested, "init", "-q")

      expect(related_after_masks.masks.map(&:path)).to include(File.join(nested, ".git", "config"))
    end

    it "refuses a related directory whose walk raises, rather than reading it with no masks" do
      secret(sibling)
      raised = 0
      flaky = Class.new(SimpleDelegator) do
        define_method(:mask_paths) do |files, cwd:, **opts|
          raise Errno::ENOENT, "vanished" if cwd.to_s == sibling && (raised += 1) == 1

          __getobj__.mask_paths(files, cwd:, **opts)
        end
      end.new(policy)
      listing = described_class.new(root:, policy: -> { flaky })

      answers = Array.new(2) { related_after_masks(listing) }

      expect(answers.map(&:roots)).to eq([[], []])
      expect(answers.last.refused).to match(sibling => /walk failed/)
    end

    it "journals a refusal once, naming the directory and why" do
      secret(File.join(sibling, "hub").tap { FileUtils.mkdir_p(_1) })
      ticks = 0
      journal = []
      bounded = described_class.new(root:, policy: -> { policy }, walk_bound: 0, clock: -> { ticks += 1 }, journal:)

      2.times { related_after_masks(bounded) }

      expect(journal).to match([having_attributes(capability: :related_directory,
                                                  provider: /#{Regexp.escape(sibling)}: its walk took longer/o)])
    end

    def raising(error, at: sibling)
      Class.new(SimpleDelegator) do
        define_method(:mask_paths) do |files, cwd:, **opts|
          raise error if cwd.to_s == at

          __getobj__.mask_paths(files, cwd:, **opts)
        end
      end.new(policy)
    end

    it "names only the error's class in a refusal, so a message that is not UTF-8 breaks no record" do
      secret(sibling)
      journal = []
      listing = described_class.new(root:, policy: -> { raising(Errno::ENOENT.new("a\xFFb".b)) }, journal:)

      refused = related_after_masks(listing).refused
      line = Lain::Confine::Profile.reader(root:, home:, unread: refused).tier_line

      expect(refused).to eq(sibling => "its walk failed: Errno::ENOENT")
      expect([line.encoding, line.valid_encoding?]).to eq([Encoding::UTF_8, true])
      expect { [JSON.generate(journal.map(&:to_journal)), Lain::Canonical.dump({ "content" => line })] }
        .not_to raise_error
    end

    it "lets a task's timeout through rather than refusing the directory for it" do
      secret(sibling)
      listing = described_class.new(root:, policy: -> { raising(Async::TimeoutError.new("deadline")) })

      expect { listing.masks }.to raise_error(Async::TimeoutError)
    end

    it "keeps a nested repository's .git/config masked once an unrelated file joins the walked directory" do
      nested = File.join(sibling, "nested").tap { FileUtils.mkdir_p(_1) }
      SeedRepo.git(nested, "init", "-q")
      aging = described_class.new(root:, policy: -> { policy }, stat: method(:aged))
      related_after_masks(aging)
      File.write(File.join(sibling, "new.txt"), "n\n")

      expect(related_after_masks(aging).masks.map(&:path)).to include(config_of(nested))
    end

    it "keeps refusing a directory on a later ask, though that walk would have kept to the bound" do
      secret(File.join(sibling, "hub").tap { FileUtils.mkdir_p(_1) })
      now = 0
      first = true
      clock = lambda do
        now += first ? 100 : 0
        now
      end
      bounded = described_class.new(root:, policy: -> { policy }, walk_bound: 10, clock:)
      related_after_masks(bounded)
      first = false

      expect(related_after_masks(bounded)).to have_attributes(roots: [], refused: { sibling => /longer than 10s/ })
    end

    it "stops a walk at the bound before it classifies anything, reading few of its directories" do
      dirs = Array.new(40) { File.join(sibling, "d#{_1}").tap { |d| FileUtils.mkdir_p(d) } }
      dirs.each { File.write(File.join(_1, "f.txt"), "x\n") }
      read = []
      stat = lambda do |path|
        read << path
        described_class.const_get(:DIRECTORY_STAT).call(path)
      end
      ticks = 0
      bounded = described_class.new(root:, policy: -> { recording }, walk_bound: 5, clock: -> { ticks += 1 }, stat:)

      related = related_after_masks(bounded)

      expect(related.refused).to have_key(sibling)
      expect(asked.flatten.grep(/\Ad\d+/)).to be_empty
      expect(read.grep(%r{\A#{Regexp.escape(sibling)}/d}o).size).to be < 40
    end

    it "refuses a walk whose last slice of classifying runs past the bound" do
      File.write(File.join(sibling, "a.txt"), "x\n")
      now = 0
      slow = Class.new(SimpleDelegator) do
        define_method(:mask_paths) { |files, **opts| (now += 20) && __getobj__.mask_paths(files, **opts) }
      end.new(policy)
      bounded = described_class.new(root:, policy: -> { slow }, walk_bound: 10, clock: -> { now })

      expect(related_after_masks(bounded)).to have_attributes(roots: [], refused: { sibling => /longer than 10s/ })
    end

    # Classifying is the slow part of a walk, so the bound is asked between slices of it, not only after.
    it "refuses at the bound while it classifies, leaving the rest of the walk's names unclassified" do
      names = Array.new((described_class::CLASSIFY_SLICE * 2) + 1) { "f#{_1}.txt" }
      names.each { File.write(File.join(sibling, _1), "x\n") }
      now = 0
      slow = Class.new(SimpleDelegator) do
        define_method(:mask_paths) { |files, **opts| (now += 20) && __getobj__.mask_paths(files, **opts) }
      end.new(policy)
      bounded = described_class.new(root:, policy: -> { slow }, walk_bound: 10, clock: -> { now })

      related = related_after_masks(bounded)

      expect(related.refused).to match(sibling => /longer than 10s/)
      expect(now).to be < 60
    end

    it "walks a related directory once it stops being a repository, masking what it now holds" do
      SeedRepo.git(sibling, "init", "-q")
      expect(related_after_masks.roots).to eq([sibling])
      FileUtils.rm_rf(File.join(sibling, ".git"))
      hidden = secret(sibling)

      expect(related_after_masks).to have_attributes(roots: [sibling], masks: [having_attributes(path: hidden)])
    end

    it "unlists a related directory whose listing times out, and keeps the project's masks" do
      SeedRepo.git(sibling, "init", "-q")
      write(".env")
      failing = false
      shell_out = lambda do |*argv, **opts|
        sibling_call = argv.include?(sibling)
        failing && sibling_call ? raise(Lain::Shell::Out::Timeout) : Lain::Shell::Out.new(*argv, **opts)
      end
      flaky = described_class.new(root:, policy: -> { policy }, shell_out:)
      expect(related_after_masks(flaky).roots).to eq([sibling])

      failing = true

      expect(related_after_masks(flaky).roots).to eq([])
      expect(flaky.masks.map(&:path)).to eq([File.join(root, ".env")])
    end

    it "keeps a related repository readable when the project's own listing fails, since a walk masks the project" do
      SeedRepo.git(sibling, "init", "-q")
      hidden = secret(sibling)
      write(".env")
      failing = false
      shell_out = lambda do |*argv, **opts|
        failing && argv.include?(root) ? raise(Lain::Shell::Out::Timeout) : Lain::Shell::Out.new(*argv, **opts)
      end
      flaky = described_class.new(root:, policy: -> { policy }, shell_out:)
      expect(related_after_masks(flaky).roots).to eq([sibling])

      failing = true

      expect(related_after_masks(flaky).masks.map(&:path)).to eq([hidden, config_of(sibling)])
      expect(related_after_masks(flaky).roots).to eq([sibling])
      expect(flaky.masks.map(&:path)).to eq([File.join(root, ".env")])
    end

    it "masks each directory below a pruned one whole, since the listing does not look inside it" do
      SeedRepo.git(sibling, "init", "-q")
      FileUtils.mkdir_p(%w[tmp/x a/node_modules/p/q vendor].map { File.join(sibling, _1) })
      File.write(File.join(sibling, "tmp", "x", ".env"), "KEY=value\n")
      File.write(File.join(sibling, "a", "node_modules", "p", "q", "f"), "x\n")
      File.write(File.join(sibling, "vendor", "top.txt"), "x\n")

      masks = related_after_masks.masks

      expect(masks.map(&:path)).to contain_exactly(File.join(sibling, "tmp", "x"),
                                                   File.join(sibling, "a", "node_modules", "p"), config_of(sibling))
    end

    it "masks each directory below a pruned one inside a nested repository whole" do
      SeedRepo.git(sibling, "init", "-q")
      nested = File.join(sibling, "nested")
      FileUtils.mkdir_p(File.join(nested, "target", "x"))
      SeedRepo.git(nested, "init", "-q")
      File.write(File.join(nested, "target", "x", "creds.txt"), "x\n")

      expect(related_after_masks.masks.map(&:path))
        .to contain_exactly(File.join(nested, "target", "x"), config_of(sibling), config_of(nested))
    end

    it "keeps a nested repository's pruned directory masked whole on a later ask" do
      SeedRepo.git(sibling, "init", "-q")
      nested = File.join(sibling, "nested")
      FileUtils.mkdir_p(File.join(nested, "target", "x"))
      SeedRepo.git(nested, "init", "-q")
      File.write(File.join(nested, "target", "x", "creds.txt"), "x\n")
      aging = described_class.new(root:, policy: -> { policy }, stat: method(:aged))

      expect(Array.new(2) { related_after_masks(aging).masks.map(&:path).sort })
        .to eq([[File.join(nested, "target", "x"), config_of(sibling), config_of(nested)].sort] * 2)
    end

    it "masks no pruned directory of the project whole, whose gap is documented" do
      FileUtils.mkdir_p(File.join(root, "tmp", "x"))
      File.write(File.join(root, "tmp", "x", ".env"), "KEY=value\n")

      expect(paths).to be_empty
    end

    it "starts no git process for a related directory that is missing" do
      gone = File.join(@base, "gone")
      started = []
      shell_out = lambda do |*argv, **opts|
        started << argv
        Lain::Shell::Out.new(*argv, **opts)
      end
      list = described_class.new(root:, policy: -> { relating(gone) }, shell_out:)

      expect(related_after_masks(list).roots).to eq([])
      expect(started).to all(satisfy { !_1.include?(gone) })
      expect(started).not_to be_empty
    end

    it "names no related directory whose own path the policy would hide" do
      keys = File.join(home, ".ssh").tap { FileUtils.mkdir_p(_1) }
      SeedRepo.git(keys, "init", "-q")
      list = described_class.new(root:, policy: -> { relating(keys) })

      expect(related_after_masks(list).roots).to eq([])
    end

    it "stops naming a related directory once the policy no longer holds it" do
      SeedRepo.git(sibling, "init", "-q")
      current = policy
      changing = described_class.new(root:, policy: -> { current })
      changing.masks
      current = relating

      expect(related_after_masks(changing).roots).to eq([])
    end

    it "names the related files that landed on a mask, by their path" do
      SeedRepo.git(sibling, "init", "-q")
      hidden = secret(sibling)
      related_after_masks

      expect(list.landed_on(hidden)).to eq([hidden])
    end
  end

  describe "#prime" do
    it "leaves masks answering what an unprimed list answers" do
      write(".env")
      other = described_class.new(root:, policy: -> { policy })

      list.prime

      expect(list.masks).to eq(other.masks)
    end

    it "surfaces a failure in the background classification at masks", :primes do
      calls = 0
      started = Queue.new
      broken = described_class.new(root:, policy: lambda {
        (calls += 1) == 1 ? raise(started.push(1) && "no policy yet") : policy
      })

      broken.prime
      started.pop

      expect { broken.masks }.to raise_error(RuntimeError, "no policy yet")
    end
  end

  # {Sensitivity::Policy#judge} is the oracle for what a refresh masks.
  describe "a refresh over links and plain files" do
    let(:home) { File.join(@base, "home") }
    let!(:policy) do
      real_home = File.join(@base, "realhome")
      FileUtils.mkdir_p(%w[.ssh .aws .kube tokens].map { File.join(real_home, _1) })
      File.write(File.join(real_home, ".ssh", "id_rsa"), "key\n")
      File.write(File.join(real_home, ".kube", "config"), "token: x\n")
      File.write(File.join(real_home, "tokens", "tokens.txt"), "t\n")
      FileUtils.rm_rf(File.join(@base, "home"))
      File.symlink(real_home, File.join(@base, "home"))
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:)
    end

    def plant
      stale_tracked_under_a_link
      CredentialLinks.plant(root, home:)
      write(".env", "A=1\n")
      write("README.md")
    end

    def stale_tracked_under_a_link
      %w[linkdir/id_rsa kubedir/config].each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(root, name)))
        write(name)
        git("add", name)
      end
      FileUtils.rm_r(%w[linkdir kubedir].map { File.join(root, _1) })
    end

    def plain_files
      Array.new(200) { |i| "d#{i % 10}/f#{i}.txt" }.each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(root, name)))
        write(name)
      end
    end

    def judged(names)
      masks = names.filter_map do |name|
        verdict = policy.judge(name, cwd: root)
        Lain::Sensitivity::Policy.masks?(verdict) ? [File.realpath(name, root), verdict.reason] : nil
      rescue SystemCallError
        nil
      end
      masks.uniq(&:first).select { File.exist?(_1.first) }
    end

    it "masks what judge masks, name by name" do
      plant
      git("add", *plain_files.first(100))
      listed = git("ls-files", "-z", "-co").stdout.split("\0").uniq

      expect(listed).to include("linkdir/id_rsa", "kubedir/config", "linkdir", "d0/f0.txt", "d9/f199.txt")
      expect(judged(listed).map(&:first))
        .to include(File.join(root, ".env"), File.join(@base, "realhome", ".ssh", "id_rsa"))
      expect(list.masks.map { [_1.path, _1.reason] }).to match_array(judged(listed))
    end

    # The bounds show as names left out: a pruned directory's depths, and what a link out of the root holds.
    it "masks what judge masks beneath a nested repo and a linked directory, name by name" do
      FileUtils.mkdir_p(%w[.aws/node_modules/pkg keys].map { File.join(root, _1) } << File.join(@base, "outside"))
      %w[.aws/credentials .aws/notes.txt .aws/node_modules/.env .aws/node_modules/pkg/.env keys/notes.txt keys/config]
        .each { write(_1) }
      File.write(File.join(@base, "outside", ".env"), "x\n")
      File.symlink(File.join(@base, "outside"), File.join(root, ".aws", "out"))
      File.symlink("keys", File.join(root, ".ssh"))
      git("init", "-q", ".aws")
      listed = git("ls-files", "-z", "-co").stdout.split("\0")
      beneath = %w[.aws/credentials .aws/notes.txt .aws/node_modules/.env .aws/out .ssh/notes.txt .ssh/config]

      expect(listed).to include(".aws/", ".ssh", "keys/config")
      expect(judged(beneath).map(&:first)).to include(File.join(root, ".aws", "credentials"),
                                                      File.join(root, "keys", "config"))
      expect(list.masks.map { [_1.path, _1.reason] }).to match_array(judged(listed + beneath))
    end

    def nested_repo(name)
      FileUtils.mkdir_p(File.join(root, name))
      git("init", "-q", name)
    end

    def asked_names = asked.flatten

    it "masks what judge masks through a sensitive-named link met inside a nested repo" do
      FileUtils.mkdir_p(File.join(root, "nest", "keys"))
      %w[nest/keys/config nest/keys/id_work nest/keys/notes.txt].each { write(_1) }
      File.symlink("keys", File.join(root, "nest", ".ssh"))
      nested_repo("nest")
      beneath = %w[nest/keys/config nest/keys/id_work nest/keys/notes.txt nest/.ssh nest/.ssh/config
                   nest/.ssh/id_work nest/.ssh/notes.txt]

      expect(judged(beneath).map(&:first)).to include(File.join(root, "nest", "keys", "config"))
      expect(list.masks.map { [_1.path, _1.reason] }).to match_array(judged(["nest/", *beneath]))
    end

    it "keeps a pruned directory pruned when a link reaches it" do
      FileUtils.mkdir_p(File.join(root, "node_modules", "pkg"))
      %w[node_modules/.env node_modules/pkg/.env].each { write(_1) }
      File.symlink("node_modules", File.join(root, ".ssh"))

      expect(paths).to eq([File.join(root, "node_modules", ".env")])
      expect(asked_names).to include(".ssh/.env")
      expect(asked_names).not_to include(".ssh/pkg/.env")
    end

    # Through a link no rule's directory name spells, a name judges as its landing's own does.
    it "does not walk a link whose spelling adds no directory name a rule matches" do
      FileUtils.mkdir_p(File.join(root, "keys"))
      write("keys/config")
      %w[lnk lnk2].each { File.symlink("keys", File.join(root, _1)) }

      list.masks

      expect(asked_names).to include("lnk", "lnk2", "keys/config")
      expect(asked_names.grep(%r{\Alnk2?/})).to be_empty
    end

    it "walks a link onto its own ancestor once, as deep as judge reads it" do
      FileUtils.rm_r(File.join(root, "config"))
      FileUtils.mkdir_p(File.join(root, "sub"))
      %w[config sub/config].each { write(_1) }
      File.symlink(".", File.join(root, ".ssh"))

      expect(policy.judge(".ssh/sub/config", cwd: root)).to be_gated
      expect(paths).to contain_exactly(File.join(root, "config"), File.join(root, "sub", "config"))
      expect(asked_names.grep(%r{\A\.ssh/\.ssh/})).to be_empty
    end

    it "asks about nothing inside a .git directory, nor below a pruned directory's top in a nested repo" do
      FileUtils.mkdir_p(%w[.aws/keys .aws/node_modules tmp/inner].map { File.join(root, _1) })
      %w[.aws/credentials .aws/keys/config tmp/inner/.env].each { write(_1) }
      File.symlink("../keys", File.join(root, ".aws", "node_modules", ".ssh"))
      nested_repo(".aws")
      nested_repo("tmp/inner")

      list.masks

      expect(asked_names).to include(".aws/credentials", ".aws/node_modules/.ssh")
      expect(asked_names.select { _1.split(File::SEPARATOR).include?(".git") }).to be_empty
      expect(asked_names.grep(%r{\A(tmp/inner/|\.aws/node_modules/\.ssh/)})).to be_empty
    end

    it "walks a nested repo deeper than a fiber's stack" do
      deep = File.join("nest", Array.new(1000, "d"))
      FileUtils.mkdir_p(File.join(root, deep))
      write(File.join(deep, ".env"))
      nested_repo("nest")

      expect(Fiber.new { paths }.resume).to eq([File.join(root, deep, ".env")])
    end

    it "walks a nested repo whose name and files are not ASCII" do
      FileUtils.mkdir_p(File.join(root, "café"))
      %w[café/.env café/résumé.md].each { write(_1) }
      nested_repo("café")

      expect(paths.map(&:b)).to eq([File.join(root, "café", ".env").b])
    end

    # No loop, but every simple path through the links is a way down.
    def link_graph(size)
      dirs = Array.new(size) { "d#{_1}" }
      dirs.each { FileUtils.mkdir_p(File.join(root, "nest#{size}", _1)) && write("nest#{size}/#{_1}/f") }
      dirs.product(dirs).reject { |from, to| from == to }
          .each { |from, to| File.symlink("../#{to}", File.join(root, "nest#{size}", from, "to_#{to}")) }
      nested_repo("nest#{size}")
    end

    it "walks N directories each linked to every other in about N squared names" do
      [5, 6, 7].each { link_graph(_1) }

      Timeout.timeout(10) { list.masks }

      [5, 6, 7].each { |n| expect(asked_names.count { _1.start_with?("nest#{n}/") }).to be <= (n + 1)**2 }
    end

    it "walks the same graph once more under a link named .ssh into it" do
      link_graph(7)
      File.symlink("nest7/d0", File.join(root, ".ssh"))

      Timeout.timeout(10) { list.masks }

      expect(asked_names.count { _1.start_with?(".ssh/") }).to be <= 2 * (8**2)
    end

    it "masks what judge gates beneath a link inside a nested repo that lands on the repo itself" do
      FileUtils.mkdir_p(File.join(root, "nest", "sub"))
      %w[nest/config nest/sub/notes.txt].each { write(_1) }
      File.symlink(".", File.join(root, "nest", ".ssh"))
      nested_repo("nest")

      expect(policy.judge("nest/.ssh/config", cwd: root)).to be_gated
      expect(paths).to eq([File.join(root, "nest", "config")])
    end

    it "does not walk a link inside a nested repo out of the root" do
      File.symlink("/etc", File.join(root, "nest", ".ssh").tap { FileUtils.mkdir_p(File.dirname(_1)) })
      nested_repo("nest")

      list.masks

      expect(asked_names).to include("nest/.ssh")
      expect(asked_names.grep(%r{\Anest/\.ssh/})).to be_empty
    end

    it "does not walk a link onto a pruned directory's depths" do
      FileUtils.mkdir_p(File.join(root, "node_modules", "pkg"))
      write("node_modules/pkg/.env")
      File.symlink("node_modules/pkg", File.join(root, ".ssh"))

      expect(paths).to be_empty
      expect(asked_names).not_to include(".ssh/.env")
    end

    # Each link lands on a directory inside the root, so only the spelling through .ssh makes config gated.
    it "masks what judge gates through a sensitive link 3 crossings above the file" do
      FileUtils.mkdir_p(%w[a b c].map { File.join(root, "nest", _1) })
      write("nest/c/config")
      { "nest/.ssh" => "a", "nest/a/l1" => "../b", "nest/b/l2" => "../c" }
        .each { |name, target| File.symlink(target, File.join(root, name)) }
      nested_repo("nest")

      expect(policy.judge("nest/.ssh/l1/l2/config", cwd: root)).to be_gated
      expect(paths).to eq([File.join(root, "nest", "c", "config")])
    end

    it "masks a .env file 3 crossings beneath a nested repo" do
      FileUtils.mkdir_p(%w[a b c].map { File.join(root, "nest", _1) })
      write("nest/c/.env")
      { "nest/l0" => "a", "nest/a/l1" => "../b", "nest/b/l2" => "../c" }
        .each { |name, target| File.symlink(target, File.join(root, name)) }
      nested_repo("nest")

      expect(paths).to eq([File.join(root, "nest", "c", ".env")])
    end

    within = %w[.ssh .aws .gnupg .password-store .gem .cargo .terraform.d keyrings proc]

    it "walks a directory linked to itself under every rule's directory name once per name, not per set" do
      FileUtils.mkdir_p(File.join(root, "d0"))
      10.times { write("d0/f#{_1}") }
      within.each { File.symlink(".", File.join(root, "d0", _1)) }

      Timeout.timeout(10) { list.masks }

      expect(asked_names.count { _1.start_with?("d0/") }).to be <= (within.size + 1) * (within.size + 10)
    end

    # A name rule reads every directory name below the root, and an anchored rule reads a path's prefix.
    {
      "a link whose own name a name rule reads" => [{ "auth.md" => "plain" }, "plain/creds.json", "auth.md/creds.json"],
      "a link inside a nested repo whose name a name rule reads" =>
        [{ "nest/private.md" => "inner" }, "nest/inner/prod.yml", "nest/private.md/prod.yml"],
      "a link into the project's own Ruby directory" =>
        [{ ".lain/services" => "../x" }, "x/hook.rb", ".lain/services/hook.rb"]
    }.each do |shape, (links, real, spelled)|
      it "masks what judge gates through #{shape}" do
        FileUtils.mkdir_p(File.dirname(File.join(root, real)))
        write(real)
        links.each do |name, target|
          FileUtils.mkdir_p(File.dirname(File.join(root, name)))
          File.symlink(target, File.join(root, name))
        end
        nested_repo("nest") if real.start_with?("nest/")

        expect(policy.judge(spelled, cwd: root)).to be_gated
        expect(policy.judge(real, cwd: root)).to be_ordinary
        expect(paths).to eq([File.join(root, real)])
      end
    end

    it "walks a link named .git inside a nested repo, which judge reads by its name" do
      FileUtils.mkdir_p(%w[nest/sub nest/keys].map { File.join(root, _1) })
      write("nest/keys/config")
      nested_repo("nest")
      File.symlink("../keys", File.join(root, "nest", "sub", ".git"))

      expect(policy.judge("nest/sub/.git/config", cwd: root)).to be_gated
      expect(paths).to eq([File.join(root, "nest", "keys", "config")])
    end

    it "walks a link named .ssh under a project root whose path is not ASCII" do
      cafe = File.join(@base, "café")
      FileUtils.mkdir_p(File.join(cafe, "keys"))
      File.write(File.join(cafe, "keys", "config"), "x\n")
      File.symlink("keys", File.join(cafe, ".ssh"))
      SeedRepo.git(cafe, "init", "-q")
      judging = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: cafe, root: cafe),
                                              home:, root: cafe)

      masks = described_class.new(root: cafe, policy: -> { judging }).masks

      expect(judging.judge(".ssh/config", cwd: cafe)).to be_gated
      expect(masks.map(&:path)).to eq([File.join(cafe, "keys", "config")])
    end

    # The exemption marks only the landing, and the link's own name judges ordinary.
    it "masks what judge gates through a link onto a directory an exemption reaches into" do
      FileUtils.mkdir_p(File.join(root, "vault", "a"))
      write("vault/a/server.key")
      File.symlink("a", File.join(root, "vault", "l"))
      rules = Lain::Sensitivity::Rules.from({ "exempt" => ["/vault/a/server.key"] })
      judging = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:, rules:),
                                              home:, root:)

      masks = described_class.new(root:, policy: -> { judging }).masks

      expect(judging.judge("vault/l/server.key", cwd: root)).to be_gated
      expect(judging.judge("vault/l", cwd: root)).to be_ordinary
      expect(masks.map(&:path)).to eq([File.join(root, "vault", "a", "server.key")])
    end

    # Neither name can be read as text, so neither side's marks can be trusted to match.
    it "walks a link whose spelling and landing both have names the rules cannot read" do
      FileUtils.mkdir_p(File.join(root.b, "\xFEk".b))
      File.write(File.join(root.b, "\xFEk".b, "notes"), "x\n")
      File.symlink("\xFEk".b, File.join(root.b, "\xFFl".b))

      list.masks

      expect(asked_names.map(&:b)).to include("\xFFl/notes".b)
    end

    def swap_for_link(name, target)
      FileUtils.rm(File.join(root, name))
      File.symlink(target, File.join(root, name))
    end

    it "masks a listed file on the next refresh once it is swapped for a link to a secret" do
      write("plain.txt")
      expect(paths).to be_empty

      swap_for_link("plain.txt", File.join(home, ".ssh", "id_rsa"))

      expect(list.masks.map { [_1.path, _1.reason] }).to eq(judged(["plain.txt"]))
      expect(paths).to eq([File.join(@base, "realhome", ".ssh", "id_rsa")])
    end

    it "unmasks a listed link once it is swapped back for a plain file" do
      File.symlink(File.join(home, ".ssh", "id_rsa"), File.join(root, "plain.txt"))
      expect(paths).to eq([File.join(@base, "realhome", ".ssh", "id_rsa")])

      FileUtils.rm(File.join(root, "plain.txt"))
      write("plain.txt")

      expect(paths).to be_empty
    end

    it "judges no name again when 200 listed files are unchanged" do
      plain_files
      list.masks
      asked.clear

      list.masks

      expect(asked).to be_empty
    end

    def secret = File.join(@base, "realhome", ".ssh", "id_rsa")

    def notes = File.join(@base, "realhome", "notes.txt").tap { File.write(_1, "n\n") }

    it "masks a listed link retargeted at a secret by a delete and a new link" do
      File.symlink(notes, File.join(root, "lnk"))
      expect(paths).to be_empty

      swap_for_link("lnk", File.join(home, ".ssh", "id_rsa"))

      expect(paths).to eq([secret])
    end

    it "masks a listed link retargeted at a secret in place" do
      File.symlink(notes, File.join(root, "lnk"))
      expect(paths).to be_empty

      system("ln", "-sfn", File.join(home, ".ssh", "id_rsa"), File.join(root, "lnk"), exception: true)

      expect(paths).to eq([secret])
    end

    it "unmasks a listed link whose target outside the tree is deleted" do
      File.symlink(File.join(home, "tokens", "tokens.txt"), File.join(root, "k"))
      expect(paths).to eq([File.join(@base, "realhome", "tokens", "tokens.txt")])

      FileUtils.rm(File.join(home, "tokens", "tokens.txt"))

      expect(paths).to be_empty
    end

    it "unmasks a secret link moved out of the tree while its landing remains" do
      File.symlink(File.join(home, ".ssh", "id_rsa"), File.join(root, "k"))
      expect(paths).to eq([secret])

      File.rename(File.join(root, "k"), File.join(@base, "k"))

      expect(paths).to be_empty
    end

    it "masks a tracked name at its new landing once its directory is swapped for a link" do
      FileUtils.mkdir_p(File.join(root, "d"))
      write("d/id_rsa")
      git("add", "d/id_rsa")
      expect(paths).to eq([File.join(root, "d", "id_rsa")])

      FileUtils.rm_r(File.join(root, "d"))
      File.symlink(File.join(home, ".ssh"), File.join(root, "d"))

      expect(paths).to include(secret)
    end

    it "keeps the masks it has when a listing fails" do
      failing = false
      shell_out = lambda do |*argv, **opts|
        failing ? Lain::Shell::Out.new("false", **opts.slice(:chdir, :timeout)) : Lain::Shell::Out.new(*argv, **opts)
      end
      flaky = described_class.new(root:, policy: -> { policy }, shell_out:)
      File.symlink(File.join(home, ".ssh", "id_rsa"), File.join(root, "k"))
      expect(flaky.masks.map(&:path)).to eq([secret])

      failing = true

      expect(flaky.masks.map(&:path)).to eq([secret])
    end

    describe "an ask that finds the same listing under the same policy" do
      let(:aged_list) { described_class.new(root:, policy: -> { recording }, stat: method(:aged)) }

      it "answers the last masks without classifying a name again" do
        FileUtils.mkdir_p(File.join(root, "build"))
        write(".env")
        write("build/out.txt")
        first = aged_list.masks
        asked.clear

        expect([aged_list.masks, asked]).to eq([first, []])
        expect(aged_list.masks).to equal(first)
      end

      it "classifies every name again once the policy is another" do
        write(".env")
        write("README.md")
        policy_now = recording
        reloaded = recorder.new(policy, asked)
        swapping = described_class.new(root:, policy: -> { policy_now }, stat: method(:aged))
        swapping.masks
        asked.clear

        policy_now = reloaded
        swapping.masks

        expect(asked.flatten).to contain_exactly(".env", "README.md")
      end

      it "masks a file swapped for a link to a secret" do
        write("config/app.yml")
        expect(aged_list.masks).to be_empty

        swap_for_link("config/app.yml", File.join(home, ".ssh", "id_rsa"))

        expect(aged_list.masks.map(&:path)).to eq([secret])
      end

      it "drops a mask whose target outside the root was deleted, with the listing and its directories unchanged" do
        File.symlink(File.join(home, ".ssh", "id_rsa"), File.join(root, "lnk"))
        expect(aged_list.masks.map(&:path)).to eq([secret])

        FileUtils.rm(secret)

        expect(aged_list.masks).to be_empty
      end

      it "masks an ignored file created after the last ask" do
        write(".gitignore", "build/\n")
        FileUtils.mkdir_p(File.join(root, "build"))
        write("build/out.txt")
        expect(aged_list.masks).to be_empty

        write("build/.env")

        expect(aged_list.masks.map(&:path)).to eq([File.join(root, "build", ".env")])
      end
    end

    describe "a later ask over directories changed more than a tick before the last one" do
      let(:list) { described_class.new(root:, policy: -> { recording }, stat: method(:aged)) }

      def nested_tree
        FileUtils.mkdir_p(%w[d nest/sub].map { File.join(root, _1) })
        %w[a.txt d/b.txt nest/c.txt nest/sub/e.txt nest/sub/.env].each { write(_1) }
        File.symlink("a.txt", File.join(root, "lnk"))
        nested_repo("nest")
      end

      def lstatted_by_next_ask
        lstatted = []
        allow(File).to(receive(:lstat).and_wrap_original { |original, path| original.call(lstatted.push(path.b).last) })
        [paths, lstatted]
      end

      it "masks a new secret in an existing directory and beneath a nested repo" do
        nested_tree
        expect(paths).to eq([File.join(root, "nest", "sub", ".env")])

        %w[d/.env nest/.env].each { write(_1) }

        expect(paths).to match_array(%w[d/.env nest/.env nest/sub/.env].map { File.join(root, _1) })
      end

      it "lstats no plain listed name and walks no nested repo again when nothing changed" do
        nested_tree
        masked = paths
        unchanged = %w[a.txt d/b.txt nest/c.txt nest/sub/e.txt nest/sub/.env].map { File.join(root, _1).b }

        again, lstatted = lstatted_by_next_ask

        expect([again, lstatted & unchanged]).to eq([masked, []])
        expect(lstatted).to include(File.join(root, "lnk").b)
      end

      it "masks a listed link's new landing once a link it chains through is retargeted outside the checkout" do
        out = File.join(@base, "out").tap { FileUtils.mkdir_p(_1) }
        File.symlink(notes, File.join(out, "hop"))
        File.symlink("../out/hop", File.join(root, "link"))
        expect(paths).to be_empty

        expect { system("ln", "-sfn", File.join(home, ".ssh", "id_rsa"), File.join(out, "hop"), exception: true) }
          .not_to(change { File.lstat(root).mtime })

        expect(paths).to eq([secret])
      end

      it "masks a masked file's new landing once it is swapped for a link out of the checkout" do
        FileUtils.mkdir_p(File.join(root, "d"))
        write("d/.env")
        expect(paths).to eq([File.join(root, "d", ".env")])

        swap_for_link("d/.env", File.join(home, ".ssh", "id_rsa"))

        expect(paths).to eq([secret])
      end

      it "masks a nested repo link's new landing once a link it chains through is retargeted outside the checkout" do
        out = File.join(@base, "out").tap { FileUtils.mkdir_p(_1) }
        File.symlink(notes, File.join(out, "hop"))
        FileUtils.mkdir_p(File.join(root, "nest"))
        File.symlink("../../out/hop", File.join(root, "nest", "l0"))
        nested_repo("nest")
        expect(paths).to be_empty

        system("ln", "-sfn", File.join(home, ".ssh", "id_rsa"), File.join(out, "hop"), exception: true)

        expect(paths).to eq([secret])
      end

      it "masks a secret planted beneath a nested repo whose directory's mtime is set back" do
        nested_tree
        nest = File.join(root, "nest")
        expect(paths).to eq([File.join(nest, "sub", ".env")])
        before = File.stat(nest)

        write("nest/.env")
        File.utime(before.atime, before.mtime, nest)

        expect(paths).to contain_exactly(File.join(nest, ".env"), File.join(nest, "sub", ".env"))
      end

      it "lstats no tracked name under a directory swapped for a link when nothing changed" do
        FileUtils.mkdir_p(%w[d real].map { File.join(root, _1) })
        %w[d/a.txt real/a.txt].each { write(_1) }
        git("add", "d/a.txt")
        FileUtils.rm_r(File.join(root, "d"))
        File.symlink("real", File.join(root, "d"))
        masked = paths

        again, lstatted = lstatted_by_next_ask

        expect([again, lstatted & [File.join(root, "d", "a.txt").b]]).to eq([masked, []])
      end

      it "masks what a listed link's new landing holds once it is retargeted onto another directory in the root" do
        FileUtils.mkdir_p(%w[keys keys2].map { File.join(root, _1) })
        %w[keys/notes.txt keys2/config].each { write(_1) }
        File.symlink("keys", File.join(root, ".ssh"))
        expect(paths).to be_empty

        system("ln", "-sfn", "keys2", File.join(root, ".ssh"), exception: true)

        expect(paths).to eq([File.join(root, "keys2", "config")])
      end

      # The link onto its own repo cedes its second crossing to the walk it is already in.
      it "walks no nested repo again when nothing changed and a link inside lands on the repo itself" do
        FileUtils.mkdir_p(File.join(root, "nest"))
        write("nest/config")
        File.symlink(".", File.join(root, "nest", ".ssh"))
        nested_repo("nest")
        masked = paths

        again, lstatted = lstatted_by_next_ask

        expect([again, lstatted & [File.join(root, "nest", "config").b]]).to eq([masked, []])
      end

      it "masks a new secret 2 levels beneath a nested repo" do
        FileUtils.mkdir_p(File.join(root, "nest", "sub", "deep"))
        write("nest/sub/deep/a.txt")
        nested_repo("nest")
        expect(paths).to be_empty

        write("nest/sub/deep/.env")

        expect(paths).to eq([File.join(root, "nest", "sub", "deep", ".env")])
      end

      # The root's .ssh lists before nest/, so it takes the walk into keys that nest/.ssh then cedes.
      def shared_walk(root_link: true)
        FileUtils.mkdir_p(%w[keys nest].map { File.join(root, _1) })
        write("keys/config")
        File.symlink("keys", File.join(root, ".ssh")) if root_link
        File.symlink("../keys", File.join(root, "nest", ".ssh"))
        nested_repo("nest")
      end

      def keys_config = File.join(root, "keys", "config")

      def fresh_landed_on(path) = described_class.new(root:, policy: -> { policy }).tap(&:masks).landed_on(path)

      it "masks through a nested repo's link once the root link that took the same walk is gone" do
        shared_walk
        expect(paths).to eq([keys_config])

        File.unlink(File.join(root, ".ssh"))
        write("keys/config.new")
        File.rename(File.join(root, "keys", "config.new"), keys_config)

        expect(policy.judge("nest/.ssh/config", cwd: root)).to be_gated
        expect(paths).to eq([keys_config])
      end

      it "names a mask's files as a fresh list does once an earlier link takes a nested repo link's walk" do
        shared_walk(root_link: false)
        expect(list.tap(&:masks).landed_on(keys_config)).to include("nest/.ssh/config")

        File.symlink("keys", File.join(root, ".ssh"))
        list.masks

        expect(list.landed_on(keys_config)).to match_array(fresh_landed_on(keys_config))
      end

      it "names a mask's files as a fresh list does after an unchanged ask over 2 links sharing a walk" do
        shared_walk

        2.times { list.masks }

        expect(list.landed_on(keys_config)).to match_array(fresh_landed_on(keys_config))
      end

      # Replaying the root's first stamp stands for a coarse clock: the rename then moves neither of its times.
      {
        "both its times fall 3 ms before the ask, inside the 10 ms tick" => ->(now) { [now - 0.003] * 2 },
        "only its ctime falls inside the tick" => ->(now) { [now - 60, now - 0.003] },
        "its whole-second times fall 1 s before the ask, in the 2 s tick" => ->(now) { [Time.at((now - 1).to_i)] * 2 }
      }.each do |which, times|
        it "masks a name renamed over when #{which}" do
          write("plain.txt")
          frozen = nil
          stat = lambda do |path|
            real = File.stat(path)
            replay = -> { stat_at.new(*times.call(Time.now), real.ino, real.dev, true) }
            File.identical?(path, root) ? (frozen ||= replay.call) : real
          end
          coarse = described_class.new(root:, policy: -> { policy }, stat:)
          expect(coarse.masks).to be_empty

          File.symlink(File.join(home, ".ssh", "id_rsa"), File.join(root, "swap"))
          File.rename(File.join(root, "swap"), File.join(root, "plain.txt"))

          expect(coarse.masks.map(&:path)).to eq([secret])
        end
      end
    end
  end

  describe "a workspace call over a project that is not a git repository" do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
      skip("bwrap cannot make a user namespace on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
    end

    # Under $HOME, as the workspace profile refuses a TMPDIR that holds home.
    around do |example|
      Dir.mktmpdir("lain-unlisted", Dir.tmpdir.start_with?("#{Dir.home}/") ? Dir.tmpdir : Dir.home) do |dir|
        @plain = File.realpath(dir)
        FileUtils.mkdir_p([File.join(@plain, "p", "config"), File.join(@plain, "t")])
        example.run
      end
    end

    def project = File.join(@plain, "p")

    def listed_masks
      plain_policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: Dir.home, cwd: project))
      described_class.new(root: project, policy: -> { plain_policy }).masks.map(&:path)
    end

    def confined(*argv)
      masks = listed_masks
      profile = Lain::Confine::Profile.workspace(root: project, home: Dir.home, tmpdir: File.join(@plain, "t"), masks:)
      launcher = Lain::Confine::Bwrap.new(fence:)
      bound = launcher.masked(profile).bind(stages: 1, first_fd: 4)
      run(launcher.wrap(Lain::Shell::Term.of(argv), profile, trace_fd: 3, bound:).stages.first.argv, bound.fds)
    ensure
      bound&.close
    end

    def run(argv, fds)
      reader, writer = IO.pipe
      out, err, status = Open3.capture3({ "LC_ALL" => "C" }, *argv, chdir: project, 3 => writer, **fds)
      [out, err, status.success?]
    ensure
      writer&.close
      reader&.close
    end

    it "shows the child .env as an empty file, and lets it read an ordinary file" do
      File.write(File.join(project, ".env"), "SECRET=1\n")
      File.write(File.join(project, "config", "master.key"), "KEY\n")
      File.write(File.join(project, "README.md"), "the readme\n")

      expect([confined("cat", ".env"), confined("cat", "README.md")])
        .to eq([["", "", true], ["the readme\n", "", true]])
    end
  end

  describe "a Rust project's package caches, on the session's own policy" do
    let(:home) { File.join(@base, "home") }
    let(:paths) { Lain::Paths.new(env: { "HOME" => home, "XDG_STATE_HOME" => File.join(@base, "state") }) }
    let(:registry_src) { File.join(home, ".cargo/registry/src") }
    let(:session) do
      project = Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag)
      Lain::CLI::Wiring::BoardBuild.session_policy(
        project:, paths:, table: Lain::CLI::Wiring::BoardBuild.rules(project:, paths:),
        config: Lain::Config.load(root:, paths:)
      )
    end
    let(:cached) { described_class.new(root:, policy: -> { session }) }
    let(:journal) { [] }
    let(:probe) do
      fence = "#{JSON.generate({ abi: 6, rights: {}, skipped: [], private_net: false })}\n"
      answers = { "bwrap" => ["", true], "lain-fence" => [fence, true], "strace" => ["strace 6.1", true] }
      Lain::Confine::Probe.new(fence: "/x/lain-fence", journal:, ptrace_scope: -> { "1\n" },
                               runner: ->(argv) { answers.fetch(File.basename(argv.first)) })
    end
    let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }

    before do
      write("Cargo.toml", "[package]\nname = \"x\"\n")
      crate = File.join(registry_src, "index.crates.io-1949cf8c6b5b557f/whisper-rs-0.16.0")
      FileUtils.mkdir_p([File.join(crate, "src"), File.join(crate, "tests"), File.join(home, ".cargo/git/checkouts/x")])
      File.write(File.join(crate, "src/lib.rs"), "pub fn run() {}\n")
      File.write(File.join(crate, "tests/key.pem"), "x\n")
      File.write(File.join(home, ".cargo/git/checkouts/x/.env"), "KEY=value\n")
    end

    def ruling(rung, rule: nil)
      Lain::Approval::Escalation::Ruling.allow(rung:, because: "approved", rule:, authority: :automatic)
    end

    def composed = request(ruling("rules", rule: "composed_term"))

    def request(ruling, executables: [], argv: nil)
      Lain::Confine::Request.new(ruling:, executables:, cwd: root, root:, tool_use_id: "toolu_1",
                                 **(argv ? { argv: } : {}))
    end

    def elf(file)
      FileUtils.mkdir_p(File.dirname(file))
      fields = [2, 62, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0].pack("S<S<L<Q<Q<Q<L<S<S<S<S<S<S<")
      File.binwrite(file, ["\x7FELF".b, [2, 1, 1].pack("C3"), "\0" * 9, fields, [1].pack("L<"), "\0" * 52].join)
      File.chmod(0o755, file)
      file
    end

    # A lineage that wrote nothing under the project, where each file reads as fresh or not.
    def lineage(fresh:)
      Struct.new(:all) do
        def any_under?(_root) = false
        def fresh?(_path) = all
        def making(path) = yield(path)
      end.new(fresh)
    end

    def profiles(**rest) = Lain::Confine::Profiles.new(masks: cached, probe:, home:, root:, classifier: cached, **rest)

    it "lists neither cache, and lends both as reads with no mask" do
      started = []
      shell_out = lambda do |*argv, **opts|
        started << argv
        Lain::Shell::Out.new(*argv, **opts)
      end
      listing = described_class.new(root:, policy: -> { session }, shell_out:)

      related = related_after(listing)

      expect([related.roots, related.masks]).to eq([[], []])
      expect(related.reads).to include(registry_src, File.join(home, ".cargo/git/checkouts"))
      expect(started.flatten.grep(%r{\.cargo/})).to eq([])
    end

    it "globs for a git checkout's .git/config under cargo's checkouts only, not under every read root" do
      clone = File.join(session.read_roots.first, "a", "b").tap { FileUtils.mkdir_p(_1) }
      SeedRepo.git(clone, "init", "-q")

      expect(related_after(cached).masks).to eq([])
    end

    it "masks each git checkout's .git/config under a read root whole, 2 levels down, as cargo lays them out" do
      checkout = File.join(home, ".cargo/git/checkouts/dep-abc/1234567").tap { FileUtils.mkdir_p(_1) }
      SeedRepo.git(checkout, "init", "-q")

      expect(related_after(cached).masks.map(&:path)).to eq([File.join(checkout, ".git", "config")])
    end

    it "keeps a granted linter granted" do
      shellcheck = elf(File.join(home, ".local/bin/shellcheck"))
      related_after(cached)

      linting = profiles(env: { "PATH" => File.dirname(shellcheck) }, fresh: lineage(fresh: false))

      expect(linting.for(composed).runs?(shellcheck)).to be(true)
    end

    it "keeps the hidden toolchain files hidden from a workspace call" do
      config = File.join(home, ".bundle/config").tap { FileUtils.mkdir_p(File.dirname(_1)) }
      File.write(config, "---\n")
      related_after(cached)

      profile = profiles(workspace: true, tmpdir: scratch).for(request(ruling("auto")))

      expect(profile.hidden).to include(config)
      expect(profile.masks).not_to include(config)
    end

    it "keeps a pinned mise install's write to mise's data dir" do
      data = File.join(home, ".local/share/mise").tap { FileUtils.mkdir_p(_1) }
      mise = File.join(home, ".local/bin/mise").tap { FileUtils.mkdir_p(File.dirname(_1)) }
      File.write(mise, "#!/bin/sh\n")
      File.chmod(0o755, mise)
      write("mise.toml", %([tools]\njq = "1.8.1"\n))
      registry = Struct.new(:answer) { def backend(**) = answer }.new("aqua:jqlang/jq")
      fresh = lineage(fresh: true)
      executable = Lain::Shell::Executable.new(name: "mise", resolved: mise, realpath: mise, chain: [], shadowed: [],
                                               anomalies: [], klass: :user, fresh: false, run_files: [], wrappers: [])
      related_after(cached)

      profile = profiles(workspace: true, tmpdir: scratch, fresh:, env: {}, registry:)
                .for(request(ruling("auto"), executables: [executable], argv: [%w[mise install jq@1.8.1]]))

      expect(profile).to have_attributes(name: :grant, mise_data: data)
      expect(profile.write_dirs).to include(data)
    end

    def related_after(listing)
      listing.masks
      listing.related
    end
  end

  describe "a contained reader call into a cache outside the project", :seam do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }
    let(:home) { File.join(@base, "home") }
    let(:token) { %w[hf ZqX7mN2vB9kL4pR8sT1wY6].join("_") }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
      skip("bwrap cannot make a user namespace on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
    end

    # The reader profile as `Profiles` builds it over the list: the project's masks and each related one.
    def reader_over(policy)
      listing = described_class.new(root:, policy: -> { policy })
      related = listing.tap(&:masks).related
      Lain::Confine::Profile.reader(root:, home:, masks: [*listing.masks, *related.masks].map(&:path),
                                    related: [*related.roots, *related.reads])
    end

    def confined(command, policy)
      profile = reader_over(policy)
      launcher = Lain::Confine::Bwrap.new(fence:)
      bound = launcher.masked(profile).bind(stages: 1, first_fd: 4)
      argv = launcher.wrap(Lain::Shell::Term.of(["/bin/sh", "-c", command]), profile, trace_fd: 3, bound:)
                     .stages.first.argv
      out, = Open3.capture3({ "LC_ALL" => "C" }, *argv, chdir: root, 3 => File::NULL, **bound.fds)
      out
    ensure
      bound&.close
    end

    it "reads a project-related cache that is not a repository with its token masked" do
      cache = File.join(home, ".cache/huggingface").tap { FileUtils.mkdir_p(File.join(_1, "hub")) }
      File.write(File.join(cache, "token"), token)
      File.write(File.join(cache, "hub/version.txt"), "1\n")
      rules = Lain::Sensitivity::Rules.new(related: ["~/.cache/huggingface"])
      policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, rules:), home:,
                                             root:)

      read = confined("cat #{cache}/hub/version.txt; cat #{cache}/token", policy)

      expect(read).to start_with("1\n")
      expect(read).not_to include(token)
    end

    it "shows a cargo checkout's .git/config empty or as a decoy, whatever its remote URL carries" do
      checkout = File.join(home, ".cargo/git/checkouts/dep-abc/1234567").tap { FileUtils.mkdir_p(_1) }
      SeedRepo.git(checkout, "init", "-q")
      SeedRepo.git(checkout, "remote", "add", "origin", "https://x:#{token}@example.com/r.git")
      policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root), home:, root:,
                                             read_roots: [File.join(home, ".cargo/git/checkouts")])

      expect(confined("cat #{checkout}/.git/config", policy)).not_to include(token)
    end

    it "lists the cargo registry a Rust project reads" do
      FileUtils.mkdir_p(File.join(home, ".cargo/registry/src/index/whisper-rs-0.16.0"))
      policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root), home:, root:,
                                             read_roots: [File.join(home, ".cargo/registry/src")])

      expect(confined("ls #{home}/.cargo/registry/src/index", policy)).to eq("whisper-rs-0.16.0\n")
    end
  end
end
