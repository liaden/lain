# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Lain::Telemetry::FileWritten do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "cat")
      File.write(@path, "#!/bin/sh\n")
      example.run
    end
  end

  attr_reader :path

  def ctime_ns(stat) = (stat.ctime.tv_sec * 1_000_000_000) + stat.ctime.tv_nsec

  it "carries the identity of the stat it was built from, ctime to the nanosecond" do
    stat = File.stat(path)
    record = described_class.from_stat(stat, path:, tool_use_id: "tu_1")

    expect(record).to have_attributes(tool_use_id: "tu_1", path:, device: stat.dev, inode: stat.ino,
                                      ctime: ctime_ns(stat))
  end

  it "takes ctime and not mtime, which a process can set back" do
    File.utime(Time.at(0), Time.at(0), path)
    stat = File.stat(path)
    record = described_class.from_stat(stat, path:, tool_use_id: "tu_1")

    expect(record.ctime).to eq(ctime_ns(stat))
    expect(record.ctime).not_to eq((stat.mtime.tv_sec * 1_000_000_000) + stat.mtime.tv_nsec)
  end

  it "is shareable across Ractors even built from mutable Strings" do
    record = described_class.from_stat(File.stat(path), path: +path, tool_use_id: +"tu_1")

    expect(record).to be_deeply_frozen
  end

  it "writes one file_written line a reader can rebuild the identity from" do
    record = described_class.from_stat(File.stat(path), path:, tool_use_id: "tu_1")
    journal_path = File.join(File.dirname(path), "session.ndjson")
    journal = Lain::Journal.open(journal_path)
    journal.record(record)
    journal.close

    line = JSON.parse(File.readlines(journal_path, chomp: true).first)

    expect(line).to include("type" => "file_written", "tool_use_id" => "tu_1", "path" => path,
                            "device" => record.device, "inode" => record.inode, "ctime" => record.ctime)
  end

  describe "the journal line" do
    it "matches the line the record has always written" do
      record = described_class.new(tool_use_id: "tu_1", path: "/p/a.rb", device: 64_769, inode: 1234,
                                   ctime: 1_700_000_000_123_456_789)

      expect(JSON.generate(record.to_journal))
        .to eq('{"type":"file_written","tool_use_id":"tu_1","path":"/p/a.rb","device":64769,"inode":1234,' \
               '"ctime":1700000000123456789}')
    end

    it "keeps a nil tool_use_id as null" do
      record = described_class.new(tool_use_id: nil, path: "/p/a.rb", device: 1, inode: 2, ctime: 3)

      expect(JSON.generate(record.to_journal))
        .to eq('{"type":"file_written","tool_use_id":null,"path":"/p/a.rb","device":1,"inode":2,"ctime":3}')
    end
  end

  it "shares the bytes of every interned field between 2 equal records" do
    build = -> { described_class.new(tool_use_id: +"tu_1", path: +"/p/a.rb", device: 1, inode: 2, ctime: 3) }
    one = build.call
    other = build.call

    expect([one.tool_use_id.equal?(other.tool_use_id), one.path.equal?(other.path)]).to eq([true, true])
  end

  it "writes a Pathname's string as the path" do
    expect(described_class.new(tool_use_id: nil, path: Pathname("/p/a.rb"), device: 1, inode: 2, ctime: 3).path)
      .to eq("/p/a.rb")
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect { described_class.new(tool_use_id: nil, path: "/p", device: 1, inode: 2, ctime: 3, extra: 1) }
      .to raise_error(ArgumentError, /extra/)
  end
end
