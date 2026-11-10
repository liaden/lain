# frozen_string_literal: true

require "fileutils"
require "timeout"
require "tmpdir"

RSpec.describe Lain::Confine::MaskList do
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
  let(:recording) do
    Class.new(SimpleDelegator) do
      def initialize(policy, asked)
        super(policy)
        @asked = asked
      end

      def mask_paths(files, **) = @asked.push(files.to_a).then { super }
    end.new(policy, asked)
  end
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

  it "reads nothing from a directory that is not a repository" do
    write(".env")
    list = described_class.new(root: @base, policy: -> { policy })

    expect(list.masks).to be_empty
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

      expect([related.roots, related.masks.map(&:path)]).to eq([[sibling], [hidden]])
      expect(paths).to eq([File.join(root, ".env")])
    end

    it "names no related directory readable before its masks are listed" do
      SeedRepo.git(sibling, "init", "-q")

      expect(list.related).to eq(described_class::Related::NONE)
    end

    it "names a related directory that is not a repository unreadable, since no listing finds its secrets" do
      secret(sibling)

      expect(related_after_masks.roots).to eq([])
    end

    # Each answer is 1 value, so a refresh between 2 asks cannot grant a root without its masks.
    it "names a root that became listable between 2 refreshes only with the masks listed for it" do
      hidden = secret(sibling)
      list.masks
      SeedRepo.git(sibling, "init", "-q")
      list.masks

      related = list.related

      expect([related.roots, related.masks.map(&:path)]).to eq([[sibling], [hidden]])
    end

    it "unlists a related directory whose listing fails, whatever an earlier listing found" do
      SeedRepo.git(sibling, "init", "-q")
      expect(related_after_masks.roots).to eq([sibling])
      FileUtils.rm_rf(File.join(sibling, ".git"))
      secret(sibling)

      expect(related_after_masks).to have_attributes(roots: [], masks: [])
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

    it "unlists every related directory when the project's own listing fails" do
      SeedRepo.git(sibling, "init", "-q")
      failing = false
      shell_out = lambda do |*argv, **opts|
        failing && argv.include?(root) ? raise(Lain::Shell::Out::Timeout) : Lain::Shell::Out.new(*argv, **opts)
      end
      flaky = described_class.new(root:, policy: -> { policy }, shell_out:)
      expect(related_after_masks(flaky).roots).to eq([sibling])

      failing = true

      expect(related_after_masks(flaky).roots).to eq([])
    end

    it "masks each directory below a pruned one whole, since the listing does not look inside it" do
      SeedRepo.git(sibling, "init", "-q")
      FileUtils.mkdir_p(%w[tmp/x a/node_modules/p/q vendor].map { File.join(sibling, _1) })
      File.write(File.join(sibling, "tmp", "x", ".env"), "KEY=value\n")
      File.write(File.join(sibling, "a", "node_modules", "p", "q", "f"), "x\n")
      File.write(File.join(sibling, "vendor", "top.txt"), "x\n")

      masks = related_after_masks.masks

      expect(masks.map(&:path)).to contain_exactly(File.join(sibling, "tmp", "x"),
                                                   File.join(sibling, "a", "node_modules", "p"))
    end

    it "masks each directory below a pruned one inside a nested repository whole" do
      SeedRepo.git(sibling, "init", "-q")
      nested = File.join(sibling, "nested")
      FileUtils.mkdir_p(File.join(nested, "target", "x"))
      SeedRepo.git(nested, "init", "-q")
      File.write(File.join(nested, "target", "x", "creds.txt"), "x\n")

      expect(related_after_masks.masks.map(&:path)).to eq([File.join(nested, "target", "x")])
    end

    it "keeps a nested repository's pruned directory masked whole on a later ask" do
      SeedRepo.git(sibling, "init", "-q")
      nested = File.join(sibling, "nested")
      FileUtils.mkdir_p(File.join(nested, "target", "x"))
      SeedRepo.git(nested, "init", "-q")
      File.write(File.join(nested, "target", "x", "creds.txt"), "x\n")
      aging = described_class.new(root:, policy: -> { policy }, stat: method(:aged))

      expect(Array.new(2) { related_after_masks(aging).masks.map(&:path) })
        .to eq([[File.join(nested, "target", "x")]] * 2)
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
end
