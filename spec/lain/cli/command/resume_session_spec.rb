# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Lain::CLI::Command::ResumeSession do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:context) { Lain::Context.new(model: "recorded-model", max_tokens: 512, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:dead) { Lain::Liveness::Writer.current.with(start: "1") }
  let(:live) { Lain::Liveness::Writer.current }
  let(:current) { File.join(@dir, "20260729T090000-999.ndjson") }
  let(:env) { instance_double(Lain::CLI::Command::Env, journal_path: current) }
  let(:asked) { [] }
  let(:restart) { ->(**kwargs) { asked << kwargs and true } }
  let(:command) { described_class.new(dir: @dir, pane: "%3", restart:) }

  def open_session(name, writer:, at: "2026-07-27T09:00:00Z")
    header = Lain::SessionRecord.header(context:, toolset:, sections: SessionSections.complete, writer:)
    path = File.join(@dir, name)
    File.write(path, "#{JSON.generate(header.merge("ts" => at))}\n")
    path
  end

  it "is the /resume command and describes itself" do
    expect(command.name).to eq("resume")
    expect(command.usage).to include("/resume")
    expect(command.returns_action?).to be(true)
  end

  it "arms a restart resuming the named session and hands the Repl its :quit action" do
    open_session("20260727T090000-111.ndjson", writer: dead)

    expect(command.call("20260727T090000-111.ndjson", env)).to eq(:quit)
    expect(asked).to eq([{ pane: "%3", extra: ["--resume", "20260727T090000-111.ndjson"] }])
  end

  it "takes a unique prefix of the session name" do
    open_session("20260727T090000-111.ndjson", writer: dead)

    command.call("20260727T09", env)

    expect(asked.sole[:extra]).to eq(["--resume", "20260727T090000-111.ndjson"])
  end

  it "refuses a session with a live writer before quitting, naming the process" do
    open_session("20260727T090000-111.ndjson", writer: live)

    expect { command.call("20260727T090000-111.ndjson", env) }
      .to raise_error(Lain::Error, /20260727T090000-111.ndjson is still open in process #{Process.pid}/)
    expect(asked).to be_empty
  end

  it "resumes the newest unclosed session when named none, never the chat's own file" do
    open_session("20260727T090000-111.ndjson", writer: dead)
    open_session("20260729T090000-999.ndjson", writer: dead, at: "2026-07-29T09:00:00Z")

    expect(command.call("", env)).to eq(:quit)
    expect(asked.sole[:extra]).to eq(["--resume", "20260727T090000-111.ndjson"])
  end

  it "says so and stays when there is no unclosed session" do
    expect { command.call("", env) }.to raise_error(Lain::Error, /no unclosed session to resume/)
    expect(asked).to be_empty
  end

  it "stays when the name matches no session" do
    expect { command.call("nope", env) }.to raise_error(Lain::Error, /no session matching/)
    expect(asked).to be_empty
  end

  it "refuses outside a cockpit, naming lain chat --resume" do
    open_session("20260727T090000-111.ndjson", writer: dead)
    command = described_class.new(dir: @dir, pane: nil, restart: ->(**) { false })

    expect { command.call("20260727T090000-111.ndjson", env) }
      .to raise_error(Lain::Error, /lain chat --resume 20260727T090000-111.ndjson/)
  end

  it "stays in the chat and says the restart could not be set up when tmux refuses" do
    open_session("20260727T090000-111.ndjson", writer: dead)
    refusing = ->(**) { raise Lain::CLI::Up::TmuxUnavailable, "tmux run-shell failed: boom" }
    command = described_class.new(dir: @dir, pane: "%3", restart: refusing)

    expect { command.call("20260727T090000-111.ndjson", env) }
      .to raise_error(Lain::Error, /restart could not be set up.*boom/m)
  end
end
