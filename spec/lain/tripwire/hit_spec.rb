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
    SeedRepo::SCRUB.merge("GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1", "HOME" => home,
                          "LC_ALL" => "C")
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

  # The scrub guard reads the constant at the call site.
  def git(*args) = system(env.merge(SeedRepo::SCRUB), "git", *args, chdir: project, exception: true, out: File::NULL)

  def wrapped(argv)
    launcher = Lain::Confine::Bwrap.new(fence:)
    bound = launcher.masked(profile).bind(stages: 1, first_fd: 4)
    [launcher.wrap(Lain::Shell::Term.of(argv), profile, trace_fd: 3, bound:), bound]
  end

  def sandboxed(argv, extra = {})
    command, bound = wrapped(argv)
    reader, writer = IO.pipe
    Open3.capture3(env.merge(extra), *command.stages.first.argv, chdir: project, 3 => writer, **bound.fds)
    writer.close
    bound.close
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

  describe "a granted launcher's exec into its own toolchain root" do
    let(:launcher) { executable(File.join(home, ".cargo/bin/rustc")) }
    let(:toolchains) { File.join(home, ".rustup/toolchains") }
    let(:target) { executable(File.join(toolchains, "stable/bin/rustc")) }
    let(:launcher_fresh) { false }
    let(:resolution) do
      Lain::Tripwire::Resolution.new(
        [{ "name" => "rustc", "resolved" => launcher, "realpath" => launcher, "chain" => [], "klass" => "user",
           "fresh" => launcher_fresh }],
        fresh: Lain::Shell::Executable::Fresh.new(start: Time.now + 60, written: [],
                                                  stat: Lain::Shell::Executable::Stat.new),
        home:
      )
    end

    def scored(exec)
      record = { "tool_use_id" => "tu_1", "profile" => "reader", "truncated" => false, "refusals" => [],
                 "fd_execs" => [],
                 "execs" => [{ "path" => launcher, "rc" => 0 }, { "path" => exec, "rc" => 0 }] }
      described_class.of_exec_record(record, resolution).map(&:name)
    end

    it "scores nothing for the proxy exec'ing the toolchain's own tool" do
      expect(scored(target)).to be_empty
    end

    it "still scores a launcher exec'ing outside its root" do
      expect(scored(executable(File.join(mkdir("elsewhere"), "x")))).to eq(["unresolved_exec"])
    end

    it "still scores a toolchain linked into the root from outside it" do
      evil = executable(File.join(mkdir("evil"), "bin/rustc"))
      FileUtils.mkdir_p(toolchains)
      File.symlink(File.dirname(evil, 2), File.join(toolchains, "evil"))

      expect(scored(File.join(toolchains, "evil/bin/rustc"))).to eq(["unresolved_exec"])
    end

    it "still scores a launcher claiming a home that is not the real one" do
      planted = mkdir("planted")
      launcher_path = executable(File.join(planted, ".cargo/bin/rustc"))
      tool = executable(File.join(planted, ".rustup/toolchains/evil/bin/x"))
      allow(self).to receive(:launcher).and_return(launcher_path)

      expect(scored(tool)).to eq(["unresolved_exec"])
    end

    it "still scores a path under the root that cannot be resolved" do
      target
      expect(scored("#{toolchains}/stable/bin/../../../../etc/gone")).to eq(["unresolved_exec"])
    end

    it "still scores a link under the root deleted after the call ran it" do
      target
      link = File.join(toolchains, "stable/bin/lnk")
      File.symlink("/usr/bin/true", link)
      File.delete(link)

      expect(scored(link)).to eq(["unresolved_exec"])
    end

    it "still scores a sibling directory sharing the root's name as a prefix" do
      target
      expect(scored(executable(File.join(home, ".rustup/toolchains-evil/x")))).to eq(["unresolved_exec"])
    end

    context "when the launcher is itself fresh" do
      let(:launcher_fresh) { true }

      it "still scores the exec" do
        expect(scored(target)).to eq(["unresolved_exec"])
      end
    end
  end
end
