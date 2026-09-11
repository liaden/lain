# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

# Every git call against the lain-owned store, and the one place git's `-z`
# names become Ruby strings.
RSpec.describe Lain::Workspace::Snapshot::Scope::ShadowGit::Repository, :seam do
  around do |example|
    Dir.mktmpdir("lain-shadow-repo-project") do |project|
      Dir.mktmpdir("lain-shadow-repo-state") do |state|
        @project = File.realpath(project)
        @state = File.realpath(state)
        example.run
      end
    end
  end

  attr_reader :project

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }) }
  let(:repository) { described_class.open(root: project, paths:) }

  def put(name, bytes, mode: nil)
    File.join(project, name).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
      File.chmod(mode, path) if mode
    end
  end

  def rows_by_key(before, after) = repository.rows(before, after).to_h { |row| [row.key, row] }

  it "stages the work tree into a tree id that changes only when the tree does" do
    put("a.txt", "a\n")
    first = repository.stage

    expect(repository.stage).to eq(first)

    put("a.txt", "changed\n")
    expect(repository.stage).not_to eq(first)
  end

  it "names what changed since a tree, root-relative" do
    put("a.txt", "a\n")
    since = repository.stage
    put("b.txt", "b\n")
    repository.stage

    expect(repository.changed(since)).to eq(["b.txt"])
  end

  # A deletion, an addition, an edit and a mode change between two trees: the
  # four shapes an undo has to put back, each with both sides' modes.
  it "lists the rows between two trees, with each side's mode and blob" do
    put("old.txt", "old\n")
    put("mod.txt", "m0\n")
    put("run.sh", "echo\n", mode: 0o644)
    before = repository.stage
    File.delete(File.join(project, "old.txt"))
    put("new.txt", "n\n")
    put("mod.txt", "m1\n")
    File.chmod(0o755, File.join(project, "run.sh"))
    rows = rows_by_key(before, repository.stage)

    expect(rows.keys).to contain_exactly("old.txt", "new.txt", "mod.txt", "run.sh")
    expect(rows.fetch("old.txt")).to have_attributes(before_mode: "100644", after_mode: nil, after_id: nil)
    expect(rows.fetch("new.txt")).to have_attributes(before_mode: nil, before_id: nil, after_mode: "100644")
    expect(rows.fetch("run.sh")).to have_attributes(before_mode: "100644", after_mode: "100755")
    expect(rows.fetch("run.sh").before_id).to eq(rows.fetch("run.sh").after_id)
  end

  it "reads a blob back byte for byte, binary included" do
    bytes = (0..255).map(&:chr).join.b * 16
    put("blob.bin", bytes)
    before = repository.stage
    put("blob.bin", "X")

    row = rows_by_key(before, repository.stage).fetch("blob.bin")

    expect(repository.blob(row.before_id)).to eq(bytes)
  end

  it "says whether the project's .gitignore hides a path" do
    put(".gitignore", "*.log\n")

    expect(repository.ignored?("app.log")).to be(true)
    expect(repository.ignored?("app.rb")).to be(false)
  end

  # Two chats on one project share one store. A shared index would have them
  # stage over each other and lose `index.lock` races; each session's own
  # index inside the store keeps their staging apart.
  describe "sessions sharing one store" do
    def store = File.join(paths.state_home, "workspace", paths.project_hash(project))

    it "gives each session its own index inside the shared store" do
      put("a.txt", "a\n")
      described_class.open(root: project, paths:, session: "one").stage
      described_class.open(root: project, paths:, session: "two").stage

      expect(Dir.children(store).grep(/\Aindex/)).to contain_exactly("index-one", "index-two")
    end

    it "lets two processes stage one store at once without failing" do
      40.times { |i| put("f#{i}.txt", "#{i}\n") }
      workers = Array.new(2) do |worker|
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          repository = described_class.open(root: project, paths:, session: "worker-#{worker}")
          failures = Array.new(10) do |i|
            put("w#{worker}-#{i}.txt", "x")
            repository.stage
            nil
          rescue Lain::Workspace::Snapshot::Scope::ShadowGit::Failed => e
            e.message
          end
          writer.puts(failures.compact.length)
          exit!(0)
        end
        writer.close
        [pid, reader]
      end

      counts = workers.map do |pid, reader|
        Process.wait(pid)
        Integer(reader.read.strip)
      end

      expect(counts).to eq([0, 0])
    end

    # A git whose first `init` loses the lock race a second process creating
    # the same store would cause.
    it "survives losing a lock race while creating the store" do
      real = Mixlib::ShellOut.public_method(:new)
      lost = false
      loser = Struct.new(:exitstatus, :stdout, :stderr) { def run_command = self }
      racing = lambda do |*argv, **options|
        losing = !lost && argv.include?("init")
        lost ||= losing
        losing ? loser.new(128, "", "error: could not lock config file") : real.call(*argv, **options)
      end

      expect(described_class.open(root: project, paths:, shell_out_factory: racing).stage).to match(/\A\h+\z/)
    end
  end

  describe "names outside ASCII" do
    it "hands back a non-ASCII name as UTF-8, from both listings" do
      before = repository.stage
      put("café.txt", "x\n")
      put("naïve/résumé.md", "y\n")
      after = repository.stage

      expect(repository.changed(before)).to contain_exactly("café.txt", "naïve/résumé.md")
      expect(repository.changed(before)).to all(have_attributes(encoding: Encoding::UTF_8))
      expect(repository.rows(before, after).map(&:key)).to contain_exactly("café.txt", "naïve/résumé.md")
    end

    # A name git hands back that is not UTF-8 cannot become a key a restore
    # writes to faithfully, so it is refused by name rather than mangled.
    it "refuses a name that is not valid UTF-8, naming it" do
      before = repository.stage
      put((+"bad\xFF.txt").force_encoding(Encoding::BINARY), "x\n")
      repository.stage

      expect { repository.changed(before) }
        .to raise_error(Lain::Workspace::Snapshot::Scope::ShadowGit::Failed, /not valid UTF-8.*bad/)
    end
  end
end
