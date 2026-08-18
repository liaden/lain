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

  it "returns matches in deterministic sorted order" do
    touch("b.rb")
    touch("a.rb")
    touch("sub", "c.rb")
    touch("d.txt")

    result = tool.call(pattern: "**/*.rb", path: tmpdir)
    expect(result.content.split("\n")).to eq(%w[a.rb b.rb sub/c.rb])
  end

  it "says a pattern matched nothing, rather than returning an empty string" do
    touch("a.rb")

    result = tool.call(pattern: "*.nope", path: tmpdir)

    expect(result.is_error).to be(false)
    expect(result.content).not_to eq("")
    expect(result.content).to include('"*.nope"')
    expect(result.content).to match(/no match/i)
  end

  it "describes no-matches as a named, non-error outcome" do
    expect(tool.description).to match(/no match/i)
  end

  it "defaults the base path to the current directory" do
    Dir.chdir(tmpdir) do
      touch("only.rb")
      result = tool.call(pattern: "*.rb")
      expect(result.content.split("\n")).to eq(%w[only.rb])
    end
  end
end
