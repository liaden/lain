# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Memory::Staleness do
  subject(:staleness) { described_class.new(root: @root) }

  around do |example|
    Dir.mktmpdir("lain-staleness") do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def digest_of(bytes) = "blake3:#{Lain::Ext.blake3_hex(bytes)}"

  def item(sources)
    Lain::Memory::Item.new(id: "a", description: "d", body: "b", sources:)
  end

  def write(name, bytes)
    File.write(File.join(@root, name), bytes)
  end

  it "has no mark for an item with no sources" do
    expect(staleness.of(item({}))).to eq([])
  end

  it "has no mark while every source still has its recorded digest" do
    write("a.rb", "x = 1")

    expect(staleness.of(item({ "a.rb" => digest_of("x = 1") }))).to eq([])
  end

  it "names a source whose bytes changed" do
    write("a.rb", "x = 1")
    sourced = item({ "a.rb" => digest_of("x = 1") })
    write("a.rb", "x = 2")

    expect(staleness.of(sourced)).to eq(["a.rb changed"])
  end

  it "names a deleted source as missing rather than raising" do
    expect(staleness.of(item({ "gone.rb" => digest_of("x") }))).to eq(["gone.rb missing"])
  end

  it "names every stale source" do
    write("b.rb", "new")

    expect(staleness.of(item({ "a.rb" => digest_of("x"), "b.rb" => digest_of("old") })))
      .to eq(["a.rb missing", "b.rb changed"])
  end

  it "refuses a symlink inside the project that points outside it" do
    outside = File.join(Dir.mktmpdir("lain-outside"), "hosts")
    File.write(outside, "secret")
    File.symlink(outside, File.join(@root, "ln"))

    expect { staleness.record(["ln"]) }.to raise_error(described_class::Refused, /ln/)
  end

  it "does not re-read a source whose size and mtime are unchanged" do
    write("a.rb", "x = 1")
    sourced = item({ "a.rb" => digest_of("x = 1") })
    staleness.of(sourced)
    allow(File).to receive(:binread).and_call_original

    staleness.of(sourced)

    expect(File).not_to have_received(:binread)
  end

  it "re-reads once the source's stat changes" do
    write("a.rb", "x = 1")
    sourced = item({ "a.rb" => digest_of("x = 1") })
    staleness.of(sourced)
    write("a.rb", "x = 22")

    expect(staleness.of(sourced)).to eq(["a.rb changed"])
  end

  describe "Never" do
    it "never marks anything" do
      expect(described_class::Never.of(item({ "a.rb" => digest_of("x") }))).to eq([])
    end
  end
end
