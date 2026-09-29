# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "mixlib/shellout"

RSpec.describe Lain::QA::Changeset, :seam do
  around do |example|
    Dir.mktmpdir("lain-qa-changeset") do |dir|
      @repo = File.realpath(dir)
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @repo)
      example.run
    end
  end

  # The scrub is what makes this hermetic under pre-commit, which exports
  # GIT_INDEX_FILE into every hook: unscrubbed, the fixture would stage into
  # lain's own index.
  def git(*)
    Mixlib::ShellOut.new("git", "-C", @repo, *, environment: SeedRepo::SCRUB).run_command.tap(&:error!).stdout
  end

  def commit(files, message)
    files.each { |path, body| File.write(File.join(@repo, path), body) }
    git("add", "-A")
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD").strip
  end

  let(:base) { git("rev-parse", "HEAD").strip }

  it "lists exactly the paths git reports as changed between the base and the head" do
    base
    commit({ "order.rb" => "total\n", "order_spec.rb" => "describe\n" }, "work")

    expect(described_class.read(root: @repo, base:).changed).to contain_exactly("order.rb", "order_spec.rb")
  end

  it "quotes the range in short SHAs a human can paste" do
    base
    head = commit({ "order.rb" => "total\n" }, "work")

    expect(described_class.read(root: @repo, base:).range).to eq("#{base[0, 12]}..#{head[0, 12]}")
  end

  it "resolves a base named as a ref rather than a SHA" do
    seed = base
    git("tag", "before")
    head = commit({ "order.rb" => "total\n" }, "work")

    expect(described_class.read(root: @repo, base: "before"))
      .to have_attributes(base: seed, head:, changed: ["order.rb"])
  end

  it "reads nothing changed when the head is the base" do
    expect(described_class.read(root: @repo, base:).changed).to be_empty
  end

  # core.quotePath would report this as "f\303\266\303\266.rb", which no card's
  # Files paragraph could ever match.
  it "reads a non-ASCII path back as the name it was written under" do
    base
    commit({ "föö.rb" => "total\n" }, "work")

    expect(described_class.read(root: @repo, base:).changed).to eq(["föö.rb"])
  end

  # The example above passes under a filesystem-encoding tag too, but only on a
  # UTF-8 box: under LC_ALL=C that tag is US-ASCII and the same bytes compare
  # unequal to the plan document's path, which is a false major finding decided
  # by the runner's locale. The comparand is what fixes the encoding.
  it "tags a path with the encoding of the plan document it will be compared against" do
    base
    commit({ "föö.rb" => "total\n", "order.rb" => "total\n" }, "work")

    expect(described_class.read(root: @repo, base:).changed.map(&:encoding)).to all(eq(Encoding::UTF_8))
  end

  # A rename is two claims, not one: the card that moved the file owes both
  # paths, and a rename git folded into one entry would read as an unperformed
  # claim on the old name.
  it "reads a rename as both the path that went and the path that arrived" do
    commit({ "old.rb" => "total\n" }, "before")
    start = git("rev-parse", "HEAD").strip
    FileUtils.mv(File.join(@repo, "old.rb"), File.join(@repo, "new.rb"))
    commit({}, "rename")

    expect(described_class.read(root: @repo, base: start).changed).to contain_exactly("old.rb", "new.rb")
  end

  it "is a deeply frozen value, so every rung and every finding quote the same range" do
    base
    commit({ "order.rb" => "total\n" }, "work")

    expect(Ractor.shareable?(described_class.read(root: @repo, base:))).to be(true)
  end

  it "refuses a base git cannot resolve, naming the command that failed" do
    expect { described_class.read(root: @repo, base: "no-such-ref") }
      .to raise_error(Lain::Error, /could not read the changeset: `git rev-parse/)
  end

  # Mid-merge, HEAD is still the first parent, so the diff would report the
  # branch's own work and none of what the merge is bringing in.
  it "refuses a tree mid-merge rather than reporting a diff that omits the merge" do
    trunk = git("rev-parse", "--abbrev-ref", "HEAD").strip
    seed = base
    commit({ "order.rb" => "ours\n" }, "ours")
    git("checkout", "-q", "-b", "theirs", seed)
    commit({ "order.rb" => "theirs\n" }, "theirs")
    git("checkout", "-q", trunk)
    Mixlib::ShellOut.new("git", "-C", @repo, "merge", "theirs", environment: SeedRepo::SCRUB).run_command

    expect { described_class.read(root: @repo, base:) }
      .to raise_error(Lain::Error, /operation in progress.*Finish or abort it/m)
  end

  # The worst of the in-progress states and the one a merge check never sees:
  # nothing is conflicted, HEAD is simply parked behind the work, and the diff
  # is EMPTY -- every card in the plan a false major finding.
  it "refuses a rebase stopped part way, whose empty diff would fail every card at once" do
    seed = base
    commit({ "order.rb" => "total\n" }, "work")
    Mixlib::ShellOut.new("git", "-C", @repo, "rebase", "-i", seed,
                         environment: SeedRepo::SCRUB.merge("GIT_SEQUENCE_EDITOR" => "sed -i '1i break'")).run_command

    expect { described_class.read(root: @repo, base: seed) }.to raise_error(Lain::Error, /operation in progress/)
  end
end
