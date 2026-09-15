# frozen_string_literal: true

require "fileutils"
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

  it "reports a missing path as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope")

    result = tool.call(pattern: "needle", path: missing)

    expect(result).to have_attributes(is_error: true, content: /no such file or directory/)
  end

  it "reports an invalid regex pattern as an error Result rather than raising" do
    write("foo.rb", "needle\n")

    result = tool.call(pattern: "(unclosed", path: tmpdir)

    expect(result).to have_attributes(is_error: true, content: /invalid pattern/)
  end

  # The in-process walk is the DEFAULT, and this is the sharpest witness that
  # it ran: lookaround is exactly what the out-of-process engine refuses
  # (crates/lain-core builds its matcher on finite automata, by construction).
  # A green here with no client wired is the Ruby engine, not a coincidence.
  it "runs the Ruby engine when no core client is wired -- lookaround still compiles" do
    write("foo.rb", "needle in a haystack\n")

    result = tool.call(pattern: '(?=needle)\w+', path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to include("foo.rb:1:")
  end

  # The description is the text the MODEL reads to decide what to send, so it
  # may only promise what BOTH paths accept. Naming Ruby made the wired-client
  # path a trap: the model writes `(?<=x)y`, the daemon refuses it, and the
  # tool's own words are why.
  it "describes the dialect as the subset both paths accept, never as Ruby's" do
    expect(tool.description).to include("Backreferences", "lookaround")
    expect(tool.description).not_to include("Ruby")
    expect(tool.input_schema.to_s).not_to include("Ruby")
  end

  it "describes no-matches as a named, non-error outcome" do
    expect(tool.description).to match(/no match/i)
  end

  # The transport swap, without a daemon: everything about the core path that
  # is THIS side's responsibility -- the wire params, the label substitution,
  # the cap flag, and how each failure reaches the model -- is pinned here and
  # runs everywhere. spec/lain/core/grep_parity_spec.rb drives the real daemon.
  describe "with a core client wired" do
    let(:client) { instance_double(Lain::Core::Client) }
    let(:tool) { described_class.new(client:) }

    def reply(matches, capped: false) = { "matches" => matches, "capped" => capped }

    it "sends the resolved path, the pattern, and an explicit case flag" do
      allow(client).to receive(:call).and_return(reply([]))

      tool.call(pattern: "needle", path: tmpdir, case_insensitive: true)

      expect(client).to have_received(:call).with(
        "grep", [{ "pattern" => "needle", "path" => tmpdir,
                   "case_insensitive" => true, "respect_ignores" => false }]
      )
    end

    # The daemon CAN apply .gitignore/.ignore rules and the in-process walk
    # cannot, so leaving them on would make the same tool answer differently
    # depending on how it was wired. Sent explicitly rather than left to the
    # daemon's default, so this side's intent is auditable on the wire -- and
    # so a future flip of that default cannot change grep's behaviour silently.
    it "always tells the daemon NOT to honour VCS ignore rules" do
      allow(client).to receive(:call).and_return(reply([]))

      tool.call(pattern: "needle", path: tmpdir)

      expect(client).to have_received(:call).with(
        "grep", [hash_including("respect_ignores" => false)]
      )
    end

    it "sends case_insensitive as false, never nil, when the model omits it" do
      allow(client).to receive(:call).and_return(reply([]))

      tool.call(pattern: "needle", path: tmpdir)

      expect(client).to have_received(:call).with(
        "grep", [hash_including("case_insensitive" => false)]
      )
    end

    it "renders the daemon's matches as file:line:text, labels verbatim under a directory" do
      allow(client).to receive(:call).and_return(
        reply([{ "path" => "nested/bar.rb", "line_number" => 7, "line" => "the needle" }])
      )

      result = tool.call(pattern: "needle", path: tmpdir)

      expect(result.ok?).to be(true)
      expect(result.content).to eq("nested/bar.rb:7:the needle")
    end

    # The daemon labels a FILE target with the `path` param verbatim -- which
    # is the WorkerEnv-resolved absolute locator this side sends, not the
    # model's spelling. Substituting `display` back is what keeps the core
    # path's label byte-identical to the Ruby path's (grep_spec.rb:55).
    it "labels a single-file target with the model's spelling, not the path it sent" do
      path = write("README.md", "hello world\n")
      allow(client).to receive(:call).and_return(
        reply([{ "path" => path, "line_number" => 1, "line" => "hello world" }])
      )

      # The cwd arrives through the WorkerEnv rather than Dir.chdir: same
      # resolution, without a process-global mutation the parallel workers
      # would share.
      call = Lain::Tool::Invocation.new(
        context: Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: {}))
      )
      result = tool.call({ pattern: "hello", path: "README.md" }, call)

      expect(result.content).to eq("README.md:1:hello world")
    end

    it "reports the daemon's capped flag rather than recounting the rows" do
      rows = Array.new(Lain::Tools::Grep::MAX_MATCHES) { |i| { "path" => "a.rb", "line_number" => i + 1, "line" => "x" } }
      allow(client).to receive(:call).and_return(reply(rows, capped: true))

      result = tool.call(pattern: "x", path: tmpdir)

      expect(result.content.lines.grep(/^a\.rb:/).size).to eq(Lain::Tools::Grep::MAX_MATCHES)
      expect(result.content).to include("capped at #{Lain::Tools::Grep::MAX_MATCHES}")
    end

    it "turns a pattern the daemon's engine refuses into an error Result" do
      allow(client).to receive(:call)
        .and_raise(Lain::Core::Client::Refused, 'invalid pattern "(?=x)y": look-around ... is not supported')

      result = tool.call(pattern: "(?=x)y", path: tmpdir)

      expect(result).to have_attributes(is_error: true, content: /invalid pattern/)
      expect(result.content).to include("look-around")
    end

    # A refusal that is not about the pattern is a bug on THIS side (a param
    # spelled wrong, a daemon too old to know "grep"). Dressing it up as a
    # tool error would hand the model a message it cannot act on and hide the
    # defect; the handler turns the raise into an error Result anyway.
    it "re-raises a refusal that is not about the pattern" do
      allow(client).to receive(:call).and_raise(Lain::Core::Client::Refused, 'unknown method "grep"')

      expect { tool.call(pattern: "needle", path: tmpdir) }.to raise_error(Lain::Core::Client::Refused)
    end

    it "turns boundary death into an error Result naming it, never a raise past the loop" do
      allow(client).to receive(:call).and_raise(Lain::Core::Died.new("signal 9"))

      result = tool.call(pattern: "needle", path: tmpdir)

      expect(result).to be_error
      expect(result.content).to include("Lain::Core::Died", "signal 9")
    end

    it "still answers a missing path from this side, without a round trip" do
      allow(client).to receive(:call)

      result = tool.call(pattern: "needle", path: File.join(tmpdir, "nope"))

      expect(result).to have_attributes(is_error: true, content: /no such file or directory/)
      expect(client).not_to have_received(:call)
    end
  end
end
