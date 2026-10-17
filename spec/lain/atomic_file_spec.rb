# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::AtomicFile, :seam do
  around do |example|
    Dir.mktmpdir("lain-atomic-file") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, "nested", "out.txt") }

  it "creates the parent and writes the bytes" do
    described_class.write(path, "hello")

    expect(File.binread(path)).to eq("hello")
  end

  it "replaces an existing file whole" do
    described_class.write(path, "old old old")
    described_class.write(path, "new")

    expect(File.binread(path)).to eq("new")
  end

  it "leaves only the target behind" do
    described_class.write(path, "x")

    expect(Dir.children(File.dirname(path))).to eq(["out.txt"])
  end

  it "removes the scratch file when the rename fails" do
    FileUtils.mkdir_p(path)

    expect { described_class.write(path, "x") }.to raise_error(SystemCallError)
    expect(Dir.children(File.dirname(path))).to eq(["out.txt"])
  end

  it "removes the scratch file and keeps the old bytes when the write fails" do
    described_class.write(path, "old")
    allow(File).to receive(:binwrite).and_wrap_original do |original, scratch, _bytes|
      original.call(scratch, "par")
      raise Errno::ENOSPC, scratch
    end

    expect { described_class.write(path, "new") }.to raise_error(Errno::ENOSPC)
    expect(File.binread(path)).to eq("old")
    expect(Dir.children(File.dirname(path))).to eq(["out.txt"])
  end

  it "applies the mode when given" do
    described_class.write(path, "x", mode: 0o600)

    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "uses the umask-derived mode of an ordinary write when none is given" do
    File.write(File.join(@dir, "plain"), "x")

    described_class.write(path, "x")

    expect(File.stat(path).mode).to eq(File.stat(File.join(@dir, "plain")).mode)
  end

  it "survives concurrent writers of the same path" do
    Array.new(8) { |i| Thread.new { 20.times { described_class.write(path, "writer-#{i}") } } }.each(&:join)

    expect(File.binread(path)).to match(/\Awriter-\d\z/)
    expect(Dir.children(File.dirname(path))).to eq(["out.txt"])
  end
end
