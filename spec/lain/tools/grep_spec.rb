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

  it "has a model-facing name and description" do
    expect(tool.name).to eq("grep")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
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

  it "returns an ok, empty result when nothing matches -- not an error" do
    write("foo.rb", "nothing interesting here\n")

    result = tool.call(pattern: "zzz", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to eq("")
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

  it "skips .git directories while walking a directory tree" do
    write(".git/objects/pack-junk", "needle\n")
    write("real.rb", "needle\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.content).not_to include(".git")
    expect(result.content).to include("real.rb:1:")
  end

  it "skips unreadable (binary) content rather than raising" do
    write("binary.dat", (0..255).map(&:chr).join)
    write("text.rb", "needle\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to include("text.rb:1:")
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
end
