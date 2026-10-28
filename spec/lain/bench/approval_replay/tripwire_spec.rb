# frozen_string_literal: true

require "json"
require "tmpdir"
require "stringio"

RSpec.describe Lain::Bench::ApprovalReplay::Tripwire do
  let(:dir) { Dir.mktmpdir }
  let(:fence) { "/elsewhere/target/release/lain-fence" }
  let(:default) { Lain::Tripwire::Rules::DEFAULT }

  after { FileUtils.remove_entry(dir) }

  def command(id) = { "command" => "echo #{id}" }

  def digest_of(id) = Lain::Canonical.digest(["bash", command(id), nil])

  def turn(ids)
    { "type" => "turn", "role" => "assistant",
      "content" => ids.map { { "type" => "tool_use", "id" => _1, "name" => "bash", "input" => command(_1) } } }
  end

  def reask(id, requester)
    { "type" => "escalation", "tool" => "bash", "tool_use_id" => id, "requester" => requester, "verdict" => "deny",
      "rung" => Lain::Middleware::RememberedDenials::RUNG, "reason" => "again", "faulted" => false,
      "authority" => "automatic", "final" => false }.compact
  end

  def judge_deny(id, requester)
    reask(id, requester).merge("rung" => Lain::Approval::Judged::NAME, "reason" => Lain::Approval::Judged::DENIED)
  end

  def refused_exec(id)
    Lain::Telemetry::ExecRecord.new(tool_use_id: id, profile: :reader, fd_execs: [], truncated: false,
                                    incomplete: false, connects: [],
                                    execs: [{ path: fence, argv0: "lain-fence", rc: 0 }],
                                    refusals: [{ path: "/work/bin/cat", errno: "EACCES" }]).to_journal
  end

  def write(name, records)
    File.join(dir, name).tap { |path| File.write(path, records.map { JSON.generate(_1) }.join("\n")) }
  end

  # A requester that asks `n` calls, each refused again by a remembered deny: 4 are medium enough to trip.
  def session(name, requester: "subagent:a", asks: 4)
    ids = Array.new(asks) { "#{name}_#{_1}" }
    write(name, [turn(ids), *ids.map { reask(_1, requester) }])
  end

  def labels_for(session_name, asks, label: "routine")
    path = File.join(dir, "#{session_name}.labels.jsonl")
    File.write(path, Array.new(asks) { JSON.generate("digest" => digest_of("#{session_name}_#{_1}"), "label" => label) }
                          .join("\n"))
    Lain::Bench::ApprovalReplay::Score.labels_from(path)
  end

  def tripwire(*journals, labels: Lain::Bench::Labels::NONE, rules: [default])
    described_class.new(journals:, labels:, rules:)
  end

  describe "folding" do
    it "stands a requester where a live ledger journaled it, for a refused exec and two judge denials" do
      ids = %w[t1 t2 t3]
      records = [turn(ids), judge_deny("t1", "subagent:a"), judge_deny("t2", "subagent:a"),
                 reask("t3", "subagent:a"), refused_exec("t3")]
      path = write("mixed", records)
      io = StringIO.new
      journal = Lain::Journal.new(io:)
      journal.observe(Lain::Tripwire::Ledger.new(journal:))
      records.each { journal << _1 }
      live = journal_records(io).select { _1["type"] == "tripwire" }.last
      labels = Lain::Bench::Labels.new(ids.to_h { [digest_of(_1), "routine"] })
      at = ->(stop) { tripwire(path, labels:, rules: [default.with(hard_stop: stop)]).rows.sole }

      expect(live["stop"]).to eq("would_stop")
      expect(at.call(live["score"])).to have_attributes(tripped: 1)
      expect(at.call(live["score"] + 1)).to have_attributes(tripped: 0)
      expect(at.call(live["score"]).signals).to eq("subagent:a" => live["evidence"].map { _1["signal"] }.uniq.sort)
    end

    it "leaves the session file's bytes as they were" do
      path = session("same")
      before = File.binread(path)

      tripwire(path).report

      expect(File.binread(path)).to eq(before)
    end

    it "counts a judge deny a human was handed as a weak hit, as the live ledger does" do
      escalated = judge_deny("j1", "subagent:a").merge("verdict" => "abstain",
                                                       "reason" => Lain::Approval::Judged::ESCALATED)
      path = write("handed", [turn(%w[j1]), escalated])

      expect(tripwire(path).rows.sole.rules).to eq(default)
      expect(tripwire(path, rules: [default.with(hard_stop: 1)]).rows.sole.tripped).to eq(1)
      expect(tripwire(path, rules: [default.with(hard_stop: 2)]).rows.sole.tripped).to eq(0)
    end
  end

  describe "#rows" do
    it "counts a trip on a requester whose calls are all routine as a false trip, naming its signals" do
      path = session("s1")
      row = tripwire(path, labels: labels_for("s1", 4)).rows.sole

      expect(row).to have_attributes(sessions: 1, tripped: 1, false_trips: 1)
      expect(row.signals).to eq("subagent:a" => %w[remembered_reask])
    end

    it "does not call a trip false when a call of the requester is harmful or unlabelled" do
      path = session("s2")
      harmful = labels_for("s2", 4, label: "harmful")
      row = tripwire(path, labels: harmful).rows.sole
      partly = tripwire(path, labels: labels_for("s2", 3)).rows.sole

      expect([row.false_trips, partly.false_trips]).to eq([0, 0])
      expect(row.tripped).to eq(1)
    end

    it "does not trip a requester below the hard stop" do
      path = session("quiet", asks: 2)

      expect(tripwire(path, labels: labels_for("quiet", 2)).rows.sole).to have_attributes(tripped: 0, false_trips: 0)
    end

    it "counts false trips per session with the Wilson interval of the sessions" do
      paths = Array.new(12) { |index| session("n#{index}", asks: index < 2 ? 4 : 1) }
      labels = Lain::Bench::Labels.new(Array.new(12) { |index| Array.new(4) { digest_of("n#{index}_#{_1}") } }
                                          .flatten.to_h { [_1, "routine"] })
      row = tripwire(*paths, labels:).rows.sole
      interval = Lain::Compare::Stats.wilson(2, 12)

      expect(row).to have_attributes(sessions: 12, tripped: 2, false_trips: 2, low: interval.low, high: interval.high)
      expect(tripwire(*paths, labels:).report).to include("false trips: 2 of 12 sessions")
    end

    it "adds a row for alternative rules beside the default" do
      path = session("s3")
      strict = default.with(hard_stop: 13)
      rows = tripwire(path, labels: labels_for("s3", 4), rules: [default, strict]).rows

      expect(rows.map(&:rules)).to eq([default, strict])
      expect(rows.map(&:tripped)).to eq([1, 0])
    end
  end

  describe "#report" do
    it "prints trips per session and says the false-trip rate needs labels when there are none" do
      out = tripwire(session("s4")).report

      expect(out).to include("tripped: 1 of 1 session", "false-trip rate needs labels")
      expect(out).not_to include("false trips:")
    end

    it "names the false-tripping requester and its signals" do
      out = tripwire(session("s5"), labels: labels_for("s5", 4)).report

      expect(out).to include("false trips: 1 of 1 session", "subagent:a (remembered_reask)")
    end

    it "counts a session tripped only under unknown as tripped, not false, and says it was not checked" do
      path = write("anon_strong", [turn(%w[a_0]), refused_exec("a_0")])
      labels = Lain::Bench::Labels.new({ digest_of("a_0") => "routine" })
      out = tripwire(path, labels:).report

      expect(out).to include("tripped: 1 of 1 session", "false trips: 0 of 1 session",
                             "1 session tripped with no requester named (default rules)",
                             "not checked against the labels")
    end

    it "says so when a session named no requester, and attributes its hits to unknown" do
      path = write("anon", [turn(%w[a_0]), reask("a_0", nil)])

      expect(tripwire(path).report).to include("1 hit named no requester (default rules)", "unknown")
    end

    it "marks the default rules and shows an alternative beside them" do
      out = tripwire(session("s6"), rules: [default, default.with(hard_stop: 13)]).report

      expect(out).to include("hard_stop=10 (default)", "hard_stop=13")
    end
  end

  describe ".rules_from" do
    it "reads key=value overrides of the default into one rules each" do
      expect(described_class.rules_from(["hard_stop=13", "hard_stop=20,weak=2"]))
        .to eq([default, default.with(hard_stop: 13),
                Lain::Tripwire::Rules.new(points: default.points.merge(weak: 2), hard_stop: 20)])
    end

    it "refuses an unknown key, naming the valid ones" do
      expect { described_class.rules_from(["stop=3"]) }
        .to raise_error(Lain::Bench::CLI::Refusal, /stop.*hard_stop, strong, medium, weak/)
    end

    it "refuses a pair that is not key=value, a value below 1 and a key given twice, naming the form and the keys" do
      %w[hard_stop hard_stop= =3 a=b=c hard_stop=0 hard_stop=-5 hard_stop=10,hard_stop=12 hard_stop=1.5].each do |spec|
        expect { described_class.rules_from([spec]) }
          .to raise_error(Lain::Bench::CLI::Refusal, /key=value.*hard_stop, strong, medium, weak/), spec
      end
    end

    it "drops a rule set identical to an earlier one, the default included" do
      expect(described_class.rules_from(["hard_stop=10", "weak=2", "weak=2", "hard_stop=13"]).map(&:hard_stop))
        .to eq([10, 10, 13])
    end

    it "refuses a value that is not a whole number" do
      expect { described_class.rules_from(["hard_stop=many"]) }.to raise_error(Lain::Bench::CLI::Refusal, /many/)
    end
  end

  describe "through the replay" do
    let(:fixtures) { ApprovalReplayFixtures::DIR }

    it "appends the tripwire section to the approval replay report, from the real fixtures" do
      replay = Lain::Bench::ApprovalReplay.asked(sessions: [File.join(fixtures, "ask.ndjson")], approvals: %w[ask],
                                                 rules: [], approver: "recorded", project: ApprovalReplayFixtures.place,
                                                 labels: File.join(fixtures, "labels.jsonl"),
                                                 tripwire: true, tripwire_rules: ["hard_stop=13"])

      expect(replay.report).to include("tripwire replay", "hard_stop=10 (default)", "hard_stop=13", "false trips:")
    end

    it "adds nothing unless asked" do
      replay = Lain::Bench::ApprovalReplay.asked(sessions: [File.join(fixtures, "ask.ndjson")], approvals: %w[ask],
                                                 rules: [], approver: "recorded", project: ApprovalReplayFixtures.place)

      expect(replay.report).not_to include("tripwire replay")
    end
  end
end
