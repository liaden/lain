# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "openssl"
require "securerandom"

# Every git argv the subject spawns, run for real unless it names a word
# `failing` holds, which runs `false` in its place that many times, or the
# word `timing_out` names, which times out.
class HistoryLiteralsSpecSpy
  attr_reader :argvs

  # A command that outlived its bound.
  TimedOut = Struct.new(:argv) do
    def run_command = raise(Lain::Shell::Out::Timeout, "timed out")
  end

  def initialize(gate: nil, failing: {}, timing_out: nil)
    @argvs = []
    @gate = gate
    @failing = failing.dup
    @timing_out = timing_out
  end

  def call(*argv, **)
    @argvs << argv
    @gate&.pop if argv.include?("rev-list")
    return TimedOut.new(argv) if argv.include?(@timing_out)

    Lain::Shell::Out.new(*(failed?(argv) ? ["false"] : argv), **)
  end

  # @param word [String] fails the next commands naming it
  # @param times [Integer] how many of them fail
  def fail_next(word, times = 1) = @failing[word] = times

  def enumerations = runs("rev-list")

  def runs(word) = @argvs.count { _1.include?(word) }

  private

  def failed?(argv)
    word = @failing.keys.find { argv.include?(_1) && @failing[_1].positive? }
    word && (@failing[word] -= 1)
  end
end

RSpec.describe Lain::Sensitivity::HistoryLiterals, :seam do
  let(:root) { File.join(@base, "repo") }
  let(:policy) do
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: File.join(@base, "home"), cwd: root,
                                                                     rules: Lain::Sensitivity::Rules.empty, root:),
                                  root:)
  end

  around do |example|
    Dir.mktmpdir("lain-history-literals") { |made| (@base = File.realpath(made)) and example.run }
  end

  def git(*) = SeedRepo.git(root, *)

  # HEAD~1 committed the dotenv and HEAD deleted it, so only history holds it.
  def seed_deleted(dotenv)
    SeedRepo.derived("history-literals #{dotenv}", into: root) do |dir|
      File.write(File.join(dir, ".env"), dotenv)
      SeedRepo.git(dir, "add", ".env")
      SeedRepo.git(dir, "commit", "-q", "-m", "add env")
      SeedRepo.git(dir, "rm", "-q", ".env")
      SeedRepo.git(dir, "commit", "-q", "-m", "drop env")
    end
  end

  def commit(name, content)
    FileUtils.mkdir_p(File.dirname(File.join(root, name)))
    File.write(File.join(root, name), content)
    git("add", name)
    git("commit", "-q", "-m", "add #{name}")
  end

  it "lists a value a deleted sensitive file held in history" do
    seed_deleted("ADMIN_PIN=48291377\n")

    expect(described_class.new(root:, policy:).to_a).to include("48291377")
  end

  it "lists a value an untracked, ignored sensitive file holds" do
    seed_deleted("ADMIN_PIN=48291377\n")
    File.write(File.join(root, ".gitignore"), ".env.local\n")
    File.write(File.join(root, ".env.local"), "GREETING=correct horse battery\n")

    expect(described_class.new(root:, policy:).to_a).to include("correct horse battery")
  end

  # The files on disk are listed as the mask list lists them, over a tree a sandboxed call wrote.
  it "runs no fsmonitor the checkout's config names while it lists the files on disk" do
    seed_deleted("ADMIN_PIN=48291377\n")
    marker = File.join(@base, "fsmonitor-ran")
    git("config", "core.fsmonitor", "touch #{marker}; false")
    File.write(File.join(root, ".env.local"), "GREETING=correct horse battery\n")

    expect(described_class.new(root:, policy:).to_a).to include("correct horse battery")
    expect(File.exist?(marker)).to be(false)
  end

  # A commondir a call plants after the reader was built names refs the clone does not hold; only the clone's
  # own git dir decides which history is read.
  it "reads only a clone's own refs, never those a planted commondir names" do
    seed_deleted("ADMIN_PIN=48291377\n")
    secret = git("rev-parse", "HEAD").stdout.strip
    git("reset", "-q", "--hard", "HEAD~2")
    git("reflog", "expire", "--expire=now", "--all")
    leases = File.join(Lain::Paths.new.state_home, "worktrees", Lain::Paths.new.project_hash(root))
    FileUtils.mkdir_p(leases)
    clone = File.join(leases, "a")
    base = git("rev-parse", "HEAD").stdout.strip
    Lain::Isolation::Clone::Registry.new(repo_root: root, root: leases,
                                         shell_out_factory: Lain::Shell::Out.public_method(:new))
                                    .add(clone, base, reason: "held")
    clone_policy = Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: File.join(@base, "home"), cwd: clone, rules: Lain::Sensitivity::Rules.empty,
                                         root: clone), root: clone
    )
    literals = described_class.new(root: clone, policy: clone_policy)
    evil = File.join(clone, "evil")
    FileUtils.mkdir_p(File.join(evil, "refs", "heads"))
    FileUtils.cp_r(File.join(root, ".git", "objects"), evil)
    File.write(File.join(evil, "refs", "heads", "planted"), "#{secret}\n")
    File.write(File.join(evil, "config"), "[core]\n\trepositoryformatversion = 0\n")
    File.write(File.join(clone, ".git", "commondir"), "../evil\n")

    expect(literals.to_a).not_to include("48291377")
  ensure
    FileUtils.rm_rf(leases) if leases
  end

  it "lists nothing an ordinary path held" do
    seed_deleted("ADMIN_PIN=48291377\n")
    commit("notes.txt", "COLOUR=ultraviolet-blue\n")

    expect(described_class.new(root:, policy:).to_a).not_to include("ultraviolet-blue")
  end

  it "lists no value shorter than the floor" do
    seed_deleted("PIN=1234\n")

    expect(described_class.new(root:, policy:).to_a).not_to include("1234")
  end

  it "answers frozen" do
    seed_deleted("ADMIN_PIN=48291377\n")

    expect(described_class.new(root:, policy:).to_a).to be_frozen
  end

  it "lists a value an amended-away commit held, reachable only through the reflog" do
    seed_deleted("ADMIN_PIN=48291377\n")
    commit(".npmrc", "TOKEN=amended-away-value\n")
    File.write(File.join(root, ".npmrc"), "TOKEN=amended-in-value\n")
    git("commit", "-q", "-a", "--amend", "-m", "amend")
    git("rm", "-q", ".npmrc")
    git("commit", "-q", "-m", "drop npmrc")

    expect(described_class.new(root:, policy:).to_a).to include("amended-away-value", "amended-in-value")
  end

  it "lists a lone line a value file holds, and no line of a file holding several" do
    seed_deleted("ADMIN_PIN=48291377\n")
    commit("secrets/token", "lone-line-value-1\n")
    commit("secrets/notes", "first-of-two-lines\nsecond-of-two-lines\n")

    expect(described_class.new(root:, policy:).to_a)
      .to include("lone-line-value-1").and(not_include("first-of-two-lines", "second-of-two-lines"))
  end

  it "lists a region the detector finds where nothing is assigned" do
    seed_deleted("ADMIN_PIN=48291377\n")
    token = "ghp_aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5"
    commit("secrets/notes", "the deploy token\n#{token}\n")

    expect(described_class.new(root:, policy:).to_a).to include(token)
  end

  describe "#refusable" do
    let(:high) { "Zq8xV2nL4tR7yW1kP9mB3cJ6hD0sF5gA" }

    it "answers a value under a secret-named key and a high-entropy one, not ordinary config" do
      seed_deleted("APP_ENV=staging-eu\nAPP_HOST=myapp.internal:8080\nLOG_LEVEL=verbose-debug\n" \
                   "SECRET_KEY_BASE=fake-probe-secret-0123456789\nDB_PASSWORD=plainword99\nBUILD_SALT=#{high}\n")
      literals = described_class.new(root:, policy:)

      expect(literals.refusable).to contain_exactly("fake-probe-secret-0123456789", "plainword99", high)
      expect(literals.to_a).to include("staging-eu", "myapp.internal:8080", "verbose-debug")
    end

    it "answers a region the detector finds, and not a lone ordinary line" do
      seed_deleted("APP_ENV=staging-eu\n")
      token = "ghp_aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5"
      commit("secrets/notes", "the deploy token\n#{token}\n")
      commit("secrets/token", "lone-line-value-1\n")

      expect(described_class.new(root:, policy:).refusable).to include(token).and(not_include("lone-line-value-1"))
    end

    it "answers frozen" do
      seed_deleted("DB_PASSWORD=plainword99\n")

      expect(described_class.new(root:, policy:).refusable).to be_frozen
    end

    # One example per arm, each with a value no other arm accepts. A YAML line
    # and a JSON line are the shapes the file-wide region pass does not read
    # as an assignment, so only the arm under test can answer them.
    it "answers a low-entropy value under a secret-named key" do
      seed_deleted("deploy_key: plainword99\n")

      expect(described_class.new(root:, policy:).refusable).to eq(["plainword99"])
    end

    it "answers a low-entropy value under an all-caps name glued to KEY" do
      seed_deleted("MASTERKEY=plainword99\n")

      expect(described_class.new(root:, policy:).refusable).to eq(["plainword99"])
    end

    it "answers a low-entropy value under a name whose last word ends in an ordinary word's letters" do
      seed_deleted("DaemonKey=plainword99\n")

      expect(described_class.new(root:, policy:).refusable).to eq(["plainword99"])
    end

    it "answers a low-entropy value under a name glued to Token after an ordinary word's letters" do
      seed_deleted("summonToken=plainword99\n")

      expect(described_class.new(root:, policy:).refusable).to eq(["plainword99"])
    end

    it "answers a whole value the detector shapes, under a plain key" do
      url = "postgres://app:fakeS3cretPw@db.internal:5432/app"
      seed_deleted("DB_URL=#{url}\n")

      expect(described_class.new(root:, policy:).refusable).to include(url)
    end

    it "answers a high-entropy value the detector does not shape, under a plain key" do
      seed_deleted("\"salt\": \"Zq8xV2nL4tR7yW1=kP9mB3cJ6hD0sF5\",\n")

      expect(described_class.new(root:, policy:).refusable).to eq(["Zq8xV2nL4tR7yW1=kP9mB3cJ6hD0sF5"])
    end

    it "keeps refusable a value one commit holds under a secret-named key and a later one under a plain key" do
      seed_deleted("APP_ENV=staging-eu\n")
      commit("secrets/first", "deploy_key: laterplain88\n")
      commit("secrets/later", "app_label: laterplain88\n")

      expect(described_class.new(root:, policy:).refusable).to eq(["laterplain88"])
    end

    it "keeps refusable a value seen under a secret-named key and then a plain one" do
      seed_deleted("deploy_key: sharedvalue77\napp_label: sharedvalue77\n")

      expect(described_class.new(root:, policy:).refusable).to eq(["sharedvalue77"])
    end
  end

  describe "#split" do
    it "answers both sets from one read, the same as the two readers" do
      seed_deleted("APP_ENV=staging-eu\nDB_PASSWORD=plainword99\n")
      literals = described_class.new(root:, policy:)

      split = literals.split

      expect([split.known, split.refusable]).to eq([literals.to_a, literals.refusable])
      expect(split.known).to include("staging-eu", "plainword99")
      expect(Ractor.shareable?(split)).to be(true)
    end

    it "answers empty for a run with no project" do
      expect(described_class::Null.split).to have_attributes(known: [], refusable: [])
    end
  end

  describe "a value a non-sensitive file tracked at the starting commit also holds" do
    let(:dotenv) do
      "ADMIN_PIN=48291377\nNODE_ENV=development\nDB_HOST=localhost\nAPP_URL=http://127.0.0.1:3000\n"
    end

    before do
      seed_deleted(dotenv)
      commit("config/app.yml", "env: development\nhost: localhost\nurl: http://127.0.0.1:3000\n")
    end

    it "is not listed, while a value only the deleted file held still is" do
      expect(described_class.new(root:, policy:).to_a)
        .to include("48291377").and(not_include("development", "localhost", "http://127.0.0.1:3000"))
    end

    it "is still not listed after a ref moves" do
      literals = described_class.new(root:, policy:)
      literals.to_a
      commit("notes.txt", "x\n")

      expect(literals.to_a).to include("48291377").and(not_include("development"))
    end

    it "is listed when only a commit made after the first read holds it" do
      literals = described_class.new(root:, policy:)
      literals.to_a
      commit("notes.txt", "pin 48291377\n")

      expect(literals.to_a).to include("48291377")
    end

    it "still has its history and disk halves refreshed by a ref move" do
      literals = described_class.new(root:, policy:)
      literals.to_a
      File.write(File.join(root, ".gitignore"), ".env.local\n")
      File.write(File.join(root, ".env.local"), "GREETING=correct horse battery\n")
      commit(".npmrc", "TOKEN=fresh-commit-value\n")

      expect(literals.to_a).to include("fresh-commit-value", "correct horse battery")
    end

    it "is listed when only another sensitive file holds it too" do
      commit(".env.production", "PIN=48291377\n")

      expect(described_class.new(root:, policy:).to_a).to include("48291377")
    end

    it "is not listed when a tracked example file and a README both hold it" do
      commit(".env.example", "GREETING=example-greeting-value\n")
      commit("README", "Set GREETING to example-greeting-value.\n")

      expect(described_class.new(root:, policy:).to_a).not_to include("example-greeting-value")
    end

    it "is listed when the search fails" do
      literals = described_class.new(root:, policy:, shell: HistoryLiteralsSpecSpy.new(failing: { "grep" => 1 }))

      expect(literals.to_a).to include("48291377", "development", "localhost")
    end

    it "is listed when the search times out" do
      literals = described_class.new(root:, policy:, shell: HistoryLiteralsSpecSpy.new(timing_out: "grep"))

      expect(literals.to_a).to include("48291377", "development", "localhost")
    end

    it "is listed when the file holding it is only staged, since the search reads the starting commit" do
      File.write(File.join(root, "staged.txt"), "PIN 48291377\n")
      git("add", "staged.txt")

      expect(described_class.new(root:, policy:).to_a).to include("48291377")
    end

    it "is listed when only a binary file holds it" do
      File.binwrite(File.join(root, "blob.bin"), "\x00\x01 48291377 \x00")
      git("add", "blob.bin")
      git("commit", "-q", "-m", "binary")

      expect(described_class.new(root:, policy:).to_a).to include("48291377")
    end

    it "is not listed when a non-sensitive file whose name is not ASCII holds it" do
      commit("données/app.yml", "pin: 48291377\n")

      expect(described_class.new(root:, policy:).to_a).not_to include("48291377")
    end
  end

  describe "a value a tracked file holds only inside a longer token" do
    before do
      seed_deleted("ADMIN_PIN=48291377\nSALT=k9Qz7mWp2x\n")
      commit("data/ids.csv", "9482913770\nk9Qz7mWp2xLLnn8\n")
    end

    it "is listed" do
      expect(described_class.new(root:, policy:).to_a).to include("48291377", "k9Qz7mWp2x")
    end
  end

  describe "a root below the repository's top" do
    let(:top) { File.join(@base, "top") }
    let(:root) { File.join(top, "app") }

    before do
      SeedRepo.derived("history-literals below top", into: top) do |dir|
        File.write(File.join(dir, ".env"), "ADMIN_PIN=48291377\nNODE_ENV=development\n")
        FileUtils.mkdir_p(File.join(dir, "app"))
        File.write(File.join(dir, "app", "main.rb"), "puts 1\n")
        File.write(File.join(dir, "config.yml"), "env: development\n")
        SeedRepo.git(dir, "add", ".")
        SeedRepo.git(dir, "commit", "-q", "-m", "seed")
        SeedRepo.git(dir, "rm", "-q", ".env")
        SeedRepo.git(dir, "commit", "-q", "-m", "drop env")
      end
    end

    it "frees a value a file outside the root holds" do
      expect(described_class.new(root:, policy:).to_a).to include("48291377").and(not_include("development"))
    end
  end

  it "lists a value a CRLF file assigns without its carriage return" do
    seed_deleted("ADMIN_PIN=48291377\r\nTOKEN=crlf-value-123\r\n")

    expect(described_class.new(root:, policy:).to_a).to include("crlf-value-123", "48291377")
  end

  describe "the size cap" do
    def sized(value, bytes) = "TOKEN=#{value}\n".then { "#{_1}#{"#" * (bytes - _1.bytesize - 1)}\n" }

    before { seed_deleted("ADMIN_PIN=48291377\n") }

    it "reads a history blob at the cap and skips one past it" do
      commit("secrets/at-cap", sized("history-at-cap", described_class::LARGEST))
      commit("secrets/past-cap", sized("history-past-cap", described_class::LARGEST + 1))

      expect(described_class.new(root:, policy:).to_a)
        .to include("history-at-cap").and(not_include("history-past-cap"))
    end

    it "reads a file on disk at the cap and skips one past it" do
      File.write(File.join(root, ".gitignore"), ".env.*\n")
      File.write(File.join(root, ".env.at"), sized("disk-at-cap", described_class::LARGEST))
      File.write(File.join(root, ".env.past"), sized("disk-past-cap", described_class::LARGEST + 1))

      expect(described_class.new(root:, policy:).to_a).to include("disk-at-cap").and(not_include("disk-past-cap"))
    end
  end

  describe "a root and a file whose names are not ASCII" do
    let(:root) { File.join(@base, "rép") }

    it "lists what history and the disk hold there" do
      seed_deleted("ADMIN_PIN=48291377\n")
      commit("données/.env", "TOKEN=non-ascii-history\n")
      File.write(File.join(root, "données", ".env.local"), "TOKEN=non-ascii-on-disk\n")

      expect(described_class.new(root:, policy:).prime.to_a).to include("non-ascii-history", "non-ascii-on-disk")
    end
  end

  describe "a git command that fails" do
    let(:literals) { described_class.new(root:, policy:, shell: spy) }

    before do
      seed_deleted("ADMIN_PIN=48291377\n")
      File.write(File.join(root, ".gitignore"), ".env.local\n")
      File.write(File.join(root, ".env.local"), "GREETING=correct horse battery\n")
    end

    describe "rev-list" do
      let(:spy) { HistoryLiteralsSpecSpy.new(failing: { "rev-list" => 1 }) }

      it "keeps what is on disk, and is not retried until a ref moves" do
        2.times { literals.to_a }

        expect(literals.to_a).to include("correct horse battery").and(not_include("48291377"))
        expect(spy.enumerations).to eq(1)
      end

      it "is retried once a ref moves" do
        literals.to_a
        commit("notes.txt", "x\n")

        expect(literals.to_a).to include("48291377")
      end
    end

    describe "ls-files" do
      let(:spy) { HistoryLiteralsSpecSpy.new(failing: { "ls-files" => 1 }) }

      it "keeps what history holds, and is not retried until a ref moves" do
        2.times { literals.to_a }

        expect(literals.to_a).to include("48291377").and(not_include("correct horse battery"))
        expect(spy.runs("ls-files")).to eq(1)
      end
    end

    describe "rev-list and ls-files, after a read that succeeded" do
      let(:spy) { HistoryLiteralsSpecSpy.new }

      it "keeps the values the last read listed" do
        literals.to_a
        commit("notes.txt", "x\n")
        spy.fail_next("rev-list")
        spy.fail_next("ls-files")

        expect(literals.to_a).to include("48291377", "correct horse battery")
        expect(spy.runs("ls-files")).to eq(2)
      end
    end

    describe "cat-file" do
      let(:spy) { HistoryLiteralsSpecSpy.new(failing: { "--batch" => 1 }) }

      it "reads the blobs again once a ref moves" do
        expect(literals.to_a).not_to include("48291377")

        commit("notes.txt", "x\n")

        expect(literals.to_a).to include("48291377")
      end
    end
  end

  describe "git missing" do
    let(:missing) { ->(*argv, **opts) { Lain::Shell::Out.new("/nonexistent/git", *argv.drop(1), **opts) } }

    it "lists nothing, and raises nothing" do
      seed_deleted("ADMIN_PIN=48291377\n")

      expect(described_class.new(root:, policy:, shell: missing).prime.to_a).to eq([])
    end
  end

  describe "a prime that raises" do
    let(:raising) { instance_double(Lain::Sensitivity::Policy) }

    it "raises it again from the read that joins it" do
      seed_deleted("ADMIN_PIN=48291377\n")
      allow(raising).to receive(:classify).and_raise(ArgumentError, "unreadable rule")

      expect { described_class.new(root:, policy: raising).prime.to_a }.to raise_error(ArgumentError, "unreadable rule")
    end

    it "keeps the commit the first refresh started from, though that refresh raised" do
      seed_deleted("ADMIN_PIN=48291377\n")
      calls = 0
      allow(raising).to receive(:classify) do |path, **|
        (calls += 1) == 1 ? raise(ArgumentError, "once") : policy.classify(path)
      end
      literals = described_class.new(root:, policy: raising)
      expect { literals.to_a }.to raise_error(ArgumentError, "once")
      commit("notes.txt", "pin 48291377\n")

      expect(literals.to_a).to include("48291377")
    end

    it "raises again from the next read rather than answering an empty list" do
      seed_deleted("ADMIN_PIN=48291377\n")
      allow(raising).to receive(:classify).and_raise(ArgumentError, "unreadable rule")
      literals = described_class.new(root:, policy: raising).prime
      expect { literals.to_a }.to raise_error(ArgumentError)

      expect { literals.to_a }.to raise_error(ArgumentError, "unreadable rule")
    end
  end

  describe "the enumeration" do
    let(:spy) { HistoryLiteralsSpecSpy.new }
    let(:literals) { described_class.new(root:, policy:, shell: spy) }

    before { seed_deleted("ADMIN_PIN=48291377\n") }

    it "runs once while no ref moves" do
      2.times { literals.to_a }

      expect(spy.enumerations).to eq(1)
    end

    it "runs again after a new commit, and lists what it added" do
      literals.to_a
      commit(".npmrc", "TOKEN=fresh-commit-value\n")

      expect(literals.to_a).to include("fresh-commit-value")
      expect(spy.enumerations).to eq(2)
    end
  end

  describe "a read during the prime" do
    let(:gate) { Queue.new }
    let(:literals) { described_class.new(root:, policy:, shell: HistoryLiteralsSpecSpy.new(gate:)) }

    before { seed_deleted("ADMIN_PIN=48291377\n") }

    after { 2.times { gate << :go } }

    it "waits for the prime to finish, and holds its values" do
      literals.prime
      reader = Thread.new { literals.to_a }

      expect(reader.join(0.2)).to be_nil
      gate << :go
      expect(reader.join(5)&.value).to include("48291377")
    end
  end

  # A missing object is fetched through the program the clone's own config names, so reading history
  # in a cloned repository would run that program before any prompt.
  describe "a partial clone whose history holds a blob it never fetched" do
    let(:marker) { File.join(@base, "MARKER") }

    before do
      source = File.join(@base, "source")
      SeedRepo.derived("history-literals partial-clone source", into: source) do |dir|
        File.write(File.join(dir, ".env"), "ADMIN_PIN=48291377\n")
        SeedRepo.git(dir, "add", ".env")
        SeedRepo.git(dir, "commit", "-q", "-m", "add env")
        SeedRepo.git(dir, "rm", "-q", ".env")
        SeedRepo.git(dir, "commit", "-q", "-m", "drop env")
      end
      SeedRepo.git(source, "config", "uploadpack.allowFilter", "true")
      SeedRepo.git(@base, "clone", "-q", "--filter=blob:none", "file://#{source}", root)
      git("config", "user.name", "spec")
      git("config", "user.email", "spec@example.com")
      commit(".env.local", "LOCAL_PIN=55501234\n")
      git("rm", "-q", ".env.local")
      git("commit", "-q", "-m", "drop local env")
      upload_pack = File.join(@base, "upload-pack")
      File.write(upload_pack, "#!/bin/sh\ntouch '#{marker}'\nexec git upload-pack \"$@\"\n")
      File.chmod(0o755, upload_pack)
      git("config", "remote.origin.uploadpack", upload_pack)
    end

    it "runs no program the repository names, and still lists the history it holds" do
      values = described_class.new(root:, policy:).to_a

      expect([File.exist?(marker), values]).to match([false, include("55501234")])
    end
  end

  describe "a root that is not a git repository" do
    before { FileUtils.mkdir_p(root) }

    it "lists nothing, and raises nothing" do
      expect(described_class.new(root:, policy:).prime.to_a).to eq([])
    end
  end

  describe described_class::Null do
    it "lists nothing" do
      expect(described_class.to_a).to eq([])
    end
  end

  describe "Rails credentials" do
    # Sealed the way Rails seals credentials, without ActiveSupport: loading it here would
    # put its JSON extensions into every later example in the worker.
    def seal(yaml, key)
      cipher = OpenSSL::Cipher.new("aes-128-gcm").encrypt
      cipher.key = [key].pack("H*")
      iv = cipher.random_iv
      cipher.auth_data = ""
      data = cipher.update(Marshal.dump(yaml)) + cipher.final
      [data, iv, cipher.auth_tag].map { [_1].pack("m0") }.join("--")
    end

    it "lists a leaf the project's encrypted credentials hold" do
      key = SecureRandom.hex(16)
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/master.key"), key)
      File.write(File.join(root, "config/credentials.yml.enc"), seal("signing:\n  value: synthetic-leaf-4f9a2c\n", key))

      expect(described_class.new(root:, policy:).to_a).to include("synthetic-leaf-4f9a2c")
    end

    it "reports through the given callable a credentials file that will not decrypt, naming the file" do
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/master.key"), SecureRandom.hex(16))
      File.write(File.join(root, "config/credentials.yml.enc"), "not-decryptable")
      reasons = []

      described_class.new(root:, policy:, report: reasons.method(:<<)).to_a

      expect(reasons).to eq(["config/credentials.yml.enc did not decrypt"])
    end
  end
end
