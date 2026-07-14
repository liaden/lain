# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Tools::ListFiles do
  subject(:tool) { described_class.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  def touch(*parts)
    path = File.join(tmpdir, *parts)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "")
    path
  end

  it "has a model-facing name and description" do
    expect(tool.name).to eq("list_files")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "lists the immediate entries of a directory, sorted" do
    touch("b.txt")
    touch("a.txt")
    FileUtils.mkdir_p(File.join(tmpdir, "sub"))

    result = tool.call(path: tmpdir)
    expect(result.content.split("\n")).to eq(%w[a.txt b.txt sub])
  end

  it "does not descend into subdirectories unless asked" do
    touch("top.txt")
    touch("sub", "nested.txt")

    result = tool.call(path: tmpdir)
    expect(result.content.split("\n")).to eq(%w[sub top.txt])
  end

  it "descends into subdirectories when recursive: true" do
    touch("top.txt")
    touch("sub", "nested.txt")

    result = tool.call(path: tmpdir, recursive: true)
    expect(result.content.split("\n")).to include("sub/nested.txt", "top.txt")
  end

  it "reports a missing directory as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope")
    result = tool.call(path: missing)
    expect(result).to have_attributes(is_error: true, content: /no such directory/)
  end

  it "reports a file (not a directory) as an error Result rather than raising" do
    path = touch("a_file.txt")
    result = tool.call(path:)
    expect(result).to have_attributes(is_error: true, content: /not a directory/)
  end

  it "reports an unreadable directory as an error Result rather than raising" do
    sub = File.join(tmpdir, "locked")
    FileUtils.mkdir_p(sub)
    File.chmod(0o000, sub)
    result = tool.call(path: sub)
    expect(result).to have_attributes(is_error: true, content: /not readable/)
  ensure
    File.chmod(0o700, sub) if sub && File.exist?(sub)
  end
end
