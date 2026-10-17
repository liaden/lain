# frozen_string_literal: true

require "async"
require "fileutils"
require "stringio"
require "tmpdir"

# A directory the project's config names as related masks a flagged region
# without asking. Everything is real between the config and the file: the
# trusted `.lain/config.rb`, the board a chat builds for its project, the tool
# stack the tool guard builds over it, and the read on disk.
RSpec.describe "A read under a related directory", :seam do
  let(:api_key) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, record_journal: journal,
                                          instrumentation: Lain::Agent::Instrumentation.new(journal:))
  end
  let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new]) }

  around do |example|
    Dir.mktmpdir("lain-related-read") do |dir|
      @base = File.realpath(dir)
      @home = File.join(@base, "home")
      @repo = File.join(@base, "repo")
      FileUtils.mkdir_p([File.join(@home, "dev", "pitchcraft"), File.join(@home, "dev", "other"), @repo])
      example.run
    end
  end

  def paths = Lain::Paths.new(env: { "HOME" => @home, "XDG_STATE_HOME" => File.join(@base, "state") })
  def project = Lain::Project.new(root: @repo, cwd: @repo, kind: :project, detected_by: :git)
  def session = @session ||= Lain::Session.new(worker_env: Lain::WorkerEnv.default.with(cwd: @repo))

  def configure(entries) = write_config(@repo, "sensitivity related: #{entries.inspect}\n")

  def board
    @board ||= Lain::CLI::Wiring::BoardBuild.for(
      chronicle:, options: {}, judge: Lain::CLI::Switchboard::DEFERRING,
      model: "m", toolset:, project:, paths:,
      verdict: Lain::CLI::Wiring::BoardBuild.shell_verdict(project:)
    ).bind_session(session)
  end

  def stack = Lain::CLI::ToolGuard.stack(chronicle, board).to_a

  def note(under) = File.join(@home, "dev", under, "notes.md").tap { File.write(_1, "API_KEY=#{api_key}\n") }

  def dispatch(path) = dispatch_call("read_file", { "path" => path }, toolset:, layers: stack, context: session)

  it "masks the region and parks no approval" do
    configure(["~/dev/pitchcraft"])
    path = note("pitchcraft")

    result = Sync { |task| task.with_timeout(10) { dispatch(path) } }

    expect(result.content).not_to include(api_key)
    expect(result.content).to include("<redacted:1>")
    expect(journal_records(journal_io, "approval_pending")).to be_empty
    expect(journal_records(journal_io, "read_redacted")).to contain_exactly(include("path" => path, "released" => 0))
  end

  it "still parks an approval for a read outside the related directory" do
    configure(["~/dev/pitchcraft"])
    path = note("other")

    Sync do |task|
      call = task.async { dispatch(path) }
      task.with_timeout(10) { board.approvals.dequeue }.deny(surface: "tty")
      call.wait
    end

    expect(journal_records(journal_io, "approval_pending").length).to eq(1)
  end

  it "still parks a built-in gated name under a related directory at the read gate" do
    configure(["~/dev/pitchcraft"])
    path = File.join(@home, "dev", "pitchcraft", ".env").tap { File.write(_1, "API_KEY=#{api_key}\n") }

    result = Sync do |task|
      call = task.async { dispatch(path) }
      task.with_timeout(10) { board.approvals.dequeue }.deny(surface: "tty")
      call.wait
    end

    expect(journal_records(journal_io, "approval_pending").length).to eq(1)
    expect(result.content).not_to include(api_key)
  end

  it "refuses a launch whose related entry names a file" do
    configure(["~/dev/pitchcraft/notes.md"])
    note("pitchcraft")

    expect { board }.to raise_error(Lain::Config::Refusal, %r{related takes directories.*"~/dev/pitchcraft/notes\.md"})
  end

  it "refuses a launch whose related entry is the home directory itself" do
    configure([@home])

    expect { board }.to raise_error(Lain::Config::Refusal, /related must name a specific tree/)
  end
end
