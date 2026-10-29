# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Lain::CLI::Sessions::Forks do
  around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

  def header(resumed_from: nil)
    { "type" => Lain::SessionRecord::HEADER_TYPE }.merge(resumed_from ? { "resumed_from" => resumed_from } : {})
  end

  def write(name, record)
    File.write(File.join(@dir, name), "#{JSON.generate(record)}\n").then { File.join(@dir, name) }
  end

  it "names each child file under the digest its header resumed from" do
    parent = write("a.ndjson", header)
    write("b.ndjson", header(resumed_from: { "file" => "a.ndjson", "head" => "blake3:d1" }))
    write("c.ndjson", header(resumed_from: { "file" => "a.ndjson", "head" => "blake3:d1" }))
    write("d.ndjson", header(resumed_from: { "file" => "a.ndjson", "head" => "blake3:d2" }))

    expect(described_class.of(parent, dirs: [@dir]))
      .to eq("blake3:d1" => %w[b.ndjson c.ndjson], "blake3:d2" => ["d.ndjson"])
  end

  it "ignores files that resume some other session or none" do
    parent = write("a.ndjson", header)
    write("b.ndjson", header(resumed_from: { "file" => "z.ndjson", "head" => "blake3:d1" }))
    write("c.ndjson", header)

    expect(described_class.of(parent, dirs: [@dir])).to eq({})
  end

  it "finds nothing for a chat with no journal file" do
    expect(described_class.of(nil, dirs: [@dir])).to eq({})
  end

  it "scans the chronicle's current file each time the source is called" do
    paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => @dir })
    project = Lain::Project.new(root: @dir, cwd: @dir, kind: :project, detected_by: :flag)
    @dir = paths.session_dirs(project).first
    FileUtils.mkdir_p(@dir)
    first = write("a.ndjson", header)
    write("b.ndjson", header(resumed_from: { "file" => "c.ndjson", "head" => "blake3:d1" }))
    chronicle = Struct.new(:journal_path).new(first)
    source = described_class.source(chronicle, paths:, project:)
    before = source.call
    chronicle.journal_path = File.join(@dir, "c.ndjson")

    expect([before, source.call]).to eq([{}, { "blake3:d1" => ["b.ndjson"] }])
  end

  it "skips a file with no readable header" do
    parent = write("a.ndjson", header)
    File.write(File.join(@dir, "b.ndjson"), "not json\n")
    File.write(File.join(@dir, "c.ndjson"), "")

    expect(described_class.of(parent, dirs: [@dir])).to eq({})
  end

  it "looks in every directory it is given" do
    other = Dir.mktmpdir
    parent = write("a.ndjson", header)
    File.write(File.join(other, "b.ndjson"),
               "#{JSON.generate(header(resumed_from: { "file" => "a.ndjson", "head" => "blake3:d1" }))}\n")

    expect(described_class.of(parent, dirs: [@dir, other])).to eq("blake3:d1" => ["b.ndjson"])
  ensure
    FileUtils.remove_entry(other)
  end
end
