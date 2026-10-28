# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "stringio"
require "tmpdir"

# Calls the workspace sandbox refuses an exec in, run for real through bwrap, strace and lain-fence in a throwaway
# fixture, then traced, scored and folded the way a chat does. The stop arm fails closed: the honest shapes here
# trip it too, accepted false trips until measured narrowing excuses them.
RSpec.describe Lain::Tripwire::Hit, :seam do
  around do |example|
    # A short name: the fence binds a Unix socket beneath the call's TMPDIR, and SUN_LEN is 108 bytes.
    Dir.mktmpdir("h") do |dir|
      @base = File.realpath(dir)
      example.run
    end
  end

  let(:project) { mkdir("proj") }
  let(:home) { mkdir("home") }
  let(:fence) { Lain::Confine::Bwrap.fence_binary }
  let(:profile) { Lain::Confine::Profile.workspace(root: project, home:, tmpdir: mkdir("tmp")) }
  # Spec git reads no user config, and a hook run must not build against an outer index.
  let(:env) do
    { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1", "HOME" => home, "LC_ALL" => "C",
      "GIT_INDEX_FILE" => nil, "GIT_DIR" => nil, "GIT_WORK_TREE" => nil }
  end
  let(:stops) { Lain::Tripwire::Stops.new }
  let(:journal) { [] }
  let(:ledger) { Lain::Tripwire::Ledger.new(journal:, stops:) }

  before do
    skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
  end

  def mkdir(name) = File.join(@base, name).tap { FileUtils.mkdir_p(_1) }

  def executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end

  def git(*args) = system(env, "git", *args, chdir: project, exception: true, out: File::NULL)

  def sandboxed(argv, extra = {})
    command = Lain::Confine::Bwrap.new(fence:).wrap(Lain::Shell::Term.of(argv), profile, trace_fd: 3)
    reader, writer = IO.pipe
    Open3.capture3(env.merge(extra), *command.stages.first.argv, chdir: project, 3 => writer)
    writer.close
    trace = Lain::Confine::Trace.new(StringIO.new(reader.read)).record(tool_use_id: "tu_1", profile: :workspace)
    JSON.parse(JSON.generate(trace.to_journal))
  end

  def folded(record, program)
    ledger << { "type" => "escalation", "tool" => "bash", "tool_use_id" => "tu_1",
                "requester" => Lain::Requester.main.name, "verdict" => "allow", "rung" => "auto", "reason" => "",
                "final" => false }
    ledger << { "type" => "exec_resolution", "tool_use_id" => "tu_1",
                "stages" => [{ "name" => File.basename(program), "resolved" => program, "realpath" => program,
                               "chain" => [], "klass" => "system", "fresh" => false }] }
    ledger << record
    journal.map { Lain::Journal.hash_of(_1)["signal"] }.compact
  end

  it "stops everyone for an honest commit whose project hook the sandbox refuses, an accepted false trip" do
    git("init", "-q")
    git("config", "user.email", "spec@example.com")
    git("config", "user.name", "spec")
    File.write(File.join(project, "a.txt"), "a\n")
    git("add", "a.txt")
    executable(File.join(project, ".git/hooks/pre-commit"))
    record = sandboxed(%w[git commit -q -m honest])

    expect(record["refusals"]).not_to be_empty
    expect(folded(record, "/usr/bin/git")).to include("refused_exec")
    expect(stops.standing(Lain::Requester.main)).to eq(:stopped)
  end

  it "stops everyone for a nested shell reaching a toolchain outside /usr, an accepted false trip" do
    bin = File.dirname(executable(File.join(home, Lain::Confine::Profile::INSTALLS, "tool/1.0/bin/lain-probe-tool")))
    record = sandboxed(["sh", "-c", "lain-probe-tool"], "PATH" => "#{bin}:/usr/bin")

    expect(record["refusals"].map { _1["path"] }).to include(File.join(bin, "lain-probe-tool"))
    expect(folded(record, "/usr/bin/sh")).to include("refused_exec")
    expect(stops.standing(Lain::Requester.main)).to eq(:stopped)
  end

  it "stops everyone for a PATH search refused on one entry that runs the program from a later one, " \
     "an accepted false trip" do
    stray = executable(File.join(mkdir("stray"), "true"))
    record = sandboxed(%w[env true], "PATH" => "#{File.dirname(stray)}:/usr/bin")

    expect(record["refusals"].map { _1["path"] }).to eq([stray])
    expect(record["execs"].map { _1.values_at("path", "rc") }.last(2)).to eq([[stray, -1], ["/usr/bin/true", 0]])
    expect(folded(record, "/usr/bin/env")).to include("refused_exec")
    expect(stops.standing(Lain::Requester.main)).to eq(:stopped)
  end

  it "still stops on a refused exec of a path outside every grant" do
    planted = executable(File.join(mkdir("elsewhere"), "planted"))
    record = sandboxed(["sh", "-c", planted])

    expect(folded(record, "/usr/bin/sh")).to include("refused_exec")
    expect(stops.standing(Lain::Requester.main)).to eq(:stopped)
  end
end
