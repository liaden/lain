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

    expect(Ractor.shareable?(record)).to be(true)
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
end
