# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::FileFacts::Live do
  subject(:facts) { Lain::FileFacts::LIVE }

  around do |example|
    Dir.mktmpdir("lain-file-facts") do |dir|
      @base = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@base, "src"))
      File.write(File.join(@base, "src", "a.rb"), "x")
      File.symlink("src/a.rb", File.join(@base, "link.rb"))
      File.symlink("missing", File.join(@base, "gone"))
      example.run
    end
  end

  def at(*parts) = File.join(@base, *parts)

  it "is the default every reading site falls back to" do
    expect(facts).to be_a(described_class).and be_frozen
  end

  it "answers each question as File and Dir do" do
    paths = [at("src"), at("src", "a.rb"), at("link.rb"), at("gone"), at("absent")]

    expect(paths.map { facts.exist?(_1) }).to eq(paths.map { File.exist?(_1) })
    expect(paths.map { facts.file?(_1) }).to eq(paths.map { File.file?(_1) })
    expect(paths.map { facts.directory?(_1) }).to eq(paths.map { File.directory?(_1) })
    expect(paths.map { facts.symlink?(_1) }).to eq(paths.map { File.symlink?(_1) })
  end

  it "resolves and reads links as File does, raising where File raises" do
    expect(facts.realpath(at("link.rb"))).to eq(File.realpath(at("link.rb")))
    expect(facts.readlink(at("gone"))).to eq(File.readlink(at("gone")))
    expect { facts.realpath(at("gone")) }.to raise_error(Errno::ENOENT)
  end

  it "lists a directory and matches a pattern as Dir does" do
    expect(facts.enum_for(:each_child, @base).to_a.sort).to eq(Dir.children(@base).sort)
    expect(facts.glob("src/*.rb", base: @base)).to eq(Dir.glob("src/*.rb", base: @base))
  end
end
