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

  it "has a model-facing name and description" do
    expect(tool.name).to eq("ast_search")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
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
    expect(result.content).to match(/def \(/)
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

  it "caps output and reports the cap rather than flooding the result" do
    source = (1..5000).map { |i| "def method_#{i}\nend" }.join("\n")
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
end
