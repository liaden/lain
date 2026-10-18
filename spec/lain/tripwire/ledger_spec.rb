# frozen_string_literal: true

require "json"
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
                  incomplete: false)
    Lain::Telemetry::ExecRecord.new(tool_use_id: id, profile:, execs:, refusals:, fd_execs:, truncated:, incomplete:)
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
end
