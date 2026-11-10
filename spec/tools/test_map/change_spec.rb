# frozen_string_literal: true

require "open3"
require "tmpdir"
require "rbconfig"
require_relative "../../../tools/test_map/change"

RSpec.describe TestMap::Change do
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t",
      "GIT_COMMITTER_EMAIL" => "t@t" }
  end
  let(:old_source) do
    <<~RUBY
      # frozen_string_literal: true

      LIMIT = 3

      class X
        def other
          1
        end

        def call
          a = 1
          b = 2
          c = 3
          a + b + c
        end
      end
    RUBY
  end

  def git(dir, *args)
    out, err, st = Open3.capture3(identity.merge(SeedRepo::SCRUB), "git", "-C", dir, *args)
    raise err unless st.success?

    out.strip
  end

  def write(dir, path, text)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def init_repo(dir, files)
    git(dir, "init", "-q")
    files.each { |path, text| write(dir, path, text) }
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "base")
  end

  def tree_after(dir)
    yield
    git(dir, "add", "-A")
    git(dir, "write-tree")
  end

  def changed(dir, old_tree, new_tree)
    described_class.between(old_tree, new_tree, repo: dir).to_h { |file| [file.path, file] }
  end

  describe ".between" do
    it "reports a change inside a method as a method hunk with the def's span" do
      Dir.mktmpdir do |dir|
        init_repo(dir, "lib/x.rb" => old_source)
        old_tree = git(dir, "rev-parse", "HEAD^{tree}")
        new_tree = tree_after(dir) { write(dir, "lib/x.rb", old_source.sub("b = 2", "b = 20")) }
        file = changed(dir, old_tree, new_tree).fetch("lib/x.rb")
        expect([file.status, file.hunks]).to eq([:modified, [described_class::Hunk.new(:method, 10..15)]])
      end
    end

    it "reports a pure addition inside a method as a method hunk" do
      Dir.mktmpdir do |dir|
        init_repo(dir, "lib/x.rb" => old_source)
        old_tree = git(dir, "rev-parse", "HEAD^{tree}")
        new_tree = tree_after(dir) { write(dir, "lib/x.rb", old_source.sub("  b = 2\n", "  b = 2\n    z = 0\n")) }
        expect(changed(dir, old_tree, new_tree).fetch("lib/x.rb").hunks)
          .to eq([described_class::Hunk.new(:method, 10..15)])
      end
    end

    it "reports a change to a constant as a file hunk" do
      Dir.mktmpdir do |dir|
        init_repo(dir, "lib/x.rb" => old_source)
        old_tree = git(dir, "rev-parse", "HEAD^{tree}")
        new_tree = tree_after(dir) { write(dir, "lib/x.rb", old_source.sub("LIMIT = 3", "LIMIT = 4")) }
        expect(changed(dir, old_tree, new_tree).fetch("lib/x.rb").hunks)
          .to eq([described_class::Hunk.new(:file, 3..3)])
      end
    end

    it "reports a change spanning two methods as a file hunk" do
      Dir.mktmpdir do |dir|
        init_repo(dir, "lib/x.rb" => old_source)
        old_tree = git(dir, "rev-parse", "HEAD^{tree}")
        new_tree = tree_after(dir) { write(dir, "lib/x.rb", old_source.sub("  end\n\n  def call\n", "")) }
        expect(changed(dir, old_tree, new_tree).fetch("lib/x.rb").hunks.map(&:kind)).to eq([:file])
      end
    end

    def hunks_for(dir, source, &edit)
      init_repo(dir, "lib/x.rb" => source)
      old_tree = git(dir, "rev-parse", "HEAD^{tree}")
      new_tree = tree_after(dir) { write(dir, "lib/x.rb", yield(source)) }
      changed(dir, old_tree, new_tree).fetch("lib/x.rb").hunks
    end

    it "reports an insertion right after a def's end line as a file hunk" do
      Dir.mktmpdir do |dir|
        hunks = hunks_for(dir, old_source) do |src|
          src.sub("    a + b + c\n  end\n", "    a + b + c\n  end\n  Z = 1\n")
        end
        expect(hunks).to eq([described_class::Hunk.new(:file, 15..15)])
      end
    end

    it "reports an insertion between two defs as a file hunk" do
      Dir.mktmpdir do |dir|
        hunks = hunks_for(dir, old_source) { |src| src.sub("    1\n  end\n", "    1\n  end\n  Z = 1\n") }
        expect(hunks).to eq([described_class::Hunk.new(:file, 8..8)])
      end
    end

    it "reports a class-body line between defs as a file hunk" do
      source = old_source.sub("  def call", "  MID = 1\n  def call")
      Dir.mktmpdir do |dir|
        hunks = hunks_for(dir, source) { |src| src.sub("MID = 1", "MID = 2") }
        expect(hunks).to eq([described_class::Hunk.new(:file, 10..10)])
      end
    end

    it "gives a change in a nested def the inner def's span" do
      source = "class X\n  def outer\n    def inner\n      1\n    end\n    2\n  end\nend\n"
      Dir.mktmpdir do |dir|
        hunks = hunks_for(dir, source) { |src| src.sub("      1\n", "      9\n") }
        expect(hunks).to eq([described_class::Hunk.new(:method, 3..5)])
      end
    end

    it "gives a change in an endless def that def's span" do
      source = "class X\n  def one = 1\n\n  def two\n    2\n  end\nend\n"
      Dir.mktmpdir do |dir|
        hunks = hunks_for(dir, source) { |src| src.sub("def one = 1", "def one = 5") }
        expect(hunks).to eq([described_class::Hunk.new(:method, 2..2)])
      end
    end

    it "gives a change in a def inside a Data.define block that def's span" do
      source = "P = Data.define(:a) do\n  def twice\n    a * 2\n  end\nend\n"
      Dir.mktmpdir do |dir|
        hunks = hunks_for(dir, source) { |src| src.sub("a * 2", "a * 3") }
        expect(hunks).to eq([described_class::Hunk.new(:method, 2..4)])
      end
    end

    it "handles paths git would C-quote" do
      Dir.mktmpdir do |dir|
        names = ["lib/q\"t.rb", "lib/tab\there.rb", "lib/back\\slash.rb"]
        init_repo(dir, names.to_h { |name| [name, "A = 1\n"] })
        old_tree = git(dir, "rev-parse", "HEAD^{tree}")
        new_tree = tree_after(dir) { names.each { |name| write(dir, name, "A = 2\n") } }
        files = changed(dir, old_tree, new_tree)
        expect(files.transform_values { |file| file.hunks.map(&:kind) }).to eq(names.to_h { |name| [name, [:file]] })
      end
    end

    it "gives a glob-named file only its own hunks" do
      Dir.mktmpdir do |dir|
        init_repo(dir, "lib/a[1].rb" => "A = 1\nB = 1\n", "lib/a1.rb" => "A = 1\nB = 1\n")
        old_tree = git(dir, "rev-parse", "HEAD^{tree}")
        new_tree = tree_after(dir) do
          write(dir, "lib/a[1].rb", "A = 2\nB = 1\n")
          write(dir, "lib/a1.rb", "A = 1\nB = 2\n")
        end
        files = changed(dir, old_tree, new_tree)
        expect(files.transform_values(&:hunks)).to eq(
          "lib/a[1].rb" => [described_class::Hunk.new(:file, 1..1)],
          "lib/a1.rb" => [described_class::Hunk.new(:file, 2..2)]
        )
      end
    end

    it "reads a non-ASCII diff when the process encoding is not UTF-8" do
      Dir.mktmpdir do |dir|
        init_repo(dir, "lib/\u00e9.rb" => "A = 1\n# \u00e9\n")
        old_tree = git(dir, "rev-parse", "HEAD^{tree}")
        new_tree = tree_after(dir) { write(dir, "lib/\u00e9.rb", "A = 2\n# \u00e9\n") }
        saved = Encoding.default_external
        Encoding.default_external = Encoding::US_ASCII
        begin
          expect(changed(dir, old_tree, new_tree).keys).to eq(["lib/\u00e9.rb"])
        ensure
          Encoding.default_external = saved
        end
      end
    end

    it "reports a deletion as a deleted path and an addition as an added path" do
      Dir.mktmpdir do |dir|
        init_repo(dir, "lib/x.rb" => old_source, "README" => "hi\n")
        old_tree = git(dir, "rev-parse", "HEAD^{tree}")
        new_tree = tree_after(dir) do
          FileUtils.rm(File.join(dir, "lib/x.rb"))
          write(dir, "lib/y.rb", "Y = 1\n")
          write(dir, "README", "hello\n")
        end
        files = changed(dir, old_tree, new_tree)
        expect(files.transform_values { |file| [file.status, file.hunks] })
          .to eq("README" => [:modified, []], "lib/x.rb" => [:deleted, []], "lib/y.rb" => [:added, []])
      end
    end
  end

  describe ".staged_tree" do
    let(:hook) do
      ruby = RbConfig.ruby
      lib = File.expand_path("../../../tools/test_map/change.rb", __dir__)
      <<~SH
        #!/bin/sh
        env -u RUBYOPT -u RUBYLIB #{ruby} -e '
          require ARGV[0]
          tree = TestMap::Change.staged_tree(repo: Dir.pwd)
          File.write("../seen.txt", TestMap::Git.run("diff", "--name-only", "HEAD", tree, repo: Dir.pwd))
        ' #{lib}
      SH
    end

    def hooked_repo(dir)
      init_repo(dir, "a.txt" => "a\n", "b.txt" => "b\n")
      hook_path = File.join(dir, ".git", "hooks", "pre-commit")
      File.write(hook_path, hook)
      FileUtils.chmod(0o755, hook_path)
      write(dir, "a.txt", "a2\n")
      write(dir, "b.txt", "b2\n")
    end

    it "sees a modified tracked file under git commit -a" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "repo")
        Dir.mkdir(dir)
        hooked_repo(dir)
        git(dir, "commit", "-q", "-a", "-m", "m")
        expect(File.read(File.join(root, "seen.txt"))).to eq("a.txt\nb.txt\n")
      end
    end

    it "sees only the named file under git commit with a path" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "repo")
        Dir.mkdir(dir)
        hooked_repo(dir)
        git(dir, "commit", "-q", "-m", "m", "a.txt")
        expect(File.read(File.join(root, "seen.txt"))).to eq("a.txt\n")
      end
    end
  end
end
