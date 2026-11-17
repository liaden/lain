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

  def configure(entries) = write_config(@repo, "sensitivity related: #{entries.inspect}\n", paths:)

  def board
    @board ||= Lain::CLI::Wiring::BoardBuild.for(
      chronicle:, options: {}, judge: Lain::CLI::Switchboard::DEFERRING,
      model: "m", toolset:, project:, paths:,
      verdict: Lain::CLI::Wiring::BoardBuild.shell_verdict(project:, paths:)
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
    expect(journal_records(journal_io, "awaiting_human")).to be_empty
    masks = journal_records(journal_io, "source_masked")
    expect(masks).to contain_exactly(include("kind" => "file", "key" => path, "released" => 0))
  end

  it "still parks an approval for a read outside the related directory" do
    configure(["~/dev/pitchcraft"])
    path = note("other")

    Sync do |task|
      call = task.async { dispatch(path) }
      task.with_timeout(10) { board.approvals.dequeue }.deny(surface: "tty")
      call.wait
    end

    expect(journal_records(journal_io, "awaiting_human").length).to eq(1)
  end

  it "still parks a built-in gated name under a related directory at the read gate" do
    configure(["~/dev/pitchcraft"])
    path = File.join(@home, "dev", "pitchcraft", ".env").tap { File.write(_1, "API_KEY=#{api_key}\n") }

    result = Sync do |task|
      call = task.async { dispatch(path) }
      task.with_timeout(10) { board.approvals.dequeue }.deny(surface: "tty")
      call.wait
    end

    expect(journal_records(journal_io, "awaiting_human").length).to eq(1)
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

# The same configured directory, read by an allowed command inside the reader
# sandbox: the real mask list over the real policy, bwrap, Landlock and the fence.
RSpec.describe "A related directory inside the reader sandbox", :seam do
  let(:fence) { Lain::Confine::Bwrap.fence_binary }
  let(:journal) { RecordingChannel.new }

  around do |example|
    Dir.mktmpdir("lain-related-sandbox") do |dir|
      @base = File.realpath(dir)
      @home, @repo, @sibling = %w[home repo sibling].map { File.join(@base, _1).tap { |d| FileUtils.mkdir_p(d) } }
      SeedRepo.git(@repo, "init", "-q")
      seed_sibling
      example.run
    end
  end

  before do
    skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
    skip("bwrap cannot make a user namespace on this host") unless
      system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
  end

  def seed_sibling
    FileUtils.mkdir_p(File.join(@sibling, "src"))
    File.write(File.join(@sibling, "src", "m1.rs"), "fn m1() {}\n")
    SeedRepo.git(@sibling, "init", "-q")
    SeedRepo.git(@sibling, "add", "src/m1.rs")
    SeedRepo.git(@sibling, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                 "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "seed")
  end

  def policy(related)
    rules = Lain::Sensitivity::Rules.new(related:)
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: @home, cwd: @repo, root: @repo, rules:),
                                  home: @home, root: @repo)
  end

  def sandboxed(related)
    judging = policy(related)
    masks = Lain::Confine::MaskList.new(root: @repo, policy: -> { judging })
    Lain::Confine::Sandbox.new(root: @repo, home: @home, masks:, fence:, journal:,
                               probe: Lain::Confine::Probe.new(fence:, journal:))
                          .wrap(Lain::Exec::Local.new, requirer: "Spec")
  end

  def call(sandbox, command)
    ruling = Lain::Approval::Escalation::Ruling.allow(rung: "rules", because: "spec", rule: "composed_term")
    request = Lain::Confine::Request.new(ruling:, executables: [], cwd: @repo, root: @repo, tool_use_id: "toolu_1")
    sandbox.call(command:, cwd: @repo, env: {}, timeout: 10, confinement: request)
  end

  def run_confined(command, related: [@sibling]) = call(sandboxed(related), command)

  it "lets an allowed command read a related repository's file and its history" do
    cat = run_confined("cat #{@sibling}/src/m1.rs")
    log = run_confined("git -C #{@sibling} log --format=%s")

    expect([cat.exit_status, cat.stdout]).to eq([0, "fn m1() {}\n"]), cat.stderr
    expect([log.exit_status, log.stdout]).to eq([0, "seed\n"]), log.stderr
    expect(journal.events.grep(Lain::Telemetry::Sandbox).map(&:profile)).to eq(%i[reader reader])
  end

  # The mask refuses the read where the sibling file beside it is read.
  it "keeps a related directory's secret masked" do
    File.write(File.join(@sibling, ".env"), "KEY=value\n")

    capture = run_confined("cat #{@sibling}/.env #{@sibling}/src/m1.rs")

    expect(capture.stdout).to eq("fn m1() {}\n"), capture.stderr
    expect(capture.stdout + capture.stderr).not_to include("value")
  end

  it "refuses a read under a related directory that is not a repository, whose secrets no listing finds" do
    FileUtils.rm_rf(File.join(@sibling, ".git"))

    capture = run_confined("cat #{@sibling}/src/m1.rs")

    expect(capture.exit_status).not_to eq(0)
    expect(capture.stdout).not_to include("fn m1")
  end

  it "stops reading a related directory once it can no longer be listed, whatever its old masks were" do
    sandbox = sandboxed([@sibling])
    first = call(sandbox, "cat #{@sibling}/src/m1.rs")
    FileUtils.rm_rf(File.join(@sibling, ".git"))
    File.write(File.join(@sibling, ".env"), "KEY=value\n")

    capture = call(sandbox, "cat #{@sibling}/.env #{@sibling}/src/m1.rs")

    expect(first.stdout).to eq("fn m1() {}\n"), first.stderr
    expect(capture.stdout + capture.stderr).not_to include("value")
    expect(capture.stdout).not_to include("fn m1")
  end

  it "hides what lies below a pruned directory, which no listing looks inside" do
    FileUtils.mkdir_p(File.join(@sibling, "tmp", "x"))
    File.write(File.join(@sibling, "tmp", "x", ".env"), "KEY=value\n")
    File.write(File.join(@sibling, "tmp", "top.txt"), "top\n")

    capture = run_confined("cat #{@sibling}/tmp/x/.env #{@sibling}/tmp/top.txt")

    expect(capture.stdout).to eq("top\n"), capture.stderr
    expect(capture.stdout + capture.stderr).not_to include("value")
  end

  # git lists a nested repository as 1 leaf, so the walk below it is what finds its pruned directories.
  it "hides what lies below a pruned directory inside a nested repository" do
    nested = File.join(@sibling, "nested")
    FileUtils.mkdir_p(File.join(nested, "target", "x"))
    SeedRepo.git(nested, "init", "-q")
    File.write(File.join(nested, "target", "x", "creds.txt"), "KEY=value\n")
    File.write(File.join(nested, "ok.txt"), "ok\n")

    capture = run_confined("cat #{nested}/target/x/creds.txt #{nested}/ok.txt")

    expect(capture.stdout).to eq("ok\n"), capture.stderr
    expect(capture.stdout + capture.stderr).not_to include("value")
  end

  it "refuses the same read where no related directory is configured" do
    capture = run_confined("cat #{@sibling}/src/m1.rs", related: [])

    expect(capture.exit_status).not_to eq(0)
    expect(capture.stdout).not_to include("fn m1")
  end
end
