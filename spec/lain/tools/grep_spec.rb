# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Lain::Tools::Grep do
  subject(:tool) { described_class.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  def write(relative_path, content)
    path = File.join(tmpdir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  it "returns matching lines with file:line locations and the matching text" do
    write("foo.rb", "one\ntwo\nthis has needle in it\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to include("foo.rb:3:")
    expect(result.content).to include("this has needle in it")
  end

  it "searches recursively under a directory" do
    write("nested/deep/bar.rb", "the needle is here\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.content).to include("nested/deep/bar.rb:1:")
  end

  it "searches a single file when path names a file, not a directory" do
    path = write("foo.rb", "no match here\nneedle on this line\n")

    result = tool.call(pattern: "needle", path:)

    expect(result.content).to include("#{path}:2:")
  end

  # Byte-identical label under the default WorkerEnv: a RELATIVE single-file
  # target labels its matches with the path exactly as the model spelled it
  # ("README.md:1:"), not the WorkerEnv-resolved absolute path -- probe
  # tmp/b1-probes/grep_label.rb.
  it "labels a relative single-file target with the verbatim path, not the resolved absolute" do
    write("README.md", "hello world\n")

    result = Dir.chdir(tmpdir) { tool.call(pattern: "hello", path: "README.md") }

    expect(result.content).to eq("README.md:1:hello world")
  end

  it "says a pattern matched nothing, rather than returning an empty string -- not an error" do
    write("foo.rb", "nothing interesting here\n")

    result = tool.call(pattern: "zzz", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).not_to eq("")
    expect(result.content).to include('"zzz"')
    expect(result.content).to match(/no match/i)
  end

  it "matches case-insensitively when asked" do
    write("foo.rb", "NEEDLE\n")

    result = tool.call(pattern: "needle", path: tmpdir, case_insensitive: true)

    expect(result.content).to include("foo.rb:1:NEEDLE")
  end

  it "supports Ruby regex syntax, not just literal substrings" do
    write("foo.rb", "value = 42\nvalue = abc\n")

    result = tool.call(pattern: 'value = \d+', path: tmpdir)

    expect(result.content).to include("foo.rb:1:")
    expect(result.content).not_to include("foo.rb:2:")
  end

  it "caps output and reports the cap rather than flooding the result" do
    write("many.rb", (["x"] * 5000).join("\n"))

    result = tool.call(pattern: "x", path: tmpdir)

    expect(result.ok?).to be(true)
    matched_lines = result.content.lines.grep(/^many\.rb:/)
    expect(matched_lines.size).to eq(Lain::Tools::Grep::MAX_MATCHES)
    expect(result.content).to include("capped at #{Lain::Tools::Grep::MAX_MATCHES}")
  end

  # Through the floor CLI::Wiring::BaseTools really builds, because the seam
  # that matters is the one a session assembles rather than the one a bare
  # `described_class.new` does -- matches bash_spec.rb's own use of the same
  # floor. Proves {Tools::Grep::WALK_CAP} reaches the model-visible content
  # through production wiring, not just through this file's own subject.
  it "still caps its output and says so when run through the production floor" do
    write("many.rb", (["x"] * 5000).join("\n"))
    floor = Lain::CLI::Wiring::BaseTools.build(Lain::Memory::Recorder.new)

    result = floor.find { |candidate| candidate.name == "grep" }.call({ pattern: "x", path: tmpdir })

    expect(result.content.lines.last).to eq("... capped at #{Lain::Tools::Grep::MAX_MATCHES} matches")
  end

  it "skips .git directories while walking a directory tree" do
    write(".git/objects/pack-junk", "needle\n")
    write("real.rb", "needle\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.content).not_to include(".git")
    expect(result.content).to include("real.rb:1:")
  end

  it "reads binary content as bytes rather than raising" do
    write("binary.dat", (0..255).map(&:chr).join)
    write("text.rb", "needle\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to include("text.rb:1:")
  end

  describe "a name that is not UTF-8" do
    before do
      File.binwrite(File.join(tmpdir, "bad\xFF.rb".b), "needle\n")
      write("good.rb", "needle\n")
    end

    it "searches the readable files and counts the one it skipped" do
      result = tool.call(pattern: "needle", path: tmpdir)

      expect(result).not_to be_error
      expect(result.content.split("\n")).to eq(["good.rb:1:needle", "1 file skipped: unreadable name"])
    end

    # "No matches" alone would read as "nothing under here says that", which
    # a file nobody searched cannot support.
    it "says so beside the no-match sentence too" do
      result = tool.call(pattern: "zzz", path: tmpdir)

      expect(result.content.split("\n"))
        .to eq([described_class.no_matches_message("zzz", tmpdir), "1 file skipped: unreadable name"])
    end

    it "counts in the plural" do
      File.binwrite(File.join(tmpdir, "worse\xFE.rb".b), "needle\n")

      expect(tool.call(pattern: "needle", path: tmpdir).content).to end_with("\n2 files skipped: unreadable name")
    end

    it "does not count an unreadable name under .git, which is never searched" do
      FileUtils.mkdir_p(File.join(tmpdir, ".git"))
      File.binwrite(File.join(tmpdir, ".git", "obj\xFF".b), "needle\n")

      expect(tool.call(pattern: "needle", path: tmpdir).content).to end_with("\n1 file skipped: unreadable name")
    end
  end

  # What is unreadable is a NAME the model would be shown, and a label is
  # relative to the root: a project whose own directory is not UTF-8 prints
  # every label as ordinary text, so no file in it is skipped.
  describe "a project under a directory whose name is not UTF-8" do
    it "returns the match and skips nothing" do
      project = File.join(tmpdir, "proj\xE9".b)
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "ok.rb"), "one\ntwo\nzzz\n")
      call = Lain::Tool::Invocation.new(
        context: Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: project, env: {}))
      )

      result = tool.call({ pattern: "zzz", path: "." }, call)

      expect(result.content).to eq("ok.rb:3:zzz")
    end
  end

  describe "a matched line that is not UTF-8" do
    it "returns it with each invalid byte escaped as text" do
      File.binwrite(File.join(tmpdir, "latin1.txt"), "caf\xE9 zzzmarker\nnothing\n".b)
      write("utf8.txt", "zzzmarker\n")

      result = tool.call(pattern: "zzzmarker", path: tmpdir)

      expect(result).not_to be_error
      expect(result.content).to eq("latin1.txt:1:caf\\xE9 zzzmarker\nutf8.txt:1:zzzmarker")
      expect(result.content).to be_valid_encoding
    end

    it "escapes a truncated sequence byte by byte" do
      File.binwrite(File.join(tmpdir, "cut.txt"), "a\xE3\x81 needle\n".b)

      expect(tool.call(pattern: "needle", path: tmpdir).content).to eq("cut.txt:1:a\\xE3\\x81 needle")
    end

    it "reads the rest of the file past a line that is not UTF-8" do
      File.binwrite(File.join(tmpdir, "bad.txt"), "needle one\n\xFF\xFE invalid\nneedle three\n".b)

      expect(tool.call(pattern: "needle", path: tmpdir).content).to eq("bad.txt:1:needle one\nbad.txt:3:needle three")
    end

    # The pattern is matched against the BYTES, so the escape is display only:
    # searching for the escape's own spelling finds nothing.
    it "does not match a pattern against the escape it printed" do
      File.binwrite(File.join(tmpdir, "latin1.txt"), "caf\xE9\n".b)

      expect(tool.call(pattern: "xE9", path: tmpdir).content).to eq(described_class.no_matches_message("xE9", tmpdir))
    end

    # One stray byte must not change how the line's VALID characters match:
    # `.` is still one character of `é`, never one of its two bytes.
    it "matches the valid characters of such a line as characters" do
      File.binwrite(File.join(tmpdir, "stray.txt"), "café \xFF zzz\n".b)

      expect(tool.call(pattern: "caf. ", path: tmpdir).content).to eq("stray.txt:1:café \\xFF zzz")
    end

    # A pattern with a non-ASCII character is a UTF-8 regexp, which Ruby
    # refuses to run against BINARY bytes at all.
    it "still searches such a line with a non-ASCII pattern, rather than raising" do
      File.binwrite(File.join(tmpdir, "mixed.txt"), "caf\xE9 naïve\n".b)

      result = tool.call(pattern: "naïve", path: tmpdir)

      expect(result).not_to be_error
      expect(result.content).to eq("mixed.txt:1:caf\\xE9 naïve")
    end
  end

  # Under LC_ALL=C a bare read tags every line US-ASCII, so a UTF-8 file's
  # first non-ASCII line fails to decode and the file's remaining matches were
  # dropped without a word. The mechanism, not the locale, is what is pinned.
  it "returns a UTF-8 line when the default external encoding is US-ASCII" do
    write("accented.txt", "café needle\n")
    previous = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII

    begin
      result = tool.call(pattern: "needle", path: tmpdir)
    ensure
      Encoding.default_external = previous
    end

    expect(result.content).to eq("accented.txt:1:café needle")
    expect(result.content.encoding).to eq(Encoding::UTF_8)
  end

  it_behaves_like "a tool answering a bad file target", :either do
    def call_with(path) = tool.call(pattern: "needle", path:)
  end

  it "reports an invalid regex pattern as an error Result rather than raising" do
    write("foo.rb", "needle\n")

    result = tool.call(pattern: "(unclosed", path: tmpdir)

    expect(result).to have_attributes(is_error: true, content: /invalid pattern/)
  end

  it "accepts a lookaround pattern and matches" do
    write("foo.rb", "foobar\nfoobaz\n")

    result = tool.call(pattern: "foo(?=bar)", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content.lines.grep(/^foo\.rb:/).size).to eq(1)
  end

  it "reports a pattern that backtracks past the timeout as a tool error, not a hang" do
    write("foo.rb", "#{"a" * 40}\n")

    # The backreference keeps Onigmo's linear-time memoization off, which `(a+)+$b` alone gets.
    result = Timeout.timeout(2) { tool.call(pattern: '(a+)+\1$b', path: tmpdir) }

    expect(result).to have_attributes(is_error: true, content: /hit the 1s regex timeout/)
    expect(result.content).not_to include("invalid pattern")
  end

  it "does not forbid in its description what the engine accepts" do
    expect(tool.description).not_to include("Backreferences", "lookaround")
    expect(tool.input_schema.to_s).not_to include("Backreferences", "lookaround")
  end

  it "describes no-matches as a named, non-error outcome" do
    expect(tool.description).to match(/no match/i)
  end

  # Two hundred matches is a row cap, not a byte one: one match inside a
  # minified line is a single row of hundreds of kilobytes.
  describe "holding the result to its byte ceiling" do
    let(:ceiling) { Lain::Tool::Bounds::CEILINGS.fetch("grep") }

    it "does not hand back a 400 KiB minified line, and says what it withheld" do
      write("bundle.min.js", "var a=1;#{"x" * 200_000}needle#{"y" * 200_000}\n")

      result = tool.call(pattern: "needle", path: tmpdir)

      expect(result.content.bytesize).to be <= ceiling
      expect(result.content).to include("truncated to 0 of 1 matches", "withholding", "#{ceiling}-byte ceiling")
      expect(result.content).to include("narrow the pattern or the path", "grep -oE")
      expect(result.content).not_to include("xxxx")
    end

    it "keeps whole matches up to the ceiling and says how many it kept" do
      write("log.txt", (1..200).map { |n| "hit #{n} #{"z" * 1000}\n" }.join)

      result = tool.call(pattern: "hit", path: File.join(tmpdir, "log.txt"))

      kept = result.content.lines.count { |line| line.start_with?("#{File.join(tmpdir, "log.txt")}:") }
      expect(result.content.bytesize).to be <= ceiling
      expect(kept).to be_between(1, 199)
      expect(result.content.lines.last).to start_with("... truncated to #{kept} of 200 matches, withholding ")
    end
  end

  describe "a tree git ignores part of" do
    def git_init(dir)
      _out, err, status = Open3.capture3(SeedRepo::SCRUB, "git", "init", "-q", chdir: dir)
      raise err unless status.success?
    end

    it "skips git-ignored build output" do
      git_init(tmpdir)
      write(".gitignore", "target/\n")
      write("target/out.txt", "needle\n")
      write("src/main.rs", "needle\n")

      content = tool.call(pattern: "needle", path: tmpdir).content

      expect(content).to include("src/main.rs:1:")
      expect(content).not_to include("target/")
    end

    it "skips and counts a name that is not valid UTF-8 inside a repository" do
      git_init(tmpdir)
      write("ok.txt", "needle\n")
      File.binwrite(File.join(tmpdir, "bad\xE9.txt".b), "needle\n")

      content = tool.call(pattern: "needle", path: tmpdir).content

      expect(content).to include("ok.txt:1:").and end_with("\n1 file skipped: unreadable name")
    end

    it "skips a nested repository's ignored tree when searching a plain parent" do
      git_init(File.join(tmpdir, "app").tap { FileUtils.mkdir_p(_1) })
      write("app/.gitignore", "target/\n")
      write("app/target/x.txt", "needle\n")
      write("app/src/y.txt", "needle\n")

      content = tool.call(pattern: "needle", path: tmpdir).content

      expect(content).to include("app/src/y.txt:1:")
      expect(content).not_to include("target/")
    end
  end

  describe "the walk limit" do
    def limited(entries: 10, bytes: 10_000_000)
      described_class.new(walk_limit: Lain::Tool::Bounds::WalkLimit.new(entries:, bytes:))
    end

    it "stops listing past the entry limit and names it beside the matches" do
      30.times { write("f#{format("%02d", _1)}.txt", "needle\n") }

      content = limited.call(pattern: "needle", path: tmpdir).content

      expect(content.lines.grep(/needle/).size).to eq(10)
      expect(content.lines.last).to include("10 entries").and include("narrow")
    end

    it "does not count a repository's ignored files held by a plain parent" do
      FileUtils.mkdir_p(File.join(tmpdir, "proj"))
      _out, err, status = Open3.capture3(SeedRepo::SCRUB, "git", "init", "-q", chdir: File.join(tmpdir, "proj"))
      raise err unless status.success?

      write("proj/.gitignore", "target/\n")
      300.times { write("proj/target/o#{_1}.o", "needle\n") }
      3.times { write("proj/src/s#{_1}.rb", "needle\n") }

      content = limited(entries: 100).call(pattern: "needle", path: tmpdir).content

      expect(content.lines.grep(%r{src/s\d.rb:1:}).size).to eq(3)
      expect(content).not_to include("entries")
    end

    it "stops reading past the byte limit and names it" do
      3.times { write("big#{_1}.txt", "needle\n#{"x" * 999_990}\n") }

      content = limited(bytes: 1_500_000).call(pattern: "needle", path: tmpdir).content

      expect(content.lines.grep(/needle/).size).to eq(1)
      expect(content.lines.last).to include("1500000 bytes")
    end

    it "names the byte limit in notices read before the matches are consumed" do
      3.times { write("big#{_1}.txt", "needle\n#{"x" * 999_990}\n") }
      files = described_class::Files.under(tmpdir)
      reads = files.within(Lain::Tool::Bounds::WalkLimit.new(entries: 10, bytes: 1_500_000))

      expect(reads.notices.last).to include("1500000 bytes")
    end

    it "adds no trailer to a walk under both limits" do
      3.times { write("s#{_1}.txt", "needle\n") }

      expect(limited.call(pattern: "needle", path: tmpdir).content).not_to include("narrow")
    end

    it "names the limit beside a no-match answer too" do
      30.times { write("f#{format("%02d", _1)}.txt", "hay\n") }

      expect(limited.call(pattern: "needle", path: tmpdir).content).to include("no matches").and include("10 entries")
    end
  end

  it_behaves_like "a walk run off the reactor", ->(dir) { { "pattern" => "needle", "path" => dir } }

  describe "running off the reactor" do
    include_context "with a slowed walk"

    def run_batch(*inputs)
      content = inputs.each_with_index.map do |input, index|
        { "type" => "tool_use", "id" => "tu_#{index}", "name" => "grep", "input" => input }
      end
      runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Live.new,
                                           toolset: Lain::Toolset.new([tool]))
      runner.run(Lain::Response.new(content:, stop_reason: :tool_use), context: nil)
    end

    # 50 ticks over a 1.5s walk, so one stall of the ticker under load cannot sink it.
    it "keeps a sibling fiber running through a batch of slow searches" do
      write("a.txt", "needle\n")
      slow_walks(1.5)
      blocks = nil

      ticks = ticks_while do
        blocks = run_batch({ "pattern" => "needle", "path" => tmpdir }, { "pattern" => "need", "path" => tmpdir })
      end

      expect(blocks.map { _1["content"] }).to eq(["a.txt:1:needle", "a.txt:1:needle"])
      expect(ticks).to be >= 50
    end

    it "hands an error raised inside the walk back as the tool's error, naming the path" do
      unreadable = write("a.txt", "needle\n")
      allow(Lain::FileWalk).to receive(:new).and_wrap_original do |original, **options|
        original.call(**options).tap { allow(_1).to receive(:each).and_raise(Errno::EACCES, unreadable) }
      end

      result = dispatch_call("grep", { "pattern" => "needle", "path" => tmpdir }, toolset: Lain::Toolset.new([tool]))

      expect(result.error?).to be(true)
      expect(result.content).to include("Permission denied").and include(unreadable)
    end

    describe "stopped while git lists the repository" do
      # A `git` that hangs on the listing, so the stop lands while the child runs.
      def hanging_git(dir)
        real = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { File.join(_1, "git") }
                  .find { File.executable?(_1) }
        File.join(dir, "git").tap do |path|
          File.write(path, "#!/bin/sh\ncase \"$*\" in *ls-files*) exec sleep 30;; esac\nexec #{real} \"$@\"\n")
          File.chmod(0o755, path)
        end
      end

      it "leaves no offload thread and no git child behind" do
        Open3.capture3(SeedRepo::SCRUB, "git", "init", "-q", chdir: tmpdir)
        write("a.txt", "needle\n")
        spawned = Thread::Queue.new
        allow(Process).to receive(:spawn).and_wrap_original do |spawn, *argv, **options|
          spawn.call(*argv, **options).tap { spawned << _1 }
        end
        before = Thread.list

        Dir.mktmpdir("lain-grep-bin") do |bin|
          hanging_git(bin)
          with_env("PATH" => [bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR)) do
            Sync do |task|
              search = task.async { tool.call(pattern: "needle", path: tmpdir) }
              child = spawned.pop
              search.stop
              search.wait

              expect(Thread.list - before).to be_empty
              expect { Process.waitpid(child, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
            end
          end
        end
      end
    end
  end
end
