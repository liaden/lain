# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Tools::AstSearch do
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

  it "searches a directory for a raw structural pattern, reporting file:line and captures" do
    write("foo.rb", "one\ntwo\ndef total(items)\n  items.sum\nend\n")

    result = tool.call(pattern: "def $NAME($$$A)", language: "ruby", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to include("foo.rb:3:")
    expect(result.content).to include("total")
  end

  it "searches a single file when path names a file, not a directory" do
    path = write("foo.rb", "def total(items)\n  items.sum\nend\n")

    result = tool.call(pattern: "def $NAME($$$A)", language: "ruby", path:)

    expect(result.content).to include("#{path}:1:")
  end

  it "restricts a directory walk to the requested language's file extensions" do
    write("foo.rb", "def total(items)\n  items.sum\nend\n")
    write("bar.py", "def total(items):\n    return sum(items)\n")

    result = tool.call(pattern: "def $NAME($$$A)", language: "ruby", path: tmpdir)

    expect(result.content).to include("foo.rb:1:")
    expect(result.content).not_to include("bar.py")
  end

  it "accepts a named catalog query in place of a raw pattern, merging every template" do
    write("foo.rb", <<~RUBY)
      # remember to record.save the row
      note = "call record.save when ready"
      record.save
      save
    RUBY

    result = tool.call(query: "method_call", name: "save", language: "ruby", path: tmpdir)

    expect(result.ok?).to be(true)
    # Line 3 (`record.save`) is matched by BOTH templates -- the receiver form
    # AND the bare form (which also matches the `save` identifier inside the
    # receiver call) -- but a call site is reported ONCE per line, so line 3
    # appears exactly once. Line 4 (bare `save`) once. Neither comment (line 1)
    # nor string literal (line 2) counts -- structural matching, not text search.
    matched_lines = result.content.lines.grep(/^foo\.rb:/).map { |line| line[/^foo\.rb:(\d+):/, 1].to_i }
    expect(matched_lines.sort).to eq([3, 4])
    expect(matched_lines).to eq(matched_lines.uniq) # no line double-reported
    expect(result.content).not_to include("foo.rb:1:")
    expect(result.content).not_to include("foo.rb:2:")
  end

  it "returns an ok, explicit no-matches body when a valid pattern matches nothing" do
    write("foo.rb", "one\ntwo\nthree\n")

    result = tool.call(pattern: "def $NAME($$$A)", language: "ruby", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to match(/no matches/i)
  end

  it "reports a malformed pattern as an error Result, distinct from a valid pattern with no matches" do
    write("foo.rb", "one\n")

    result = tool.call(pattern: "def (", language: "ruby", path: tmpdir)

    expect(result).to have_attributes(is_error: true)
    expect(result.content).to include("def (")
  end

  it "reports an unknown catalog query as an error Result" do
    write("foo.rb", "one\n")

    result = tool.call(query: "nonsense", language: "ruby", path: tmpdir)

    expect(result).to have_attributes(is_error: true, content: /nonsense/)
  end

  it "reports an unsupported language as an error Result" do
    write("foo.rb", "one\n")

    result = tool.call(pattern: "$A", language: "cobol", path: tmpdir)

    expect(result).to have_attributes(is_error: true, content: /cobol/)
  end

  it "reports a missing path as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope")

    result = tool.call(pattern: "$A", language: "ruby", path: missing)

    expect(result).to have_attributes(is_error: true, content: /no such file or directory/)
  end

  it "requires exactly one of pattern or query" do
    write("foo.rb", "one\n")

    neither = tool.call(language: "ruby", path: tmpdir)
    both = tool.call(pattern: "$A", query: "method_def", language: "ruby", path: tmpdir)

    expect(neither).to have_attributes(is_error: true)
    expect(both).to have_attributes(is_error: true)
  end

  # Sized from the constant, not a round number: the cap fires on the
  # MAX_MATCHES+1st match, so a handful past it proves everything a much larger
  # file would. It used to build 5000 methods for a cap of 200, and parsing that
  # tree cost +100MB RSS -- 92% of the whole suite's heap growth, in this one
  # example, retained for the rest of the run. That is what forced `rake pspec`
  # down to one worker fewer than the box has cores.
  it "caps output and reports the cap rather than flooding the result" do
    over_cap = described_class::MAX_MATCHES + 50
    source = (1..over_cap).map { |i| "def method_#{i}\nend" }.join("\n")
    write("many.rb", source)

    result = tool.call(pattern: "def $NAME", language: "ruby", path: tmpdir)

    expect(result.ok?).to be(true)
    matched_lines = result.content.lines.grep(/^many\.rb:/)
    expect(matched_lines.size).to eq(described_class::MAX_MATCHES)
    expect(result.content).to include("capped at #{described_class::MAX_MATCHES}")
  end

  it "skips .git directories while walking a directory tree" do
    write(".git/objects/pack-junk", "def total(x)\nend\n")
    write("real.rb", "def total(x)\nend\n")

    result = tool.call(pattern: "def $NAME($$$A)", language: "ruby", path: tmpdir)

    expect(result.content).not_to include(".git")
    expect(result.content).to include("real.rb:1:")
  end

  # A `.rb` file whose bytes are not valid UTF-8 is refused at the ext boundary
  # (ext/lain/src/read_text.rs), because byte offsets that index a transcoded
  # copy are worse than no answer. It must reach the model as an error Result
  # naming the file -- not as a raise out of #call, and not as a silent skip
  # that reads identically to "your pattern matched nothing".
  describe "a source file whose bytes are not valid UTF-8" do
    def write_binary(relative_path, bytes)
      path = File.join(tmpdir, relative_path)
      File.binwrite(path, bytes)
      path
    end

    it "reports the encoding problem as an error Result naming the file" do
      path = write_binary("bad.rb", "# caf\xe9 \xff\xfe\ndef total(x)\nend\n")

      result = tool.call(pattern: "def $NAME($$$A)", language: "ruby", path:)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include(path).and include("not valid UTF-8")
    end

    it "names the offending file when it turns up in a directory walk" do
      write_binary("bad.rb", "# \xff\xfe\n")

      result = tool.call(pattern: "def $NAME($$$A)", language: "ruby", path: tmpdir)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("bad.rb").and include("not valid UTF-8")
    end

    # The refusals above are only useful if they are TRUE. A bare File.read tags
    # its result with Encoding.default_external, which a C locale makes US-ASCII
    # -- so under `LC_ALL=C` every ordinary UTF-8 source file would be refused
    # with a message saying it is not UTF-8, which it is. A model given that has
    # no move. This pins the mechanism (the read names its encoding) rather than
    # the locale, which is the part the tool actually controls.
    it "searches an ordinary UTF-8 file even when the default external encoding is US-ASCII" do
      write("accented.rb", "# a café comment\ndef total(items)\n  items.sum\nend\n")
      previous = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII

      begin
        result = tool.call(pattern: "def $NAME($$$A)", language: "ruby", path: tmpdir)
      ensure
        Encoding.default_external = previous
      end

      expect(result).to have_attributes(ok?: true)
      expect(result.content).to include("accented.rb:2:")
    end
  end

  describe "resolving paths against the session WorkerEnv" do
    let(:pattern) { "def $NAME($$$A)" }

    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    end

    def session_at(cwd)
      Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd:, env: ENV.to_h))
    end

    it "resolves a relative path under the injected WorkerEnv cwd" do
      write("foo.rb", "def total(items)\n  items.sum\nend\n")

      result = tool.call({ pattern:, language: "ruby", path: "." }, invocation_with(session_at(tmpdir)))

      expect(result.content).to include("foo.rb:1:")
    end

    it "honors an absolute path as given, whatever the WorkerEnv cwd" do
      write("foo.rb", "def total(items)\n  items.sum\nend\n")

      Dir.mktmpdir do |elsewhere|
        result = tool.call({ pattern:, language: "ruby", path: tmpdir }, invocation_with(session_at(elsewhere)))

        expect(result.content).to include("foo.rb:1:")
      end
    end

    it "resolves a relative path against the process cwd under the default WorkerEnv" do
      write("foo.rb", "def total(items)\n  items.sum\nend\n")

      Dir.chdir(tmpdir) do
        result = tool.call({ pattern:, language: "ruby", path: "." }, invocation_with(Lain::Session.new))

        expect(result.content).to include("foo.rb:1:")
      end
    end

    # The resolved path is the FILESYSTEM locator only. Model-facing output
    # keeps the model's own spelling, exactly as {Grep} does: a single-file
    # target labels its hits with the given path, and the no-matches line names
    # the given path -- neither leaks the WorkerEnv-resolved absolute path.
    it "labels a single-file hit with the given spelling, not the resolved path" do
      write("foo.rb", "def total(items)\n  items.sum\nend\n")

      result = tool.call({ pattern:, language: "ruby", path: "foo.rb" }, invocation_with(session_at(tmpdir)))

      expect(result.content).to include("foo.rb:1:")
      expect(result.content).not_to include(tmpdir)
    end

    it "names the given path, not the resolved one, in the no-matches line" do
      write("foo.rb", "one\ntwo\nthree\n")

      result = tool.call({ pattern:, language: "ruby", path: "." }, invocation_with(session_at(tmpdir)))

      expect(result.content).to eq(%(no matches for "def $NAME($$$A)" under .))
    end

    # An ERROR is a diagnostic, not model-facing content: it names the resolved
    # path so a wrong-directory read says exactly where it looked. Same split as
    # {Grep}, whose #problem_with also takes the resolved locator.
    it "names the resolved path in an error Result" do
      result = tool.call({ pattern:, language: "ruby", path: "nope" }, invocation_with(session_at(tmpdir)))

      expect(result).to have_attributes(is_error: true, content: "no such file or directory: #{tmpdir}/nope")
    end
  end
end
