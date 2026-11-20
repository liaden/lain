# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Confine::DecoyGuard do
  around do |example|
    Dir.mktmpdir("lain-decoy-guard") { |made| (@root = File.realpath(made)) and example.run }
  end

  let(:decoy) { "0123456789abcdef0123456789abcdef" }
  let(:credentials) { "config/credentials.yml.enc" }

  def at(path) = File.join(@root, path)

  def git(*args, input: nil) = SeedRepo.git(@root, "-c", "user.name=s", "-c", "user.email=s@x", *args, input:).stdout

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(at(path)))
    File.write(at(path), text)
  end

  def repo(files = { credentials => "real credentials\n", ".env" => "SECRET=1\n", "app.rb" => "app\n" })
    git("init", "-q")
    files.each { |path, text| write(path, text) }
    git("add", "-A")
    git("commit", "-qm", "seed")
  end

  def blob(path, rev = ":") = git("rev-parse", "#{rev}#{path}").chomp

  def guard(masks = { at(credentials) => decoy, at(".env") => "" }) = described_class.before(root: @root, masks:)

  # What a run under the decoys leaves when no filter stops it: the decoy's bytes staged at the path.
  def staged_decoy(path, bytes, *flags, config: [])
    original = File.binread(at(path))
    File.binwrite(at(path), bytes)
    git(*config, "add", *flags, path)
    File.binwrite(at(path), original)
  end

  # What a run leaves when the filter holds: the real blob staged, under the stand-in's size and times.
  def filtered_add(path, bytes)
    attributes = File.join(@root, ".git", "spec-attributes")
    File.write(attributes, "/#{path} filter=spec\n")
    staged_decoy(path, bytes, config: ["-c", "core.attributesFile=#{attributes}", "-c",
                                       "filter.spec.clean=git cat-file blob #{blob(path)}"])
  end

  def quiet?(*args) = system(SeedRepo::SCRUB, "git", "-C", @root, *args, "--quiet")

  # The git commands each checkout the guard makes runs, by subcommand.
  def git_runs
    [].tap do |runs|
      allow(Lain::Isolation::Checkout).to receive(:of).and_wrap_original do |of, *args, **options|
        of.call(*args, **options).tap do |checkout|
          allow(checkout).to(receive(:run).and_wrap_original do |run, *argv, **kw|
            (runs << argv.first) && run.call(*argv, **kw)
          end)
        end
      end
    end
  end

  describe "#settle" do
    it "restores an index entry the run staged a decoy into, and an empty mask's alike" do
      repo
      before = [blob(credentials), blob(".env")]
      held = guard
      staged_decoy(credentials, decoy)
      staged_decoy(".env", "")

      expect(held.settle).to have_attributes(restored: [".env", credentials], commits: [])
      expect([blob(credentials), blob(".env")]).to eq(before)
    end

    it "names each new commit that holds a decoy, with its path" do
      repo
      held = guard
      staged_decoy(credentials, decoy)
      git("commit", "-qm", "decoyed")
      decoyed = git("rev-parse", "HEAD").chomp
      write("app.rb", "more\n")
      git("add", "app.rb")
      git("commit", "-qm", "later")
      staged_decoy(".env", "")
      git("commit", "-qm", "emptied")

      settled = held.settle

      expect(settled.commits).to eq([[git("rev-parse", "HEAD").chomp, ".env"], [decoyed, credentials]])
      expect(settled.restored).to eq([".env", credentials])
    end

    it "leaves an entry the run changed to anything but a decoy, and names no commit that holds none" do
      repo
      held = guard
      staged_decoy(credentials, "rotated by the human\n")
      git("commit", "-qm", "rotated")

      expect(held.settle).to have_attributes(restored: [], commits: [])
    end

    it "names a tracked empty file that was already empty nowhere" do
      repo(".env" => "", "app.rb" => "app\n")
      held = guard
      git("commit", "-q", "--allow-empty", "-m", "nothing")

      expect(held.settle).to have_attributes(restored: [], commits: [])
    end

    it "resets a tracked mask that kept its blob once the index moved, so the host's git status reads it clean" do
      repo
      held = guard
      filtered_add(credentials, decoy)
      unsettled = git("status", "--porcelain", "--untracked-files=no")

      expect(held.settle).to have_attributes(restored: [], failed: [])
      # Before git status, which refreshes the index itself.
      expect([quiet?("diff-files"), quiet?("diff-index", "HEAD")]).to eq([true, true])
      expect([unsettled, git("status", "--porcelain", "--untracked-files=no")]).to eq([" M #{credentials}\n", ""])
    end

    it "keeps a mode staged while the call ran on a mask whose blob it kept" do
      repo
      held = guard
      git("update-index", "--chmod=+x", ".env")

      held.settle

      expect(git("ls-files", "-s", "--", ".env")).to start_with("100755 ")
    end

    # The undo is pasted into a shell from wherever the human is, so it names the repo and quotes the path.
    # @return [Array<String>] what the paste left in the directory it ran from
    def pasted(command)
      Dir.mktmpdir("lain-paste") do |elsewhere|
        system(SeedRepo::SCRUB, "bash", "-c", command, chdir: elsewhere, exception: true)
        Dir.children(elsewhere)
      end
    end

    def refused(path)
      held = guard(at(path) => "")
      yield
      FileUtils.touch(at(".git/index.lock"))
      held.settle
    ensure
      FileUtils.rm_f(at(".git/index.lock"))
    end

    it "names a restore git refused as failed, with a command that undoes it from any directory" do
      name = ".env.$(touch PWNED) x"
      repo(name => "SECRET=1\n", "app.rb" => "app\n")
      before = blob(name)

      settled = refused(name) { staged_decoy(name, "") }
      left = pasted(settled.failed.sole.last)

      expect(settled).to have_attributes(restored: [], failed: [[name, a_string_starting_with("git -C ")]])
      expect([blob(name), left, Dir.glob(File.join(@root, "**", "PWNED"))]).to eq([before, [], []])
    end

    it "names a removal git refused as failed, with a command that undoes it" do
      repo(credentials => "real\n", "app.rb" => "app\n")
      write(".env", "SECRET=1\n")

      settled = refused(".env") { staged_decoy(".env", "", "-f") }
      pasted(settled.failed.sole.last)

      expect(settled).to have_attributes(unstaged: [], failed: [[".env", a_string_including("rm --cached")]])
      expect(git("ls-files", "--", ".env")).to eq("")
    end

    # A raw control byte would reach the human's terminal, and invalid UTF-8 cannot sit in a note at all.
    { "a name holding ESC" => ".env.\e[31mred", "a name that is not UTF-8" => ".env.\xff".b }.each do |kind, name|
      it "quotes #{kind} in a printable undo that still restores the index when pasted" do
        repo(name => "SECRET=1\n", "app.rb" => "app\n")
        before = blob(name)

        command = refused(name) { staged_decoy(name, "") }.failed.sole.last
        pasted(command)

        expect(command).to be_valid_encoding.and(include("$'")).and(satisfy { !_1.match?(/[[:cntrl:]]/) })
        expect(blob(name)).to eq(before)
      end
    end

    it "writes a quote and a backslash in an ANSI-C quoted word as escapes, so they cannot end or bend it" do
      name = ".env.\e'\\x"
      repo(name => "SECRET=1\n", "app.rb" => "app\n")
      before = blob(name)

      command = refused(name) { staged_decoy(name, "") }.failed.sole.last
      pasted(command)

      expect(command).to include("\\x1b\\x27\\x5cx")
      expect(blob(name)).to eq(before)
    end

    it "words a refused undo for a path that is not ASCII in text a note can hold" do
      repo("clé.env" => "SECRET=1\n", "app.rb" => "app\n")

      path, command = refused("clé.env") { staged_decoy("clé.env", "") }.failed.sole

      expect([path, command].map(&:encoding)).to eq([Encoding::UTF_8] * 2)
      expect(format("%<path>s: %<command>s", path:, command:)).to include("clé.env")
    end

    it "takes back out of the index a stand-in staged for a mask git did not track, and names its commit" do
      repo(credentials => "real\n", "app.rb" => "app\n")
      write(".env", "SECRET=1\n")
      held = guard
      staged_decoy(".env", "", "-f")
      git("commit", "-qm", "added")

      settled = held.settle

      expect(settled).to have_attributes(unstaged: [".env"], commits: [[git("rev-parse", "HEAD").chomp, ".env"]])
      expect(git("ls-files", "--", ".env")).to eq("")
    end

    it "guards a project under a name that is not ASCII" do
      @root = at("café")
      FileUtils.mkdir_p(@root)
      repo
      held = guard
      staged_decoy(".env", "")

      expect(held.settle.restored).to eq([".env"])
    end

    it "runs no git to settle when neither the index nor HEAD moved, and lists once while they stay put" do
      repo
      runs = git_runs
      held = guard
      listed = runs.dup
      guard
      held.settle

      expect([listed.count("ls-files"), runs.size]).to eq([1, listed.size])
    end

    it "guards a repo with no commit yet by its index" do
      git("init", "-q")
      write(credentials, "real\n")
      git("add", credentials)
      before = blob(credentials)
      held = guard
      staged_decoy(credentials, decoy)
      git("commit", "-qm", "first")

      settled = held.settle

      expect(settled.commits).to eq([[git("rev-parse", "HEAD").chomp, credentials]])
      expect(blob(credentials)).to eq(before)
    end
  end

  describe "what it hands the run" do
    it "points git at an attributes file that filters each tracked mask back to its blob" do
      repo
      held = guard

      expect(held.binds.keys).to eq([described_class::ATTRIBUTES])
      expect(held.binds.values.sole).to eq(
        "/.env filter=laindecoy0\n/#{credentials} filter=laindecoy1\n"
      )
      expect(held.env).to eq(
        "GIT_CONFIG_COUNT" => "3",
        "GIT_CONFIG_KEY_0" => "core.attributesFile", "GIT_CONFIG_VALUE_0" => described_class::ATTRIBUTES,
        "GIT_CONFIG_KEY_1" => "filter.laindecoy0.clean", "GIT_CONFIG_VALUE_1" => "git cat-file blob #{blob(".env")}",
        "GIT_CONFIG_KEY_2" => "filter.laindecoy1.clean",
        "GIT_CONFIG_VALUE_2" => "git cat-file blob #{blob(credentials)}"
      )
    end

    it "keeps the user's own attributes file ahead of its lines, since its own path replaces it" do
      repo
      File.write(user = File.join(@root, ".git", "user-attributes"), "*.bin diff=hexdump\n")
      git("config", "core.attributesFile", user)

      expect(guard.binds.values.sole).to start_with("*.bin diff=hexdump\n/.env filter=laindecoy0\n")
    end

    it "keeps the attributes file git finds under XDG_CONFIG_HOME when none is configured" do
      config = File.join(@root, "xdg")
      FileUtils.mkdir_p(File.join(config, "git"))
      File.write(File.join(config, "git", "attributes"), "* text=auto eol=lf\n")
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("XDG_CONFIG_HOME", anything).and_return(config)
      repo

      expect(guard.binds.values.sole).to start_with("* text=auto eol=lf\n/.env")
    end

    it "names paths from the repo's top when the project is a directory inside it" do
      repo("web/#{credentials}" => "real\n")
      held = described_class.before(root: at("web"), masks: { at("web/#{credentials}") => decoy })

      expect(held.binds.values.sole).to eq("/web/#{credentials} filter=laindecoy0\n")
    end

    it "filters no path an attributes line cannot spell, which the check after the run still covers" do
      repo("odd name.key" => "real\n", "x[1].key" => "real\n")
      held = described_class.before(root: @root, masks: { at("odd name.key") => "", at("x[1].key") => "" })
      staged_decoy("odd name.key", "")

      expect(held.binds).to eq({})
      expect(held.settle.restored).to eq(["odd name.key"])
    end
  end

  describe "a guard with nothing to guard" do
    it "asks git once of a root that is no repository, until one appears" do
      runs = git_runs
      write(".env", "SECRET=1\n")
      2.times { guard(at(".env") => "") }
      asked = runs.size
      git("init", "-q")
      git("add", ".env")

      expect([asked, guard(at(".env") => "").env]).to match([1, a_hash_including("GIT_CONFIG_COUNT" => "2")])
    end

    it "sees a repository that appears above a root it found none at" do
      write("web/.env", "SECRET=1\n")
      in_web = -> { described_class.before(root: at("web"), masks: { at("web/.env") => "" }) }
      2.times { in_web.call }
      git("init", "-q")
      git("add", "web/.env")

      expect(in_web.call.env).to include("GIT_CONFIG_COUNT" => "2")
    end

    it "keeps no failure as no repository while a .git stands at the root, so the next guard covers it" do
      repo
      failing = true
      allow(Lain::Isolation::Checkout).to receive(:of).and_wrap_original do |of, *args, **options|
        of.call(*args, **options).tap do |checkout|
          allow(checkout).to(receive(:run).and_wrap_original do |run, *argv, **kw|
            raise Lain::Shell::Out::Timeout, "spec" if failing && argv.first == "rev-parse"

            run.call(*argv, **kw)
          end)
        end
      end
      first = guard
      failing = false

      expect([first.env, guard.env]).to match([{}, a_hash_including("GIT_CONFIG_COUNT" => "3")])
    end

    it "runs no git for masks outside the root, or none at all" do
      allow(Lain::Isolation::Checkout).to receive(:of).and_call_original
      [{ "/usr/bin/mise" => "" }, {}].each { described_class.before(root: @root, masks: _1) }

      expect(Lain::Isolation::Checkout).not_to have_received(:of)
    end

    it "hands the run nothing and settles to nothing for untracked masks, a non-repo, or no root" do
      held = [guard, described_class.before(root: nil, masks: { at(".env") => "" })]
      git("init", "-q")
      write(".env", "SECRET=1\n")
      held << guard

      expect(held.map { [_1.env, _1.binds, _1.settle.to_h] })
        .to all(eq([{}, {}, { restored: [], unstaged: [], failed: [], commits: [] }]))
    end
  end
end
