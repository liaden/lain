# frozen_string_literal: true

RSpec.describe Lain::CLI::Export do
  let(:tmpdir) { Dir.mktmpdir }
  let(:sessions_dir) { File.join(tmpdir, "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:paths) { instance_double(Lain::Paths, session_dirs: [sessions_dir]) }
  let(:project) { instance_double(Lain::Project, root: "/work/proj") }
  let(:secret) { "hunter2-s3cr3t-value" }
  let(:session_records) do
    [
      { "type" => "session", "format" => 1 },
      { "type" => "turn", "digest" => "d1", "role" => "user", "parent" => nil, "meta" => {},
        "content" => [{ "type" => "text", "text" => "read the env" }] },
      { "type" => "turn", "digest" => "d2", "role" => "assistant", "parent" => "d1", "meta" => {},
        "content" => [{ "type" => "tool_use", "id" => "tu_1", "name" => "read_file",
                        "input" => { "path" => ".env" } }] },
      { "type" => "turn", "digest" => "d3", "role" => "user", "parent" => "d2", "meta" => {},
        "content" => [{ "type" => "tool_result", "tool_use_id" => "tu_1", "content" => "KEY=<redacted:1>" }] },
      { "type" => "source_masked", "tool_use_id" => "tu_1", "kind" => "file", "key" => ".env", "regions" => 1,
        "released" => 0 },
      { "type" => "read_released", "tool_use_id" => "tu_2", "path" => ".env", "regions" => 2,
        "requester" => "agent", "surface" => "tty" },
      { "type" => "turn", "digest" => "d4", "role" => "assistant", "parent" => "d3", "meta" => {},
        "content" => [{ "type" => "text", "text" => "done" }] }
    ]
  end
  let(:lines) { session_records.map { |record| JSON.generate(record) } }

  before { File.write(File.join(sessions_dir, "work.ndjson"), "#{lines.join("\n")}\n") }

  after { FileUtils.remove_entry(tmpdir) }

  def export(selector = "work") = described_class.new(selector:, paths:, project:)

  it "prints the header and every applied record byte for byte, one per line, as jsonl" do
    expect(export.call(format: :jsonl)).to eq("#{lines.join("\n")}\n")
  end

  it "drops a retreat whose turn never landed from the jsonl" do
    torn = JSON.generate({ "type" => "rewound", "from" => "d4", "to" => "d1", "then" => "d9" })
    File.write(File.join(sessions_dir, "work.ndjson"), "#{[*lines, torn].join("\n")}\n")

    expect(export.call(format: :jsonl)).to eq("#{lines.join("\n")}\n")
  end

  it "renders html holding the conversation, the masked count and no value" do
    html = export.call(format: :html, include_released: true)

    expect(html).to include("read_file", "&lt;redacted:1&gt;", "done")
    expect(html).not_to include(secret)
  end

  it "reports the regions released to the model" do
    expect(export.released).to eq(2)
  end

  it "reports the regions the session masked, the count the html footer shows" do
    expect(export.masked).to eq(1)
  end

  it "refuses html while regions were released unless told to include them" do
    expect { export.call(format: :html) }.to raise_error(Lain::Error, /released/)
    expect(export.call(format: :html, include_released: true)).to include("2 regions were released")
  end

  it "writes out with mode 0600 and refuses an existing path unless forced" do
    out = File.join(tmpdir, "s.jsonl")
    export.call(format: :jsonl, out:)

    expect(File.stat(out).mode & 0o777).to eq(0o600)
    expect { export.call(format: :jsonl, out:) }.to raise_error(Lain::Error, /exists/)
    expect(export.call(format: :jsonl, out:, force: true)).to eq(out)
  end

  it "never follows a symlink at out, with or without force" do
    target = File.join(tmpdir, "victim")
    out = File.join(tmpdir, "s.jsonl")
    File.symlink(target, out)

    expect { export.call(format: :jsonl, out:) }.to raise_error(Lain::Error, /exists/)
    export.call(format: :jsonl, out:, force: true)

    expect(File).not_to exist(target)
    expect([File.symlink?(out), File.stat(out).mode & 0o777]).to eq([false, 0o600])
  end

  it "writes the document to out and answers with that name" do
    out = File.join(tmpdir, "s.html")

    expect(export.call(format: :html, out:, include_released: true)).to eq(out)
    expect(File.read(out)).to include("read the env")
  end

  it "refuses a format it does not know" do
    expect { export.call(format: :pdf) }.to raise_error(ArgumentError, /pdf/)
  end

  it "raises SessionNotFound for a selector nothing answers to" do
    expect { export("nope").call }.to raise_error(Lain::CLI::SessionFile::SessionNotFound)
  end
end
