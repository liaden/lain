# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Lain::Sensitivity::Taint, :seam do
  subject(:taint) { described_class.new }

  around do |example|
    Dir.mktmpdir("lain-taint") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config/master.key"), "#{key}\n")
      File.write(File.join(@root, "README.md"), "a project\n")
      git("init", "-q")
      git("add", "README.md")
      git("commit", "-q", "-m", "seed")
      example.run
    ensure
      system("chmod", "-R", "u+rwx", @root) if @root
    end
  end

  # The mark's early margin would reach back over the fixture's own key, written a moment before.
  before { stub_const("#{described_class}::EARLY", 0) unless RSpec.current_example.metadata[:early] }

  let(:root) { @root }
  let(:key) { "4f9a2c7d1e8b3a6f0c5d2e9b7a4f1c3e" }
  let(:secrets) { Struct.new(:known) { def for_reads(_context) = known }.new([key]) }

  def path(name) = File.join(root, name)

  def git(*args)
    SeedRepo.git(@root, "-c", "user.name=s", "-c", "user.email=s@x", "-c", "commit.gpgsign=false",
                 "-c", "core.hooksPath=/dev/null", *args).stdout
  end

  def scanned
    since = described_class.mark(root)
    refs = described_class.refs(root)
    yield
    taint.scan(root:, since:, refs:, secrets:)
  end

  def copied(name)
    FileUtils.mkdir_p(File.dirname(path(name)))
    FileUtils.cp(path("config/master.key"), path(name))
  end

  def big = "#{"a" * (9 * 1024 * 1024)}#{key}"

  it "gates a copy of a known value, and holds it for every later ask" do
    scan = scanned { FileUtils.cp(path("config/master.key"), path("leaked.txt")) }

    expect(scan.gated).to eq([path("leaked.txt")])
    expect([taint.include?(path("leaked.txt")), taint.paths]).to eq([true, [path("leaked.txt")]])
  end

  it "gates a copy that kept its old mtime, which ctime still dates to the run" do
    scan = scanned do
      system("cp", "-p", path("config/master.key"), path("keep.txt"), exception: true)
      File.utime(Time.utc(2020, 1, 1), Time.utc(2020, 1, 1), path("keep.txt"))
    end

    expect(scan.gated).to include(path("keep.txt"))
  end

  it "gates an existing file the run appended a known value to" do
    FileUtils.mkdir_p(path("log"))
    File.write(path("log/development.log"), "booted\n")

    scan = scanned { File.write(path("log/development.log"), "leaf=#{key}\n", mode: "a") }

    expect(scan.gated).to eq([path("log/development.log")])
  end

  it "names a commit made during the run that holds a known value" do
    scan = scanned do
      git("add", "-f", "config/master.key")
      git("commit", "-q", "-m", "x")
    end

    commit = git("rev-parse", "HEAD").strip
    expect(scan.commits).to eq([[commit, "config/master.key"]])
  end

  it "gates a file too large to scan, unscanned" do
    scan = scanned { File.write(path("big.bin"), "a" * (9 * 1024 * 1024)) }

    expect([scan.gated, scan.unscanned]).to eq([[], [path("big.bin")]])
    expect(taint.include?(path("big.bin"))).to be(true)
  end

  it "leaves a file that holds no known value alone" do
    scan = scanned do
      FileUtils.mkdir_p(path("app/models"))
      File.write(path("app/models/post.rb"), "class Post; end\n")
    end

    expect([scan.gated, scan.unscanned, scan.unopened, scan.commits, scan.unscanned_commits, taint.paths])
      .to eq([[], [], [], [], [], []])
  end

  it "leaves a file older than the mark alone, whatever it holds" do
    File.write(path("old.txt"), key)

    expect(taint.scan(root:, since: Time.now + 60, refs: described_class.refs(root), secrets:).gated).to be_empty
  end

  it "marks the start on the project's own filesystem, 2 s early", :early do
    since = described_class.mark(root)
    File.write(path("now.txt"), "x")

    expect(File.lstat(path("now.txt")).ctime - since).to be_between(2, 3)
  end

  it "makes the mark in the project's git dir" do
    allow(Tempfile).to receive(:create).and_call_original

    described_class.mark(root)

    expect(Tempfile).to have_received(:create).with(anything, path(".git"))
  end

  it "gates a file the run left unreadable" do
    scan = scanned do
      copied("locked.txt")
      File.chmod(0o000, path("locked.txt"))
    end

    expect(scan.gated).to eq([path("locked.txt")])
  ensure
    File.chmod(0o600, path("locked.txt"))
  end

  it "catches a file written in the same clock tick as the mark" do
    caught = Array.new(200) do |index|
      name = "tick-#{index}.txt"
      since = described_class.mark(root)
      File.write(path(name), "x")
      File.lstat(path(name)).ctime >= since
    end

    expect(caught).to all(be(true))
  end

  describe "the trees the mask listing prunes" do
    %w[tmp/cache/x vendor/bundle/x node_modules/p/x target/debug/x .venv/x app/tmp/a/x __pycache__/x].each do |name|
      it "gates a copy written to #{name}" do
        expect(scanned { copied(name) }.gated).to eq([path(name)])
      end
    end

    it "gates a copy written into a nested repo" do
      scan = scanned do
        FileUtils.mkdir_p(path("sub"))
        SeedRepo.git(path("sub"), "init", "-q")
        copied("sub/leak")
      end

      expect(scan.gated).to eq([path("sub/leak")])
    end

    it "leaves a pruned tree's unchanged files unread, and holds nothing of it" do
      FileUtils.mkdir_p(path("vendor/bundle"))
      5.times { |index| File.write(path("vendor/bundle/f#{index}"), key) }

      expect(taint.scan(root:, since: Time.now + 60, refs: described_class.refs(root), secrets:).gated).to be_empty
      expect(taint.paths).to eq([])
    end

    it "walks a pruned tree to its end, and gates a key deep inside it" do
      scan = scanned do
        20.times do |package|
          FileUtils.mkdir_p(path("node_modules/big/p#{package}"))
          10.times { |file| File.write(path("node_modules/big/p#{package}/f#{file}.js"), "x") }
        end
        copied("node_modules/big/zz/a/b/c/d/leak")
      end

      expect([scan.gated, scan.unscanned]).to eq([[path("node_modules/big/zz/a/b/c/d/leak")], []])
    end

    it "still gates a key elsewhere when one entry vanishes mid-walk" do
      FileUtils.mkdir_p(path("node_modules/p/a"))
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(path("node_modules/p/a")).and_raise(Errno::ENOENT)

      scan = scanned { copied("node_modules/p/leak") }

      expect(scan.gated).to eq([path("node_modules/p/leak")])
    end

    it "reads nothing under a nested repo's git dir" do
      scan = scanned do
        FileUtils.mkdir_p(path("sub"))
        SeedRepo.git(path("sub"), "init", "-q")
        File.write(path("sub/.git/COMMIT_EDITMSG"), key)
      end

      expect(scan.gated).to be_empty
    end
  end

  describe "a directory the run made unreadable" do
    def hidden(dir)
      copied("#{dir}/leak")
      File.chmod(0o000, path(dir))
    end

    {
      "under node_modules" => "node_modules/p/hid",
      "in a listed directory" => "log/hid",
      "in a nested repo" => "sub/hid"
    }.each do |where, dir|
      it "gates it whole, #{where}" do
        FileUtils.mkdir_p(path("log"))
        File.write(path("log/app.log"), "booted\n")
        FileUtils.mkdir_p(path("sub"))
        SeedRepo.git(path("sub"), "init", "-q")

        scan = scanned do
          hidden(dir)
          FileUtils.mkdir_p(path("#{dir}den"))
          File.write(path("#{dir}den/f"), "x")
        end

        expect([scan.gated, scan.unopened]).to eq([[], [path(dir)]])
        expect([dir, "#{dir}/leak", "#{dir}den/f"].map { taint.include?(path(_1)) }).to eq([true, true, false])
      end
    end

    it "holds a directory it may list but not enter, and one it may enter but not list" do
      scan = scanned do
        %w[listable enterable].each { copied("node_modules/p/#{_1}/leak") }
        File.chmod(0o444, path("node_modules/p/listable"))
        File.chmod(0o111, path("node_modules/p/enterable"))
      end

      expect(scan.unopened).to contain_exactly(path("node_modules/p/listable"), path("node_modules/p/enterable"))
    end

    it "holds a listed file's directory whole when the run left it listable but not enterable" do
      scan = scanned do
        copied("log/ro/leak")
        File.chmod(0o444, path("log/ro"))
      end

      expect(scan.unopened).to eq([path("log/ro")])
    end

    it "holds a closed directory whatever language git speaks" do
      saved = ENV.to_h.slice("LANG", "LANGUAGE", "LC_ALL")
      ENV.update("LANG" => "en_US.UTF-8", "LANGUAGE" => "de")
      ENV.delete("LC_ALL")

      expect(scanned { hidden("log/hid") }.unopened).to eq([path("log/hid")])
    ensure
      %w[LANG LANGUAGE LC_ALL].each { ENV.delete(_1) }
      ENV.update(saved)
    end

    it "holds a closed directory whose name breaks git's warning across lines" do
      expect(scanned { hidden("a\nb") }.unopened).to eq([path("a\nb")])
    end

    it "leaves an unreadable directory alone that did not change in the run" do
      hidden("log/hid")

      scan = taint.scan(root:, since: Time.now + 60, refs: described_class.refs(root), secrets:)

      expect([scan.unopened, taint.paths]).to eq([[], []])
    end
  end

  describe "a path lain cannot reach" do
    def bad(name) = path(name).b.force_encoding(Lain::FILESYSTEM)

    it "holds a read-only directory whose name is not valid UTF-8, and still gates the rest" do
      scan = scanned do
        copied("leaked.txt")
        Dir.mkdir(bad("d\xff"))
        File.write(File.join(bad("d\xff"), "f"), "x")
        File.chmod(0o444, bad("d\xff"))
      end

      expect(scan.gated).to eq([path("leaked.txt")])
      expect(scan.unopened.map(&:b)).to eq([bad("d\xff").b])
    end

    %w[f node_modules/p/f].each do |name|
      it "gates a copy at #{name} with a name that is not valid UTF-8, and answers for it" do
        leak = bad("#{name}\xff")
        scan = scanned do
          FileUtils.mkdir_p(File.dirname(leak))
          FileUtils.cp(path("config/master.key"), leak)
        end

        expect(scan.gated.map(&:b)).to eq([leak.b])
        expect([taint.include?(leak), taint.include?(path("README.md"))]).to eq([true, false])
      end
    end

    it "holds a read-only directory over a child whose name is not valid UTF-8" do
      scan = scanned do
        copied("leaked.txt")
        FileUtils.mkdir_p(File.join(path("node_modules/ro"), "\xfe".b.force_encoding(Lain::FILESYSTEM)))
        File.chmod(0o444, path("node_modules/ro"))
      end

      expect([scan.gated, scan.unopened]).to eq([[path("leaked.txt")], [path("node_modules/ro")]])
    end

    it "holds nothing for a path that is gone by the time lain looks" do
      scan = scanned do
        FileUtils.mkdir_p(path("s"))
        File.write(path("s/gone"), "x")
        allow(File).to receive(:lstat).and_call_original
        allow(File).to receive(:lstat).with(path("s/gone")).and_raise(Errno::ENOENT)
      end

      expect(scan.unopened).to eq([])
    end

    it "stops its climb below the root, so a path it cannot reach never holds the whole project" do
      scan = scanned do
        copied("a/b/leak")
        allow(File).to receive(:lstat).and_wrap_original do |original, asked|
          asked.to_s.b.start_with?(path("a").b) ? raise(Errno::EACCES, asked) : original.call(asked)
        end
      end

      expect(scan.unopened).to eq([path("a/b/leak")])
      expect(taint.include?(path("README.md"))).to be(false)
    end

    it "answers for a held name tagged as bytes, asked in the filesystem's encoding" do
      taint.hold_whole(path("d\xff").b)

      expect([taint.include?(File.join(bad("d\xff"), "x")), taint.include?(path("d"))]).to eq([true, false])
    end

    # Under the C locale Ruby tags every name it reads as US-ASCII, which cannot be joined to a root whose own
    # path is not ASCII unless the join works on bytes. The root is made by hand: mktmpdir drops a prefix's á.
    it "scans a project whose own path is not ASCII under the C locale, in a child process" do
      script = <<~RUBY
        require "lain"
        require "tmpdir"
        key = ARGV.fetch(0)
        secrets = Struct.new(:known) { def for_reads(_context) = known }.new([key])
        Dir.mktmpdir("taint") do |dir|
          root = File.join(File.realpath(dir), "n\\u00e1").tap { Dir.mkdir(_1) }
          git = ->(*args) { system("git", "-C", root, "-c", "user.name=s", "-c", "user.email=s@x", *args, exception: true) }
          git.call("init", "-q")
          File.write(File.join(root, "README"), "x")
          git.call("add", "README")
          git.call("commit", "-qm", "seed")
          taint = Lain::Sensitivity::Taint.new
          since = Lain::Sensitivity::Taint.mark(root)
          refs = Lain::Sensitivity::Taint.refs(root)
          %W[node_modules/p/cl\\u00e9.txt staged/cl\\u00e9 cl\\u00e9.txt].each do |name|
            leak = File.join(root.b, name.b)
            FileUtils.mkdir_p(File.dirname(leak))
            File.binwrite(leak, key)
          end
          git.call("add", "staged")
          scan = taint.scan(root:, since:, refs:, secrets:)
          puts scan.gated.map { _1.b.delete_prefix(root.b) }.sort.join(",")
        end
      RUBY
      lib = File.expand_path("../../../lib", __dir__)
      out, err, status = Open3.capture3({ "LC_ALL" => "C", "LANG" => nil, "LANGUAGE" => nil },
                                        RbConfig.ruby, "-I", lib, "-rfileutils", "-e", script, key)

      expect([status.success?, err.lines.grep(/Error/)]).to eq([true, []])
      expect(out.lines.last.force_encoding(Encoding::UTF_8)).to eq("/clé.txt,/node_modules/p/clé.txt,/staged/clé\n")
    end

    describe "when the prune listing fails" do
      def failing_prune(&answer)
        allow(Lain::Confine::MaskList::Listing).to receive(:git).and_wrap_original do |original, *args|
          args.include?("--directory") ? yield : original.call(*args)
        end
      end

      it "walks the whole project when git answers with an error" do
        failing_prune { Lain::Isolation::Checkout::Done.refused("broken") }

        expect(scanned { copied("node_modules/p/leak") }.gated).to eq([path("node_modules/p/leak")])
      end

      it "walks the whole project when git times out" do
        failing_prune { raise Lain::Shell::Out::Timeout, "slow" }

        expect(scanned { copied("node_modules/p/leak") }.gated).to eq([path("node_modules/p/leak")])
      end
    end

    def committed_tree
      FileUtils.mkdir_p(path("a/b"))
      File.write(path("a/b/c.rb"), "1\n")
      git("add", "a")
      git("commit", "-qm", "a")
    end

    it "holds the tracked tree whose execute bit the run took, and still gates what it wrote elsewhere" do
      committed_tree
      scan = scanned do
        copied("leaked.txt")
        File.chmod(0o644, path("a"))
      end

      expect([scan.gated, scan.unopened]).to eq([[path("leaked.txt")], [path("a")]])
      expect(taint.include?(path("a/b/c.rb"))).to be(true)
    end

    it "holds a read-only grandparent of what the run wrote" do
      scanned do
        copied("a/b/leak")
        File.chmod(0o444, path("a"))
      end

      expect(taint.include?(path("a/b/leak"))).to be(true)
    end

    # Each mkdir runs in the last directory made, so the path grows past PATH_MAX one step at a time.
    def deep(top)
      step = "#{"d" * 200}/"
      system("bash", "-c", "mkdir -p #{top} && cd #{top} && for i in $(seq 1 25); do mkdir #{step} && cd #{step}; " \
                           "done && printf '#{key}' > leak", chdir: root, exception: true)
      File.join(root, top, step * 25, "leak")
    end

    %w[s node_modules/p].each do |top|
      it "holds the deepest directory it reaches above a key past PATH_MAX, under #{top}" do
        leak = nil
        scanned { leak = deep(top) }

        expect(leak.bytesize).to be > 4096
        expect(taint.include?(leak)).to be(true)
      ensure
        system("rm", "-rf", path(top.split("/").first))
      end
    end
  end

  describe "where a run hides a key outside a file's bytes" do
    def renamed
      FileUtils.mkdir_p(path("d"))
      File.write(path("d/f"), "plain\n")
      since = File.lstat(path("d/f")).ctime + 0.5
      refs = described_class.refs(root)
      # Past the mark, so only the rename moves a ctime.
      sleep 0.6
      yield
      taint.scan(root:, since:, refs:, secrets:)
    end

    it "gates a new file below an older directory whose name is a known value" do
      FileUtils.mkdir_p(path("d#{key}"))
      since = File.lstat(path("d#{key}")).ctime + 0.5
      refs = described_class.refs(root)
      sleep 0.6
      File.write(path("d#{key}/new"), "x")

      expect(taint.scan(root:, since:, refs:, secrets:).gated).to include(path("d#{key}/new"))
    end

    it "gates a named directory whose ctime lain cannot read" do
      scan = scanned do
        copied("#{key}/f")
        allow(File).to receive(:lstat).and_call_original
        allow(File).to receive(:lstat).with(path(key)).and_raise(Errno::EACCES)
      end

      expect(scan.gated).to include(path(key))
    end

    it "gates a directory the run renamed to a known value, though the file below it is older" do
      renamed { File.rename(path("d"), path(key)) }

      expect(taint.include?(path("#{key}/f"))).to be(true)
    end

    it "gates a directory named for a known value that the run moved an older directory into" do
      renamed do
        FileUtils.mkdir_p(path("k#{key}"))
        File.rename(path("d"), path("k#{key}/d"))
      end

      expect(taint.include?(path("k#{key}/d/f"))).to be(true)
    end

    it "gates a symlink whose target is a known value" do
      scan = scanned { File.symlink(key, path("link")) }

      expect(scan.gated).to eq([path("link")])
    end

    it "gates a file whose name is a known value" do
      scan = scanned { File.write(path(key), "x") }

      expect(scan.gated).to eq([path(key)])
    end

    it "gates what lies in a directory whose name is a known value" do
      scan = scanned do
        FileUtils.mkdir_p(path("d#{key}"))
        File.write(path("d#{key}/f"), "x")
      end

      expect(taint.include?(path("d#{key}/f"))).to be(true)
      expect(scan.gated).not_to be_empty
    end

    it "gates a named symlink in a pruned tree" do
      scan = scanned do
        FileUtils.mkdir_p(path("node_modules/p"))
        File.symlink(key, path("node_modules/p/link"))
        File.write(path("node_modules/p/#{key}"), "x")
      end

      expect(scan.gated).to contain_exactly(path("node_modules/p/link"), path("node_modules/p/#{key}"))
    end

    it "leaves a link and a name alone that are older than the mark" do
      File.symlink(key, path("link"))
      File.write(path(key), "x")

      expect(taint.scan(root:, since: Time.now + 60, refs: described_class.refs(root), secrets:).gated).to be_empty
    end
  end

  describe "what git holds" do
    def head = git("rev-parse", "HEAD").strip

    it "names no commit for a key committed before the run, when the run commits something else" do
      git("add", "-f", "config/master.key")
      git("commit", "-qm", "before")

      scan = scanned do
        File.write(path("app.rb"), "class App; end\n")
        git("add", "app.rb")
        git("commit", "-qm", "after")
      end

      expect(scan.commits).to eq([])
    end

    it "leaves the stash out" do
      scan = scanned do
        copied("st.txt")
        git("stash", "push", "-qu")
      end

      expect(scan.commits).to eq([])
    end

    it "gates a small staged blob by its index path once the run removed the file" do
      scan = scanned do
        copied("s.txt")
        git("add", "s.txt")
        File.delete(path("s.txt"))
      end

      expect(scan.gated).to eq([path("s.txt")])
    end

    it "names a commit on a side branch the run left" do
      scan = scanned do
        git("checkout", "-qb", "side")
        git("add", "-f", "config/master.key")
        git("commit", "-qm", "k")
        @side = head
        git("checkout", "-q", "-")
      end

      expect(scan.commits).to eq([[@side, "config/master.key"]])
    end

    it "names a commit a branch keeps after the run reset HEAD past it" do
      scan = scanned do
        git("add", "-f", "config/master.key")
        git("commit", "-qm", "k")
        @kept = head
        git("branch", "keep")
        git("reset", "-q", "--hard", "HEAD~")
      end

      expect(scan.commits).to eq([[@kept, "config/master.key"]])
    end

    it "names a blob the run wrote and tagged" do
      scan = scanned do
        @blob = git("hash-object", "-w", "config/master.key").strip
        git("tag", "leak", @blob)
      end

      expect(scan.commits).to eq([[@blob, nil]])
    end

    it "reports a blob too large to read in a new commit as unscanned" do
      scan = scanned do
        File.binwrite(path("big.bin"), big)
        git("add", "big.bin")
        git("commit", "-qm", "big")
        @big = head
        git("rm", "-q", "big.bin")
        git("commit", "-qm", "rm")
      end

      expect([scan.commits, scan.unscanned_commits]).to eq([[], [[@big, "big.bin"]]])
    end

    it "gates a staged blob too large to read by its index path, unscanned" do
      scan = scanned do
        File.binwrite(path("big.bin"), big)
        git("add", "big.bin")
        File.delete(path("big.bin"))
      end

      expect(scan.unscanned).to eq([path("big.bin")])
    end
  end

  it "scans a project git does not list by walking it" do
    FileUtils.rm_rf(path(".git"))

    scan = scanned { FileUtils.cp(path("config/master.key"), path("leaked.txt")) }

    expect(scan.gated).to eq([path("leaked.txt")])
  end

  it "holds every path it gated across scans" do
    scanned { copied("one.txt") }
    scanned { copied("two.txt") }

    expect(taint.paths).to eq([path("one.txt"), path("two.txt")])
  end

  it "refuses a scan into the empty taint every unwired reader shares" do
    expect { described_class::NONE.scan(root:, since: Time.now, refs: {}, secrets:) }.to raise_error(FrozenError)
    expect(described_class::NONE.paths).to eq([])
  end

  it "refuses to hold anything in the empty taint" do
    expect { described_class::NONE.hold_whole(root) }.to raise_error(FrozenError)
    expect(described_class::NONE.paths).to eq([])
  end
end
