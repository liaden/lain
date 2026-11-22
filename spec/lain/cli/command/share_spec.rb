# frozen_string_literal: true

# `/share` pipes the session's export to `gh gist create` as a secret gist. The gist client is a
# fake at the `Shell::Out` seam, so nothing here reaches gh or the network.
RSpec.describe Lain::CLI::Command::Share do
  subject(:command) { described_class.new(exports: ->(file) { (opened << file) && export }, shell: gh, journal:) }

  let(:html) { "<p>3 regions were masked as &lt;redacted:n&gt;; the session was not re-scanned.</p>" }
  let(:export) { instance_double(Lain::CLI::Export, released: 0, masked: 3) }
  let(:journal) { instance_double(Lain::Journal, record: nil) }
  let(:spawned) { [] }
  let(:opened) { [] }
  let(:answer) { { stdout: "https://gist.github.com/u/abc123\n", stderr: "", exitstatus: 0 } }
  let(:gh) do
    spawned = self.spawned
    answer = self.answer
    Class.new do
      define_method(:initialize) { |*argv, **options| spawned << [argv, options] }
      define_method(:run_command) { self }
      answer.each { |reader, value| define_method(reader) { value } }
    end
  end
  let(:path) { "/home/u/.local/state/lain/sessions/s-1.ndjson" }
  let(:env) { build_command_env(chronicle: instance_double(Lain::CLI::Chronicle::Null, journal_path: path)) }

  before do
    allow(export).to receive(:call).with(format: :html).and_return(html)
  end

  it "is the /share command and describes itself" do
    expect(command.name).to eq("share")
    expect(command.usage).to include("/share")
    expect(command.usage).not_to include("--jsonl")
  end

  it "pipes the html export to a secret gist and replies with the url and the masked count" do
    reply = command.call("", env)

    expect(spawned.size).to eq(1)
    argv, options = spawned.first
    expect(argv).to eq(["gh", "gist", "create", "--public=false", "--filename", "s-1.html", "-"])
    expect(options).to include(input: html)
    expect(reply).to include("https://gist.github.com/u/abc123").and include("3 regions")
  end

  it "pipes an export that names this box's identity as its placeholders" do
    identity = Lain::Sensitivity::Secrets::Identity.new(pairs: [["/home/alice", "/home/<lain:user>"]])
    allow(export).to receive(:call).with(format: :html).and_return("<p>cd /home/alice/dev</p>")

    described_class.new(exports: ->(_file) { export }, shell: gh, journal:, identity:).call("", env)

    expect(spawned.first.last).to include(input: "<p>cd /home/<lain:user>/dev</p>")
  end

  it "spawns the gist under the configured account's environment" do
    account = instance_double(Lain::Forge::Gh::Account, environment: { "GH_TOKEN" => "t0k" })

    described_class.new(exports: ->(_file) { export }, shell: gh, journal:, account:).call("", env)

    expect(spawned.first.last).to include(environment: { "GH_TOKEN" => "t0k" })
  end

  it "falls back to `lain export` when the configured account has no gh to ask" do
    github = Lain::Config::Github.resolve(project: Lain::Config::Github.from({ "account" => "joel-fuze" }, path: nil),
                                          user: Lain::Config::Github.empty, env: {})
    absent = Class.new { define_method(:run_command) { raise Errno::ENOENT, "gh" } }.new
    account = Lain::Forge::Gh::Account.for(github, env: {}, shell_out_factory: GhParity::FakeGh.new { absent },
                                                   notes: Lain::Herdr::HeldNotes.new)

    reply = described_class.new(exports: ->(_file) { export }, shell: gh, journal:, account:).call("", env)

    expect(reply).to include("gh was not found").and end_with("; `lain export` writes a local copy")
    expect(spawned).to be_empty
  end

  it "spawns the gist under the parent's environment unchanged when no account is configured" do
    command.call("", env)

    expect(spawned.first.last).to include(environment: {})
  end

  it "opens the export over the session file as the chat holds it at call time" do
    command.call("", env)

    expect(opened).to eq([path])
  end

  it "says the bytes are the model's masked view and names the file, and journals the share" do
    reply = command.call("", env)

    expect(reply).to include("masked view").and include("s-1.ndjson")
    expect(journal).to have_received(:record).with(
      have_attributes(journal_type: "session_shared", url: "https://gist.github.com/u/abc123",
                      format: "html", masked: 3)
    )
  end

  it "answers the usage to --jsonl, which is a local record, and spawns nothing" do
    expect(command.call("--jsonl", env)).to eq(command.usage)
    expect(spawned).to be_empty
  end

  it "refuses a session that released a secret and spawns nothing" do
    allow(export).to receive(:released).and_return(2)

    reply = command.call("", env)

    expect(reply).to include("2 regions were released to the model").and include("lain export")
    expect(spawned).to be_empty
    expect(journal).not_to have_received(:record)
  end

  it "refuses a session with no turns and spawns nothing" do
    Dir.mktmpdir do |dir|
      bare = File.join(dir, "bare.ndjson")
      File.write(bare, "#{JSON.generate({ "type" => "session" })}\n")
      empty = lambda { |file|
        Lain::CLI::Export.new(selector: file, paths: instance_double(Lain::Paths, filing_dir: dir),
                              project: instance_double(Lain::Project, root: "/x"))
      }
      chronicle = instance_double(Lain::CLI::Chronicle::Null, journal_path: bare)

      expect { described_class.new(exports: empty, shell: gh, journal:).call("", build_command_env(chronicle:)) }
        .to raise_error(Lain::Error, /no turns.*nothing was exported or shared/)
    end
    expect(spawned).to be_empty
    expect(journal).not_to have_received(:record)
  end

  it "refuses by name when an earlier file of the resume chain is gone, and spawns nothing" do
    Dir.mktmpdir do |dir|
      orphan = File.join(dir, "orphan.ndjson")
      header = { "type" => "session", "resumed_from" => { "file" => "gone.ndjson" } }
      File.write(orphan, "#{JSON.generate(header)}\n")
      paths = instance_double(Lain::Paths, filing_dir: dir)
      allow(paths).to receive(:chain_file) { |name, dir:| File.join(dir, name) }
      chain = lambda { |file|
        Lain::CLI::Export.new(selector: file, paths:, project: instance_double(Lain::Project, root: "/x"))
      }
      chronicle = instance_double(Lain::CLI::Chronicle::Null, journal_path: orphan)

      expect { described_class.new(exports: chain, shell: gh, journal:).call("", build_command_env(chronicle:)) }
        .to raise_error(Lain::Error, /gone\.ndjson.*nothing was exported or shared/m)
    end
    expect(spawned).to be_empty
  end

  it "says region in the singular when one was masked" do
    allow(export).to receive(:masked).and_return(1)

    expect(command.call("", env)).to include("(1 region masked)")
  end

  it "says region in the singular when one was released" do
    allow(export).to receive(:released).and_return(1)

    expect(command.call("", env)).to include("1 region was released to the model")
  end

  it "refuses plainly when gh is not installed" do
    allow(gh).to receive(:new).and_raise(Errno::ENOENT)

    reply = command.call("", env)

    expect(reply).to include("gh is needed").and include("lain export")
    expect(journal).not_to have_received(:record)
  end

  context "when gh exits non-zero" do
    let(:answer) { { stdout: "", stderr: "gh: not logged in", exitstatus: 1 } }

    it "reports gh's own words and journals nothing" do
      reply = command.call("", env)

      expect(reply).to include("gh: not logged in")
      expect(journal).not_to have_received(:record)
    end
  end

  context "when gh exits zero without printing a url" do
    let(:answer) { { stdout: "\n", stderr: "", exitstatus: 0 } }

    it "answers a plain reply and journals nothing" do
      expect(command.call("", env)).to include("no gist url")
      expect(journal).not_to have_received(:record)
    end
  end

  it "does not blame gh when the session file is gone" do
    gone = lambda { |file|
      Lain::CLI::Export.new(selector: file, paths: instance_double(Lain::Paths, filing_dir: "/gone"),
                            project: instance_double(Lain::Project, root: "/x"))
    }
    sharing = described_class.new(exports: gone, shell: gh, journal:)

    expect { sharing.call("", env) }.to raise_error(Lain::CLI::SessionFile::SessionNotFound)
    expect(spawned).to be_empty
  end

  it "does not blame gh when the file vanishes between the checks and the read" do
    allow(export).to receive(:call).and_raise(Errno::ENOENT)

    expect { command.call("", env) }.to raise_error(Errno::ENOENT)
    expect(spawned).to be_empty
  end

  it "refuses by name when the chat has no session file" do
    bare = build_command_env

    expect { command.call("", bare) }.to raise_error(Lain::Error, /--no-journal/)
    expect(spawned).to be_empty
  end

  it "refuses an unknown argument" do
    expect(command.call("--pdf", env)).to include("/share")
    expect(spawned).to be_empty
  end

  describe "through the production path" do
    let(:dir) { Dir.mktmpdir }
    let(:file) { File.join(dir, "s.ndjson") }
    let(:records) do
      [{ "type" => "session", "format" => 1 },
       { "type" => "turn", "digest" => "d1", "role" => "user", "parent" => nil, "meta" => {},
         "content" => [{ "type" => "text", "text" => "hi" }] },
       { "type" => "source_masked", "tool_use_id" => "t", "kind" => "file", "key" => ".env", "regions" => 2,
         "released" => 0 }]
    end
    let(:exports) do
      lambda do |selector|
        Lain::CLI::Export.new(selector:, paths: Lain::Paths.new, project: instance_double(Lain::Project, root: dir))
      end
    end

    before do
      bin = File.join(dir, "bin").tap { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(bin, "gh"), <<~SH)
        #!/bin/sh
        printf '%s\\n' "$@" > #{dir}/argv
        cat > #{dir}/stdin
        echo https://gist.github.com/u/1
      SH
      File.chmod(0o755, File.join(bin, "gh"))
      File.write(file, "#{records.map { |record| JSON.generate(record) }.join("\n")}\n")
      @path = ENV.fetch("PATH")
      ENV["PATH"] = "#{bin}:#{@path}"
    end

    after do
      ENV["PATH"] = @path
      FileUtils.remove_entry(dir)
    end

    it "uploads a page holding no known value, and says one region was masked" do
      File.write(file, "#{[*records, { "type" => "turn", "digest" => "d2", "role" => "user", "parent" => "d1",
                                       "meta" => {}, "content" => [{ "type" => "text", "text" => "hunter2xyz" }] }]
                           .map { |record| JSON.generate(record) }.join("\n")}\n")
      masking = lambda do |selector|
        Lain::CLI::Export.new(selector:, paths: Lain::Paths.new, project: instance_double(Lain::Project, root: dir),
                              secrets: ["hunter2xyz"])
      end
      sharing = described_class.new(exports: masking, journal:)
      reply = sharing.call("",
                           build_command_env(chronicle: instance_double(Lain::CLI::Chronicle::Null,
                                                                        journal_path: file)))

      expect(File.read("#{dir}/stdin")).not_to include("hunter2xyz")
      expect(reply).to include("3 regions masked")
    end

    it "aliases a name that follows a newline inside a tool call and inside a tool result" do
      turns = [{ "type" => "turn", "digest" => "d2", "role" => "assistant", "parent" => "d1", "meta" => {},
                 "content" => [{ "type" => "tool_use", "id" => "t1", "name" => "bash",
                                 "input" => { "command" => "echo hi\n/home/alice/dev" } }] },
               { "type" => "turn", "digest" => "d3", "role" => "user", "parent" => "d2", "meta" => {},
                 "content" => [{ "type" => "tool_result", "tool_use_id" => "t1",
                                 "content" => "ok\n/home/alice/dev" }] }]
      File.write(file, "#{[*records, *turns].map { |record| JSON.generate(record) }.join("\n")}\n")
      identity = Lain::Sensitivity::Secrets::Identity.new(pairs: [["/home/alice", "/home/<lain:user>"]])

      described_class.new(exports:, journal:, identity:)
                     .call("", build_command_env(chronicle: instance_double(Lain::CLI::Chronicle::Null,
                                                                            journal_path: file)))

      expect(File.read("#{dir}/stdin")).to include("/home/<lain:user>/dev").and not_include("alice")
    end

    it "pipes the real html to gh and records the url and the masked count" do
      sharing = described_class.new(exports:, journal:)
      sharing.call("", build_command_env(chronicle: instance_double(Lain::CLI::Chronicle::Null, journal_path: file)))

      expect(File.read("#{dir}/stdin")).to eq(exports.call(file).call(format: :html))
      expect(File.readlines("#{dir}/argv", chomp: true))
        .to eq(%w[gist create --public=false --filename s.html -])
      expect(journal).to have_received(:record)
        .with(have_attributes(url: "https://gist.github.com/u/1", format: "html", masked: 2))
    end
  end
end
