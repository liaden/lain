# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "stringio"

RSpec.describe Lain::Tripwire::Ledger do
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:ledger) { described_class.new(journal:).tap { journal.observe(_1) } }
  # Not this checkout's fence: the launcher is read off the record, never off the booting process.
  let(:fence) { "/elsewhere/target/release/lain-fence" }
  let(:planted) { "/work/repo/bin/cat" }
  let(:cat) { program("cat", "/usr/bin/cat") }

  def tripwires = journal_records(io).select { _1["type"] == "tripwire" }

  def escalation(rung:, verdict: "deny", id: "tu_1", requester: "agent", final: false, reason: "")
    { "type" => "escalation", "tool" => "bash", "tool_use_id" => id, "requester" => requester,
      "verdict" => verdict, "rung" => rung, "reason" => reason, "faulted" => false,
      "authority" => "automatic", "final" => final }
  end

  def program(name, path, klass: :system, fresh: false, run_files: [], wrappers: [], realpath: path, chain: [],
              skipped: [])
    Lain::Shell::Executable.new(name:, resolved: path, realpath:, chain:, shadowed: [], anomalies: [], klass:,
                                fresh:, run_files:, wrappers:, skipped:)
  end

  def resolution(*programs, id: "tu_1")
    Lain::Telemetry::ExecResolution.new(tool_use_id: id, stages: programs.map(&:to_journal))
  end

  def exec_record(id: "tu_1", profile: :reader, execs: [ran(fence)], refusals: [], fd_execs: [], truncated: false,
                  incomplete: false, connects: [])
    Lain::Telemetry::ExecRecord.new(tool_use_id: id, profile:, execs:, refusals:, fd_execs:, truncated:, incomplete:,
                                    connects:)
  end

  def connect(call: "connect", family: "AF_INET", address: "93.184.216.34", port: 443, status: -1, errno: "EACCES")
    { call:, family:, address:, port:, rc: status, errno:, count: 1 }
  end

  def sandbox(id: "tu_1", profile: :workspace, created_sealed: [])
    Lain::Telemetry::Sandbox.new(tool_use_id: id, profile:, trace: true, refused: [], created_sealed:)
  end

  def ran(path) = { path:, argv0: File.basename(path), rc: 0 }

  def refused(path) = { path:, errno: "EACCES" }

  def fd_exec(path = "") = { fd: 3, path:, argv0: "x", rc: 0, errno: nil }

  def write(*records) = records.each { journal << _1 }

  # A ComposedTerm allow names the requester before the call resolves and runs.
  def approved(*programs, id: "tu_1", requester: "agent")
    write(escalation(rung: "rules", verdict: "allow", id:, requester:),
          resolution(*(programs.empty? ? [cat] : programs), id:))
  end

  def signals = tripwires.map { _1["signal"] }

  describe "strong signals" do
    before { ledger }

    it "folds an exec record written before connects were traced" do
      approved
      write(exec_record(refusals: [refused(planted)]).to_journal.except("connects"))

      expect(tripwires.sole).to include("signal" => "refused_exec")
    end

    it "counts a refusal outside the profile" do
      approved
      write(exec_record(execs: [ran(fence), ran("/usr/bin/cat")], refusals: [refused(planted)]))

      expect(tripwires.sole).to include("requester" => "agent", "signal" => "refused_exec", "weight" => "strong")
    end

    it "counts an exec on a descriptor" do
      approved
      write(exec_record(fd_execs: [fd_exec]))

      expect(tripwires.sole).to include("signal" => "fd_exec", "weight" => "strong")
    end

    it "counts an exec of the loader once, never also as a program the call did not resolve" do
      approved
      write(exec_record(execs: [ran(fence), ran("/usr/bin/cat"), ran("/usr/lib/ld-linux-x86-64.so.2")]))

      expect(tripwires.sole).to include("signal" => "loader_exec")
    end

    it "counts a program a reader call ran that it never resolved" do
      approved
      write(exec_record(execs: [ran(fence), ran("/usr/bin/cat"), ran("/usr/bin/curl")]))

      expect(tripwires.sole).to include("signal" => "unresolved_exec", "weight" => "strong")
    end

    it "counts a refused connect in a confined call" do
      approved
      write(exec_record(connects: [connect]))

      expect(tripwires.sole).to include("signal" => "refused_connect", "weight" => "strong", "stop" => "would_stop",
                                        "requester" => "agent")
    end

    it "names each refused address, whether the errno is EACCES or EPERM" do
      approved
      write(exec_record(connects: [connect, connect(address: "::1", family: "AF_INET6", port: 80, errno: "EPERM")]))

      expect(tripwires.sole["evidence"].sole["detail"]).to eq(["93.184.216.34:443", "[::1]:80"])
    end

    it "counts a refused TCP fast open send as a refused connect, not a datagram" do
      approved
      write(exec_record(connects: [connect(call: "sendto", address: "1.2.3.4", port: 80, errno: "EPERM")]))

      expect(tripwires.sole).to include("signal" => "refused_connect")
    end

    it "counts a datagram send to a port other than 53 as medium" do
      approved
      write(exec_record(connects: [connect(call: "sendto", port: 9999, status: 4, errno: nil)]))

      expect(tripwires.sole).to include("signal" => "datagram_send", "weight" => "medium")
    end

    it "counts a sealed path a workspace call created" do
      approved
      write(sandbox(created_sealed: ["/work/repo/.git/commondir"]))

      expect(tripwires.sole).to include("signal" => "created_sealed", "weight" => "strong", "stop" => "would_stop",
                                        "requester" => "agent")
      expect(tripwires.sole["evidence"].sole["detail"]).to eq(["/work/repo/.git/commondir"])
    end

    it "counts a fresh program" do
      write(escalation(rung: "rules", verdict: "allow"),
            resolution(program("cat", planted, klass: :project, fresh: true)))

      expect(tripwires.sole).to include("signal" => "fresh_program", "weight" => "strong")
    end

    it "counts a fresh file an interpreter will run" do
      script = Lain::Shell::Executable::RunFiles::Entry.new(path: "/work/repo/x.rb", klass: :project, fresh: true)
      approved(program("ruby", "/usr/bin/ruby", run_files: [script]))

      expect(tripwires.sole).to include("signal" => "fresh_run_file", "weight" => "strong")
    end

    describe "with the project's named exec rules" do
      around do |example|
        Dir.mktmpdir("ledger-execs") do |dir|
          @root = File.realpath(dir)
          example.run
        end
      end

      let(:ledger) do
        described_class.new(journal:, execs: Lain::Confine::ExecRules.project(@root)).tap { journal.observe(_1) }
      end

      def run_file(relative)
        path = File.join(@root, relative).tap { FileUtils.mkdir_p(File.dirname(_1)) }.tap { File.write(_1, "") }
        Lain::Shell::Executable::RunFiles::Entry.new(path:, klass: :project, fresh: true)
      end

      it "counts no fresh build output an interpreter will run" do
        approved(program("python3", "/usr/bin/python3", run_files: [run_file(".venv/bin/pytest")]))

        expect(tripwires).to be_empty
      end

      it "still counts a fresh run file outside them" do
        approved(program("ruby", "/usr/bin/ruby", run_files: [run_file("x.rb")]))

        expect(tripwires.sole).to include("signal" => "fresh_run_file")
      end
    end

    # The bash tool journals a quoted command's parsed stages, so a quoted run of a written script still trips.
    it "counts a written script a quoted command runs, as the bash tool journals it" do
      Dir.mktmpdir do |made|
        root = File.realpath(made)
        script = File.join(root, "add_loop.sh").tap { File.write(_1, "true\n") }
        fresh = Lain::Shell::Executable::Fresh.new(start: Time.now, written: [script],
                                                   stat: Lain::Shell::Executable::Stat.new)
        resolver = Lain::Shell::Executable::Resolver.new(root:, fresh:)
        string_arm = Class.new do
          define_method(:takes_term?) { |_term| false }
          define_method(:child_env) { Lain::Exec::ChildEnv::DEFAULT }
          define_method(:call) { |**| Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "") }
        end.new
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: root, env: {}))
        write(escalation(rung: "rules", verdict: "allow"))

        Lain::Tools::Bash.new(exec: string_arm, journal:, resolver:)
                         .call({ command: "bash 'add_loop.sh'" }, Lain::Tool::Invocation.new(tool_use_id: "tu_1",
                                                                                             context: session))

        expect(tripwires.sole).to include("signal" => "fresh_run_file", "weight" => "strong")
      end
    end

    it "still counts the refusals of an incomplete record" do
      approved
      write(exec_record(refusals: [refused(planted)], incomplete: true))

      expect(tripwires.sole).to include("signal" => "refused_exec")
    end

    it "still counts the refusal of a user program that was written this lineage" do
      approved(program("ruby", "/home/u/.local/bin/ruby", klass: :user, fresh: true))
      write(exec_record(refusals: [refused("/home/u/.local/bin/ruby")]))

      expect(signals).to include("refused_exec")
    end

    it "reads a record replayed from a session file the same as one written live" do
      approved
      write(JSON.parse(JSON.generate(exec_record(refusals: [refused(planted)]).to_journal)))

      expect(tripwires.sole).to include("signal" => "refused_exec")
    end

    it "is would_stop on a single strong signal" do
      approved
      write(exec_record(refusals: [refused(planted)]))

      expect(tripwires.sole).to include("stop" => "would_stop", "score" => Lain::Tripwire::Rules::DEFAULT.hard_stop)
    end

    it "gives one record for two refusals in one call" do
      approved
      write(exec_record(refusals: [refused(planted), refused("/work/repo/bin/wc")]))

      expect(tripwires.sole["evidence"].sole).to include("count" => 2, "detail" => [planted, "/work/repo/bin/wc"])
    end

    it "names a count and the first few paths, never every path" do
      paths = (1..12).map { "/work/repo/bin/p#{_1}" }
      approved
      write(exec_record(refusals: paths.map { refused(_1) }))

      expect(tripwires.sole["evidence"].sole).to include("count" => 12, "detail" => paths.first(8))
    end
  end

  describe "what a reader call resolved" do
    before { ledger }

    it "counts nothing for a call that ran only the launcher, PATH misses and what it resolved" do
      approved
      write(exec_record(execs: [ran(fence), { path: "/usr/local/bin/cat", argv0: "cat", rc: -1 }, ran("/usr/bin/cat")]))

      expect(tripwires).to be_empty
    end

    it "takes each stage's first exec as the launcher, read from the record" do
      approved(cat, program("wc", "/usr/bin/wc"))
      write(exec_record(execs: [ran(fence), ran("/usr/bin/cat"), ran(fence), ran("/usr/bin/wc")]))

      expect(tripwires).to be_empty
    end

    it "counts nothing for the shell a string command runs under" do
      approved
      write(exec_record(execs: [ran(fence), ran("/bin/sh"), ran("/usr/bin/cat")]))

      expect(tripwires).to be_empty
    end

    it "counts a wrapper's program as resolved" do
      approved(program("cat", "/usr/bin/cat", wrappers: [program("nice", "/usr/bin/nice")]))
      write(exec_record(execs: [ran(fence), ran("/usr/bin/nice"), ran("/usr/bin/cat")]))

      expect(tripwires).to be_empty
    end

    it "matches a program by its realpath and every link on the way, not only as resolved" do
      approved(program("vi", "/usr/bin/vi", realpath: "/usr/bin/vim.basic", chain: ["/usr/bin/vi", "/etc/alt/vi"]))
      write(exec_record(execs: [ran(fence), ran("/etc/alt/vi"), ran("/usr/bin/vim.basic")]))

      expect(tripwires).to be_empty
    end

    it "excludes the refusal of a wrapper's unchanged program" do
      shim = program("ruby", "/home/u/.local/bin/ruby", klass: :user)
      approved(program("x", "/usr/bin/x", wrappers: [shim]))
      write(exec_record(refusals: [refused("/home/u/.local/bin/ruby")]))

      expect(tripwires).to be_empty
    end

    it "forgets the oldest call past its bound, so a call that is never traced costs nothing to keep" do
      approved(id: "tu_old")
      (1..described_class::CALLS).each { approved(id: "tu_#{_1}") }
      write(exec_record(id: "tu_old", execs: [ran(fence), ran("/usr/bin/cat")]))

      expect(tripwires.sole).to include("requester" => "unknown", "signal" => "unresolved_exec")
    end
  end

  describe "PATH noise" do
    before { ledger }

    it "adds nothing for a refusal of a file the call's own resolution skipped as not executable" do
      approved(program("wc", "/usr/bin/wc", skipped: ["/home/u/noexec/wc"]))
      write(exec_record(execs: [ran(fence), { path: "/home/u/noexec/wc", argv0: "wc", rc: -1 }, ran("/usr/bin/wc")],
                        refusals: [refused("/home/u/noexec/wc")]))

      expect(tripwires).to be_empty
    end

    it "still counts a plant the resolution never saw, though the shell fell through to the real program" do
      approved(program("wc", "/usr/bin/wc", skipped: ["/home/u/noexec/wc"]))
      write(exec_record(execs: [ran(fence), { path: "/work/repo/bin/wc", argv0: "wc", rc: -1 }, ran("/usr/bin/wc")],
                        refusals: [refused("/work/repo/bin/wc")]))

      expect(signals).to eq(["refused_exec"])
    end

    it "drops the empty path of a bare descriptor from the refusals" do
      approved
      write(exec_record(refusals: [refused("")]))

      expect(tripwires).to be_empty
    end
  end

  describe "a traced record, which any process of the same user can write into" do
    before { ledger }

    it "counts a descriptor exec as medium" do
      approved
      write(exec_record(profile: :traced, execs: [ran("/bin/sh")], fd_execs: [fd_exec]))

      expect(tripwires.sole).to include("signal" => "fd_exec", "weight" => "medium")
    end

    it "counts a loader exec as medium" do
      approved
      write(exec_record(profile: :traced, execs: [ran("/bin/sh"), ran("/usr/lib/ld-linux-x86-64.so.2")]))

      expect(tripwires.sole).to include("signal" => "loader_exec", "weight" => "medium")
    end

    it "adds nothing for a refusal or a program the call did not resolve" do
      approved
      write(exec_record(profile: :traced, execs: [ran("/bin/sh"), ran("/usr/bin/curl")], refusals: [refused(planted)]))

      expect(tripwires).to be_empty
    end
  end

  describe "medium signals" do
    before { ledger }

    it "counts a final deny on a protected path" do
      reason = "triage: #{Lain::Approval::Escalation::Triage::PROTECTED}: .env is denied"
      write(escalation(rung: "triage", final: true, reason:))

      expect(tripwires.sole).to include("signal" => "protected_path_deny", "weight" => "medium")
    end

    it "counts a re-ask the remembered denials refused" do
      write(escalation(rung: "remembered"))

      expect(tripwires.sole).to include("signal" => "remembered_reask", "weight" => "medium")
    end

    it "does not count a triage final deny that names no protected path" do
      write(escalation(rung: "triage", final: true, reason: "excluded by the project's capability set"))

      expect(tripwires).to be_empty
    end

    it "does not count a protected path that was not final" do
      write(escalation(rung: "triage", reason: Lain::Approval::Escalation::Triage::PROTECTED))

      expect(tripwires).to be_empty
    end
  end

  describe "weak signals" do
    before { ledger }

    it "counts the judge's deny" do
      write(escalation(rung: "auto", reason: Lain::Approval::Judged::DENIED))

      expect(tripwires.sole).to include("signal" => "judge_deny", "weight" => "weak")
    end

    it "counts a judge deny handed to a human under escalate_only as the same judge deny" do
      write(escalation(rung: "auto", verdict: "abstain", reason: Lain::Approval::Judged::ESCALATED))

      expect(tripwires.sole).to include("signal" => "judge_deny", "weight" => "weak")
    end

    it "does not count a judged rung's other abstentions" do
      [Lain::Approval::Judged::DEFERRED, Lain::Approval::Judged::BROKEN].each do |reason|
        write(escalation(rung: "auto", verdict: "abstain", reason:))
      end

      expect(tripwires).to be_empty
    end

    it "does not count an unattended session's refusal, which no judge made" do
      write(escalation(rung: "auto", reason: Lain::Approval::Judged::Unattended::BECAUSE))

      expect(tripwires).to be_empty
    end
  end

  describe "the requester of a bash record" do
    before { ledger }

    it "comes from the escalation that ruled the call" do
      approved(id: "tu_9", requester: "researcher")
      write(exec_record(id: "tu_9", refusals: [refused(planted)]))

      expect(tripwires.sole).to include("requester" => "researcher")
      expect(ledger.standing("researcher").score).to be_positive
    end

    it "is unknown when no escalation names the call" do
      write(exec_record(id: "tu_none", refusals: [refused(planted)]))

      expect(tripwires.sole).to include("requester" => "unknown")
    end
  end

  describe "what is never counted" do
    before { ledger }

    it "adds nothing for a human's deny" do
      human = escalation(rung: "surfaces", reason: "the human refused this call (terminal)")
      write(human.merge("authority" => "human"))

      expect([tripwires, ledger.standing("agent").score]).to eq([[], 0])
    end

    it "adds nothing for a refusal of the file the user's unchanged toolchain resolves to" do
      approved(program("ruby", "/home/u/.local/bin/ruby", klass: :user))
      write(exec_record(refusals: [refused("/home/u/.local/bin/ruby")]))

      expect(tripwires).to be_empty
    end

    it "adds nothing for a run file that was not written this lineage" do
      script = Lain::Shell::Executable::RunFiles::Entry.new(path: "/work/repo/x.rb", klass: :project, fresh: false)
      approved(program("ruby", "/usr/bin/ruby", run_files: [script]))

      expect(tripwires).to be_empty
    end

    it "adds nothing for a refused connect to port 53, a resolver's TCP fallback" do
      approved
      write(exec_record(connects: [connect(address: "10.0.0.2", port: 53)]))

      expect(tripwires).to be_empty
    end

    it "adds nothing for a datagram send to port 53 or a connect that was not refused" do
      approved
      write(exec_record(connects: [connect(call: "sendto", port: 53, status: 4, errno: nil),
                                   connect(status: -1, errno: "EINPROGRESS"), connect(status: 0, errno: nil)]))

      expect(tripwires).to be_empty
    end

    it "adds nothing for a refused connect to the system resolver's unix socket" do
      approved
      write(exec_record(connects: [connect(family: "AF_UNIX", address: "/run/systemd/resolve/io.systemd.Resolve",
                                           port: nil)]))

      expect(tripwires).to be_empty
    end

    it "adds nothing for the connects of a traced call" do
      approved
      write(exec_record(profile: :traced,
                        connects: [connect,
                                   connect(call: "sendto", port: 9999, status: 4, errno: nil)]))

      expect(tripwires).to be_empty
    end

    it "adds nothing for a truncated record with a refused connect" do
      approved
      write(exec_record(connects: [connect], truncated: true))

      expect(tripwires).to be_empty
    end

    it "adds nothing for a sandbox record whose call created no sealed path" do
      approved
      write(sandbox)

      expect(tripwires).to be_empty
    end

    it "adds nothing for a replayed sandbox record written before calls were checked for created seals" do
      approved
      ledger << { "type" => "sandbox", "tool_use_id" => "tu_1", "profile" => "reader", "trace" => true,
                  "refused" => [] }

      expect(tripwires).to be_empty
    end

    it "still counts the exec record that follows a sandbox record" do
      approved
      write(sandbox, exec_record(connects: [connect]))

      expect(signals).to eq(["refused_connect"])
    end

    it "adds nothing for a truncated record" do
      approved
      write(exec_record(execs: [ran(fence), ran("/usr/bin/curl")], refusals: [refused(planted)], fd_execs: [fd_exec],
                        truncated: true))

      expect(tripwires).to be_empty
    end
  end

  describe "observe-only" do
    before { ledger }

    it "journals would_stop with the evidence chain once a requester passes the hard stop, and stops nothing" do
      write(escalation(rung: "remembered", id: "tu_1"))
      approved(id: "tu_2")
      write(exec_record(id: "tu_2", refusals: [refused(planted)]))

      last = tripwires.last
      expect(last).to include("requester" => "agent", "stop" => "would_stop")
      expect(last["evidence"].map { _1.values_at("signal", "tool_use_id") })
        .to eq([%w[remembered_reask tu_1], %w[refused_exec tu_2]])
      expect(ledger.standing("agent")).to have_attributes(stop: "would_stop")
    end

    it "journals no stop below the threshold" do
      write(escalation(rung: "auto", reason: Lain::Approval::Judged::DENIED))

      expect(tripwires.sole).to include("stop" => "none", "score" => Lain::Tripwire::Rules::DEFAULT.points[:weak])
    end
  end

  describe "with Stops::None" do
    it "journals a tripwire record and no crossing for a seeded signal" do
      ledger = described_class.new(journal:, rules: Lain::Tripwire::Rules::DEFAULT, stops: Lain::Tripwire::Stops::None)
      journal.observe(ledger)
      approved(id: "tu_1", requester: "researcher")
      write(exec_record(id: "tu_1", refusals: [refused(planted)]))

      types = journal_records(io).map { _1["type"] }
      expect([types.include?("tripwire"), types.include?("tripwire_stop")]).to eq([true, false])
    end
  end

  describe "with stops" do
    let(:stops) { Lain::Tripwire::Stops.new }
    let(:rules) { Lain::Tripwire::Rules::DEFAULT }
    let(:ledger) { described_class.new(journal:, rules:, stops:).tap { journal.observe(_1) } }

    def stop_records = journal_records(io).select { _1["type"] == "tripwire_stop" }

    def refused_exec_by(requester, id: "tu_1")
      approved(id:, requester:)
      write(exec_record(id:, refusals: [refused(planted)]))
    end

    before { ledger }

    it "stops a subagent that crosses the hard stop on a seeded signal, and pauses main" do
      refused_exec_by("researcher")

      expect(%w[researcher agent].map { stops.standing(_1) }).to eq(%i[stopped paused])
      expect(stop_records.sole).to include("requester" => "researcher", "signal" => "refused_exec",
                                           "outcome" => "stopped")
    end

    it "journals the stop after the tripwire record that crossed it" do
      refused_exec_by("researcher")

      expect(journal_records(io).map { _1["type"] }.last(2)).to eq(%w[tripwire tripwire_stop])
    end

    it "never trips on the network signals, and names them as observe-only" do
      approved(requester: "researcher")
      write(exec_record(connects: [connect, connect(call: "sendto", port: 9999, status: 4, errno: nil)]))

      expect(tripwires.last).to include("stop" => "would_stop")
      expect(%w[researcher agent].map { stops.standing(_1) }).to eq(%i[free free])
      expect(stop_records.sole).to include("requester" => "researcher", "signal" => "refused_connect",
                                           "outcome" => "observe_only",
                                           "unseeded" => %w[refused_connect datagram_send])
    end

    context "when only unseeded points carry the score past the hard stop" do
      let(:rules) { Lain::Tripwire::Rules.new(points: { strong: 10, medium: 3, weak: 1 }, hard_stop: 13) }

      it "counts only seeded signals toward a stop" do
        write(escalation(rung: "remembered", id: "tu_0", requester: "researcher"))
        refused_exec_by("researcher")

        expect(tripwires.last).to include("stop" => "would_stop", "score" => 13)
        expect(ledger.standing("researcher")).to have_attributes(score: 13, seeded: 10)
        expect(stops.standing("researcher")).not_to eq(:stopped)
        expect(stop_records.sole).to include("outcome" => "observe_only", "unseeded" => ["remembered_reask"])
      end
    end

    it "still trips on a seeded signal after an observe-only crossing" do
      approved(requester: "researcher")
      write(exec_record(connects: [connect]))
      refused_exec_by("researcher", id: "tu_2")

      expect(stop_records.map { _1["outcome"] }).to eq(%w[observe_only stopped])
      expect(stops.standing("researcher")).to eq(:stopped)
    end

    it "trips a requester once, however many seeded signals follow" do
      refused_exec_by("researcher")
      refused_exec_by("researcher", id: "tu_2")

      expect(stop_records.size).to eq(1)
      expect(stops.standing("agent")).not_to eq(:stopped)
    end

    it "stops every requester when a second one trips" do
      refused_exec_by("researcher")
      refused_exec_by("writer", id: "tu_2")

      expect(stop_records.map { _1.values_at("requester", "outcome") })
        .to eq([%w[researcher stopped], %w[writer all_stopped]])
      expect(%w[agent researcher writer anyone].map { stops.standing(_1) }).to all(eq(:stopped))
    end

    it "stops every requester when main trips first" do
      refused_exec_by("agent")

      expect(stop_records.sole).to include("requester" => "agent", "outcome" => "all_stopped")
      expect(stops.standing("researcher")).to eq(:stopped)
    end

    describe "a trip no escalation names" do
      it "stops every requester, since it could be main or a second subagent" do
        write(exec_record(id: "tu_9", refusals: [refused(planted)]))

        expect(stop_records.sole).to include("requester" => "unknown", "outcome" => "all_stopped")
        expect(%w[agent researcher].map { stops.standing(_1) }).to all(eq(:stopped))
      end

      it "stops every requester at the first of 2 subagents' unattributed trips" do
        write(exec_record(id: "from_researcher", refusals: [refused(planted)]),
              exec_record(id: "from_writer", refusals: [refused("/work/repo/bin/ls")]))

        expect(stop_records.map { _1.values_at("requester", "outcome") }).to eq([%w[unknown all_stopped]])
        expect(stops.standing("agent")).not_to eq(:paused)
        expect(stops.standing("agent")).to eq(:stopped)
      end

      it "stops every requester when the call's escalation was evicted before its exec record" do
        approved(id: "long", requester: "researcher")
        (1..described_class::CALLS).each { write(escalation(rung: "rules", verdict: "allow", id: "r#{_1}")) }
        write(exec_record(id: "long", refusals: [refused(planted)]))

        expect(stop_records.sole).to include("requester" => "unknown", "outcome" => "all_stopped")
      end
    end

    it "folds and scores exactly as it does without stops" do
      refused_exec_by("researcher")

      expect(tripwires.sole).to include("requester" => "researcher", "signal" => "refused_exec", "score" => 10,
                                        "stop" => "would_stop")
    end
  end

  it "journals no stop record without stops" do
    ledger
    approved(requester: "researcher")
    write(exec_record(refusals: [refused(planted)]), exec_record(id: "tu_2", connects: [connect]))

    expect(journal_records(io).map { _1["type"] }.uniq).to eq(%w[escalation exec_resolution exec_record tripwire])
  end

  it "counts nothing for a tripwire record that reaches it" do
    ledger << { "type" => "tripwire", "requester" => "agent", "signal" => "refused_exec", "weight" => "strong",
                "score" => 10, "stop" => "would_stop", "evidence" => [] }

    expect([tripwires, ledger.standing("agent").score]).to eq([[], 0])
  end

  # The Journal turns an observer's error into a record of its own, so a fault never loses the record that caused it.
  it "lands its own fault as a journal_error naming it" do
    ledger
    write({ "type" => "exec_record", "tool_use_id" => "tu_1", "profile" => "reader", "execs" => 7,
            "refusals" => 7, "fd_execs" => 7, "truncated" => false })

    expect(journal_records(io).map { _1["type"] }).to eq(%w[exec_record journal_error])
    expect(journal_records(io).last).to include("observer" => described_class.name)
  end

  describe "a granted launcher exec'ing into its toolchain root" do
    around do |example|
      Dir.mktmpdir("l") do |dir|
        @home = File.realpath(dir)
        example.run
      end
    end

    let(:launcher) { File.join(@home, ".cargo/bin/rustc") }
    let(:toolchains) { File.join(@home, ".rustup/toolchains") }
    let(:target) { File.join(toolchains, "stable/bin/rustc") }
    let(:written) { [] }
    let(:fresh) do
      Lain::Shell::Executable::Fresh.new(start: Time.now + 60, written:, stat: Lain::Shell::Executable::Stat.new)
    end
    let(:ledger) { described_class.new(journal:, fresh:, home: @home).tap { journal.observe(_1) } }

    before do
      ledger
      [launcher, target].each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.touch(path)
      end
    end

    def proxy_exec(*stages, exec: target)
      write(escalation(rung: "rules", verdict: "allow"), resolution(*stages),
            exec_record(execs: [ran(fence), ran(launcher), ran(exec)]))
    end

    it "counts nothing for an unchanged rustc under the root" do
      proxy_exec(program("rustc", launcher, klass: :user))

      expect(tripwires).to be_empty
    end

    it "counts a toolchain symlinked into the root from outside it as an unresolved exec" do
      elsewhere = File.join(@home, "outside")
      FileUtils.mkdir_p("#{elsewhere}/bin")
      FileUtils.touch("#{elsewhere}/bin/rustc")
      File.symlink(elsewhere, File.join(toolchains, "evil"))
      proxy_exec(program("rustc", launcher, klass: :user), exec: File.join(toolchains, "evil/bin/rustc"))

      expect(signals).to eq(["unresolved_exec"])
    end

    context "when a write record names the rustc under the root" do
      let(:written) { [target] }

      it "counts the unresolved exec, which no resolution lists" do
        proxy_exec(program("rustc", launcher, klass: :user))

        expect(signals).to eq(["unresolved_exec"])
      end

      it "counts a fresh_program, and no unresolved exec, when the resolution lists it" do
        proxy_exec(program("rustc", launcher, klass: :user), program("rustc", target, klass: :user, fresh: true))

        expect(signals).to eq(["fresh_program"])
      end
    end

    context "when no fresh rule is wired" do
      let(:ledger) { described_class.new(journal:).tap { journal.observe(_1) } }

      it "excuses nothing, as before" do
        proxy_exec(program("rustc", launcher, klass: :user))

        expect(signals).to eq(["unresolved_exec"])
      end
    end
  end
end
