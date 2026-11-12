# frozen_string_literal: true

RSpec.describe Lain::CLI::Export do
  let(:tmpdir) { Dir.mktmpdir }
  let(:sessions_dir) { File.join(tmpdir, "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:paths) { instance_double(Lain::Paths, filing_dir: sessions_dir) }
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

  it "agrees with the html footer on the masked count when 3 reads masked 1, 2 and 4 regions" do
    masked = [{ "type" => "source_masked", "tool_use_id" => "tu_a", "kind" => "file", "key" => "a", "regions" => 1,
                "released" => 0 },
              { "type" => "command_redacted", "tool_use_id" => "tu_b", "regions" => 2, "prior" => 0 },
              { "type" => "search_redacted", "tool_use_id" => "tu_c", "path" => "a.rb", "regions" => 4,
                "released" => 0 }]
    masked.unshift({ "type" => "turn", "digest" => "t1", "role" => "user", "parent" => nil, "meta" => {},
                     "content" => [{ "type" => "text", "text" => "hi" }] })
    File.write(File.join(sessions_dir, "three.ndjson"), "#{masked.map { |record| JSON.generate(record) }.join("\n")}\n")

    expect([export("three").masked, export("three").call(format: :html)]).to match([7, include("7 regions")])
  end

  it "raises on a masked record that will not read instead of leaving it uncounted" do
    broken = JSON.generate({ "type" => "source_masked", "tool_use_id" => "tu_a", "kind" => "file", "regions" => 1 })
    File.write(File.join(sessions_dir, "broken.ndjson"), "#{broken}\n")

    expect { export("broken").masked }.to raise_error(Lain::Telemetry::Unreadable, /source_masked/)
  end

  it "refuses html while regions were released unless told to include them" do
    expect { export.call(format: :html) }.to raise_error(Lain::Error, /released/)
    expect(export.call(format: :html, include_released: true)).to include("2 regions were released")
  end

  context "with a session resumed once" do
    let(:earlier) do
      [{ "type" => "session", "format" => 1 },
       { "type" => "turn", "digest" => "a1", "role" => "user", "parent" => nil, "meta" => {},
         "content" => [{ "type" => "text", "text" => "before the resume" }] },
       { "type" => "read_released", "tool_use_id" => "tu_9", "path" => ".env", "regions" => 3,
         "requester" => "agent", "surface" => "tty" }]
    end
    let(:later) do
      [{ "type" => "session", "format" => 1, "resumed_from" => { "file" => "earlier.ndjson" } },
       { "type" => "turn", "digest" => "b1", "role" => "assistant", "parent" => "a1", "meta" => {},
         "content" => [{ "type" => "text", "text" => "after the resume" }] }]
    end
    let(:later_lines) { later.map { |record| JSON.generate(record) } }

    before do
      File.write(File.join(sessions_dir, "earlier.ndjson"), "#{earlier.map { |r| JSON.generate(r) }.join("\n")}\n")
      File.write(File.join(sessions_dir, "later.ndjson"), "#{later_lines.join("\n")}\n")
      allow(paths).to receive(:chain_file) { |name, dir:| File.join(dir, name) }
    end

    it "shows the turns from before and after the resume in the html" do
      html = export("later").call(format: :html, include_released: true)

      expect(html).to include("before the resume", "after the resume")
    end

    it "counts the regions released in an earlier file, so the html gate still refuses" do
      expect { export("later").call(format: :html) }.to raise_error(Lain::Error, /3 regions were released/)
    end

    it "keeps the jsonl to the one file" do
      expect(export("later").call(format: :jsonl)).to eq("#{later_lines.join("\n")}\n")
    end
  end

  it "refuses an html page whose only turn was rewound to the empty head" do
    rewound = [{ "type" => "session", "format" => 1 }, session_records[1],
               { "type" => "rewound", "from" => "d1", "to" => nil }]
    File.write(File.join(sessions_dir, "rew.ndjson"), "#{rewound.map { |r| JSON.generate(r) }.join("\n")}\n")

    expect { export("rew").call(format: :html) }.to raise_error(Lain::Error, /no turns/)
  end

  context "when an earlier file of the resume chain is gone" do
    before do
      orphan = [{ "type" => "session", "format" => 1, "resumed_from" => { "file" => "gone.ndjson" } },
                session_records[1]]
      File.write(File.join(sessions_dir, "orphan.ndjson"), "#{orphan.map { |r| JSON.generate(r) }.join("\n")}\n")
      allow(paths).to receive(:chain_file) { |name, dir:| File.join(dir, name) }
    end

    it "refuses the html by name, saying nothing was exported" do
      expect { export("orphan").call(format: :html) }
        .to raise_error(Lain::Error, /gone\.ndjson.*released.*nothing was exported or shared/m)
    end

    it "still writes the jsonl of the one file" do
      expect(export("orphan").call(format: :jsonl)).to include("session")
    end
  end

  it "refuses an html page with no turns, and still writes the jsonl" do
    File.write(File.join(sessions_dir, "bare.ndjson"), "#{JSON.generate({ "type" => "session", "format" => 1 })}\n")

    expect { export("bare").call(format: :html) }.to raise_error(Lain::Error, /no turns.*nothing was exported/)
    expect(export("bare").call(format: :jsonl)).to include("session")
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
