# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Tools::Glob do
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
    expect(tool.name).to eq("glob")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "returns matches in deterministic sorted order" do
    touch("b.rb")
    touch("a.rb")
    touch("sub", "c.rb")
    touch("d.txt")

    result = tool.call(pattern: "**/*.rb", path: tmpdir)
    expect(result.content.split("\n")).to eq(%w[a.rb b.rb sub/c.rb])
  end

  it "returns an empty, non-error result when nothing matches" do
    touch("a.rb")

    result = tool.call(pattern: "*.nope", path: tmpdir)
    expect(result).to have_attributes(is_error: false, content: "")
  end

  it "defaults the base path to the current directory" do
    Dir.chdir(tmpdir) do
      touch("only.rb")
      result = tool.call(pattern: "*.rb")
      expect(result.content.split("\n")).to eq(%w[only.rb])
    end
  end
end
