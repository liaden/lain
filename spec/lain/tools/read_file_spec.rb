# frozen_string_literal: true

require "tmpdir"
require "lain/tools/read_file"

RSpec.describe Lain::Tools::ReadFile do
  subject(:tool) { described_class.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  def write(name, content)
    path = File.join(tmpdir, name)
    File.write(path, content)
    path
  end

  it "has a model-facing name and description" do
    expect(tool.name).to eq("read_file")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "reads a file's full contents" do
    path = write("hello.txt", "hello\nworld\n")
    expect(tool.call(path: path)).to eq(Lain::Tool::Result.ok("hello\nworld\n"))
  end

  it "reports a missing file as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope.txt")
    result = tool.call(path: missing)
    expect(result).to have_attributes(is_error: true)
    expect(result.content).to match(/no such file/)
  end

  it "reports a directory as an error Result rather than raising" do
    result = tool.call(path: tmpdir)
    expect(result).to have_attributes(is_error: true, content: /is a directory/)
  end

  it "reports an unreadable file as an error Result rather than raising" do
    path = write("secret.txt", "shh")
    File.chmod(0o000, path)
    result = tool.call(path: path)
    expect(result).to have_attributes(is_error: true, content: /not readable/)
  ensure
    File.chmod(0o600, path) if path && File.exist?(path)
  end

  it "does not care about the invocation it is handed" do
    path = write("a.txt", "a")
    invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    expect(tool.call({ path: path }, invocation)).to eq(Lain::Tool::Result.ok("a"))
  end
end
