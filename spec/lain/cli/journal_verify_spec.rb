# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::CLI::JournalVerify do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:sink) { StringIO.new }
  let(:paths) { instance_double(Lain::Paths, filing_dir: @dir) }
  let(:cli) { described_class.new(sink:, paths:) }
  let(:path) { File.join(@dir, "20260721T000000-1.ndjson") }
  let(:said) { sink.string }

  def write(chain: true, count: 5)
    Lain::Journal.open(path, chain:) do |journal|
      count.times { |n| journal.record("type" => "turn", "n" => n + 1, "text" => "line #{n + 1}") }
    end
  end

  def edit(index, from, to)
    all = File.readlines(path, mode: "rb")
    all[index] = all[index].sub(from, to)
    File.binwrite(path, all.join)
  end

  it "exits 0 and prints the line count and the tip for an untouched file" do
    write

    expect(cli.run(path)).to eq(0)
    expect(said.lines.first).to eq("chain intact: 5 lines, tip #{Lain::Journal::Line.tip(path)}\n")
  end

  it "resolves a bare session name the way the other session commands do" do
    write

    expect(cli.run("20260721T000000-1")).to eq(0)
  end

  it "raises the resolver's refusal for a session that does not exist" do
    expect { cli.run("nope") }.to raise_error(Lain::CLI::SessionFile::SessionNotFound)
  end

  it "exits 1 naming the first line whose link does not match" do
    write
    edit(2, "line 3", "line X")

    expect(cli.run(path)).to eq(1)
    expect(said).to include("chain broken at line 4").and include("edited, inserted or removed")
  end

  it "reports a file written before chaining without failing it" do
    write(chain: false, count: 3)

    expect(cli.run(path)).to eq(0)
    expect(said).to eq("unchained: 3 lines (written before record chaining)\n")
  end

  it "says where the chain began when a chainless file was reopened chained" do
    write(chain: false, count: 2)
    Lain::Journal.open(path, chain: true) { |journal| journal.record("type" => "turn") }

    expect(cli.run(path)).to eq(0)
    expect(said).to include("chain intact: 3 lines").and include("chained from line 3")
  end

  it "exits 1 naming the last line when a kept tip no longer matches" do
    write
    kept = Lain::Journal::Line.tip(path)
    edit(4, "line 5", "line X")

    expect(cli.run(path, tip: kept)).to eq(1)
    expect(said).to include("last line (5) does not match the kept tip #{kept}")
  end

  it "exits 0 for a crash tail and says it is not an edit" do
    write
    File.binwrite(path, '{"ts":"2026-01-01T00:00:00Z","ty', mode: "ab")

    expect(cli.run(path)).to eq(0)
    expect(said).to include("line 6 is a torn tail").and include("crash")
  end

  it "says a crash and a cut last record look the same, and only a kept tip tells them apart" do
    write
    File.binwrite(path, '{"ts":"2026-01-01T00:00:00Z","ty', mode: "ab")

    cli.run(path)

    expect(said).to include("cut").and include("only a kept tip")
  end

  it "says which line holds the kept tip, and that the lines after it are unchecked by it" do
    write
    kept = Lain::Journal::Line.tip(path)
    Lain::Journal.open(path, chain: true) { |journal| 2.times { journal.record("type" => "turn") } }

    expect(cli.run(path, tip: kept)).to eq(0)
    expect(said).to include("tip held by line 5").and include("lines 6..7").and include("unchecked by the tip")
  end

  it "says nothing about the lines after the tip when the tip is the last line" do
    write
    cli.run(path, tip: Lain::Journal::Line.tip(path))

    expect(said).not_to include("unchecked")
  end

  it "names the line before an unlinked one as held by nothing" do
    write(count: 3)
    Lain::Journal.open(path) { |journal| journal.record("type" => "turn") }

    cli.run(path)

    expect(said).to include("line 3 is held by nothing: line 4 carries no link")
  end

  it "says the file is empty rather than naming a last line 0" do
    File.write(path, "")

    expect(cli.run(path, tip: "blake3:#{"a" * 64}")).to eq(1)
    expect(said).to include("the file is empty")
    expect(said).not_to include("(0)")
  end

  it "fails an unchained file against a tip it does not match" do
    write(chain: false, count: 2)

    expect(cli.run(path, tip: "blake3:#{"a" * 64}")).to eq(1)
  end

  it "raises for a reason it has no words for" do
    report = Lain::Journal::Verify::Report.new(lines: 1, chained_from: 1, first_break: nil, reason: :bogus,
                                               tip: nil, covered: [], unvouched: [], tip_line: nil)
    allow(Lain::Journal::Verify).to receive(:new).and_return(instance_double(Lain::Journal::Verify, call: report))
    write

    expect { cli.run(path) }.to raise_error(ArgumentError, /bogus/)
  end

  it "mentions a sealed crash line the chain covers" do
    write(count: 2)
    File.binwrite(path, '{"ts":"2026-01-01T00:00:00Z","ty', mode: "ab")
    Lain::Journal.open(path, chain: true) { |journal| journal.record("type" => "turn") }

    expect(cli.run(path)).to eq(0)
    expect(said).to include("chain intact: 4 lines").and include("sealed crash line 3")
  end
end
