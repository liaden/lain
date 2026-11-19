# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module AgendaSpecSupport
  Submission = Data.define(:digest, :issue_id, :criteria_digest, :gate_question) do
    def fact = gate_question
  end

  # Real gates, with a hook that runs before each answer lands: the desk answering first.
  class RacingGates < SimpleDelegator
    def initialize(gates, &before)
      super(gates)
      @before = before
    end

    def deny(digest, reason: nil, answered_by: nil)
      @before.call(digest)
      __getobj__.deny(digest, reason:, answered_by:)
    end
  end

  # Gate rows held in memory, recording each answer in the order it lands.
  class RecordingGates
    Row = Lain::Remote::Agenda::Gates::Row

    attr_reader :answers

    def initialize(*issues, stage: "issue_plan", digests: issues.map { "blake3:#{_1 || stage}" })
      @rows = issues.zip(digests).map do |issue, digest|
        Row.new(digest:, epic: "alpha", stage:, issue:, question: "#{issue || stage}?", asked_at: Time.utc(2026, 11, 4))
      end
      @answers = []
    end

    def each(&block) = @rows.each(&block)
    def approve(digest, reason: nil, answered_by: nil) = @answers << [:approve, digest, reason, answered_by]
    def deny(digest, reason: nil, answered_by: nil) = @answers << [:deny, digest, reason, answered_by]
  end
end

# Everything waiting on a human, polled from its owners: the parked tool calls,
# the deferred epic gates and the open ask_human questions.
RSpec.describe Lain::Remote::Agenda do
  subject(:agenda) { described_class.new(queue:, gates:, replies:, wall: -> { now }) }

  around do |example|
    Dir.mktmpdir { |dir| @state_home = dir and example.run }
  end

  let(:paths) { Lain::Paths.new(env: SpecHome.env({ "XDG_STATE_HOME" => @state_home })) }
  let(:root) { File.join(@state_home, "project").tap { FileUtils.mkdir_p(_1) } }
  let(:now) { Time.utc(2026, 11, 4, 9, 0, 0) }
  let(:queue) { Lain::Approval::Parked::Queue.new(journal: Lain::Journal.new(io: StringIO.new)) }
  let(:gates) { described_class::Gates.new(paths:, root:) }
  # The real reply side a chat wires: the askers, and the replies `/inbox` drains.
  let(:asked_journal) { [] }
  let(:askers) do
    Lain::CLI::Wiring::Askers.new(human: Lain::CLI::Human.new(kind: :terminal),
                                  observer: Lain::EventLog::ChainWriter::Null.new, journal: asked_journal)
  end
  let(:asker) do
    parent = Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    askers.enrol(parent, agent: "researcher").asker
  end
  let(:output) { StringIO.new }
  let(:tty) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new,
                            history_path: File.join(@state_home, "history"))
  end
  let(:conductor) do
    instance_double(Lain::CLI::Conductor, counting_down?: false, prompting?: false, read_command: nil)
  end
  let(:replies) do
    Lain::CLI::HumanReplies.new(tty:, conductor:, ask_human: askers.directory, questions: askers.questions)
  end
  let(:question_digest) { replies.waiting.first.digest }
  let(:digest_a) { "blake3:#{"a" * 64}" }
  let(:digest_b) { "blake3:#{"b" * 64}" }

  before { asker.ask("Which crate owns the parser?") }

  def submission(id, digest)
    AgendaSpecSupport::Submission.new(digest:, issue_id: id, criteria_digest: nil,
                                      gate_question: "Approve the issue plan for #{id}?")
  end

  def wave
    Lain::Epic::Submission::Wave.new(slug: "alpha", number: 1,
                                     submissions: [submission("a", digest_a), submission("b", digest_b)])
  end

  # The real Deferred policy, journaling where a chat files its journal, so the
  # agenda reads the gate the way `lain epic queue` does.
  def defer_wave
    signoffs = Lain::Epic::SignoffQueue.new
    %w[research epic_plan].each do |stage|
      signoffs.apply(Lain::Epic::GateDecision.new(artifact_digest: "blake3:#{stage}", epic_slug: "alpha", stage:,
                                                  verdict: Lain::Approval::Verdict::Approve.new,
                                                  answered_by: "human", policy: "signoff", latency: 1.0).to_journal)
    end
    Lain::Journal.open(paths:, root:) do |journal|
      gate = Lain::Epic::Gate.new(journal:, timeout: 0.5)
      Sync do
        current = Data.define { def digest(_epic_slug, stage, _issue_id) = "blake3:#{stage}" }.new
        Lain::Epic::Gate::Policy::Deferred.new(queue: signoffs, digests: current, journal:)
                                          .decide(wave, gate:, stage: "issue_plan", epic_slug: "alpha")
      end
    end
  end

  def park(task, input = { "command" => "cargo test" })
    task.async { queue.call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input:), nil) }
    task.yield
    queue.find { _1.input == input }
  end

  def kinds(items) = items.map { _1.class.name.demodulize }

  def listed(kind) = listed_in(agenda, kind)

  def listed_in(subject, kind) = subject.snapshot.find { kinds([_1]) == [kind] }

  def gate_records
    Dir[File.join(paths.filing_dir(root:), "*")].flat_map { journal_records(Pathname(_1), "gate_decision") }
  end

  describe "the agenda lists every kind" do
    it "lists a parked call, a deferred wave gate and an ask_human question" do
      defer_wave
      Sync do |task|
        park(task)
        items = agenda.snapshot

        expect(kinds(items)).to contain_exactly("ParkedCall", "GateQuestion", "Question")
        task.stop
      end
    end

    it "carries each item's facts, with a distinct id per item" do
      defer_wave
      Sync do |task|
        park(task)
        call, gate, question = %w[ParkedCall GateQuestion Question].map { listed(_1) }

        expect(call).to have_attributes(requester: "agent", tool: "bash", input: { "command" => "cargo test" })
        expect(gate).to have_attributes(epic: "alpha", stage: "issue_plan", issues: %w[a b])
        expect(gate.question).to include("Approve the issue plan for a?", "Approve the issue plan for b?")
        expect(question).to have_attributes(requester: "researcher", question: "Which crate owns the parser?",
                                            options: [], asked_at: replies.waiting.first.asked_at)
        expect([call, gate, question].map(&:id).uniq.size).to eq(3)
        task.stop
      end
    end

    it "counts the regions a call would release, 0 for an ordinary call, and never carries the regions" do
      regions = Lain::Sensitivity::Regions.detect("a=ghp_6Fz9qL2vX8mN4pR7tY1wK3sD5hJ0aB2cE4gI\n" \
                                                  "b=AKIAIOSFODNN7EXAMPLE\n")
      calls = []
      Sync do |task|
        park(task)
        read = Lain::Effect::ToolCall.new(tool_use_id: "tu_2", name: "read_file", input: { "path" => "/tmp/r/.env" })
        outstanding = Lain::Approval::Parked::Queue::Outstanding.new(path: "/tmp/r/.env", regions:)
        task.async { queue.adjudicate(read, nil, outstanding:) }
        task.yield
        calls = agenda.snapshot.select { kinds([_1]) == ["ParkedCall"] }
      ensure
        task.stop
      end

      expect(regions.size).to eq(2)
      expect(calls.to_h { [_1.tool, _1.releases] }).to eq("bash" => 0, "read_file" => 2)
      expect(calls).to all(satisfy { Ractor.shareable?(_1) })
    end

    it "carries releases 0 on a gate and a question, which never release a file's regions" do
      defer_wave

      expect(%w[GateQuestion Question].map { listed(_1).releases }).to eq([0, 0])
    end

    it "is frozen all the way down" do
      Sync do |task|
        park(task)
        expect(agenda.snapshot).to all(satisfy { Ractor.shareable?(_1) })
        task.stop
      end
    end

    it "lists no postponed call: a hold sends the call back to the agent" do
      Sync do |task|
        park(task).decide(Lain::Approval::Verdict::Hold.new(note: "after lunch"), surface: "tty", authority: :human)
        task.yield

        expect(kinds(agenda.snapshot)).to eq(["Question"])
        task.stop
      end
    end
  end

  describe "a gate a human held" do
    it "is listed with the parked ones, and answering it journals as `lain epic approve` would" do
      Lain::Journal.open(paths:, root:) do |journal|
        journal.record(Lain::Epic::GateDecision.new(artifact_digest: digest_a, epic_slug: "alpha", stage: "research",
                                                    verdict: Lain::Approval::Verdict::Hold.new(note: "later"),
                                                    answered_by: "human", policy: "interactive", latency: 1.0))
      end

      expect(gates.each.map(&:digest)).to eq([digest_a])
      gates.deny(digest_a, reason: "no")
      expect(gates.each.to_a).to be_empty
    end
  end

  describe "when a gate was asked" do
    def gate_waits
      Dir[File.join(paths.filing_dir(root:), "*")].flat_map { journal_records(Pathname(_1), "awaiting_human") }
    end

    def deferral(digest, issue_id, at)
      Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: "alpha", stage: "issue_plan",
                                   verdict: Lain::Epic::GateDecision::Deferred.new, answered_by: "deferred",
                                   policy: "deferred", latency: 0.0, issue_id:).to_journal.merge("ts" => at)
    end

    it "is the earliest wait the gate journaled" do
      defer_wave

      expect(listed("GateQuestion").asked_at).to eq(gate_waits.map { Time.iso8601(_1["ts"]) }.min)
    end

    it "falls back to the gate's own records when no wait was journaled" do
      FileUtils.mkdir_p(paths.filing_dir(root:))
      File.write(File.join(paths.filing_dir(root:), "old.ndjson"),
                 [deferral(digest_a, "a", "2026-11-03T08:00:05.000000Z"),
                  deferral(digest_b, "b", "2026-11-03T08:00:03.000000Z"),
                  deferral(digest_a, "a", "2026-11-03T08:00:01.000000Z")].map { "#{JSON.generate(_1)}\n" }.join)

      expect(listed("GateQuestion").asked_at).to eq(Time.iso8601("2026-11-03T08:00:01Z"))
    end
  end

  describe "a journal holding a gate record from before verdicts" do
    def gate_record
      Lain::Epic::GateDecision.new(artifact_digest: digest_a, epic_slug: "alpha", stage: "research",
                                   verdict: Lain::Epic::GateDecision::Deferred.new, answered_by: "deferred",
                                   policy: "deferred", latency: 0.0).to_journal
                              .merge("ts" => "2026-11-02T08:00:00.000000Z")
    end

    def write_gate_record(record)
      FileUtils.mkdir_p(paths.filing_dir(root:))
      File.write(File.join(paths.filing_dir(root:), "old.ndjson"), "#{JSON.generate(record)}\n")
    end

    def write_old_gate_record = write_gate_record(gate_record.except("verdict").merge("approved" => false))

    it "lists the parked calls and questions, and 1 gate item naming the record and no rewrite command" do
      write_old_gate_record
      Sync do |task|
        park(task)

        expect(kinds(agenda.snapshot)).to contain_exactly("ParkedCall", "Question", "GateQuestion")
        expect(listed("GateQuestion")).to have_attributes(issues: [], question: /#{digest_a}.*verdict/)
        expect(listed("GateQuestion").question).not_to include("rewrite")
        task.stop
      end
    end

    it "carries releases 0 on the gate item standing in for that journal" do
      write_old_gate_record

      expect(listed("GateQuestion").releases).to eq(0)
    end

    it "refuses any answer to that gate item, naming no rewrite command" do
      write_old_gate_record

      expect { agenda.answer(listed("GateQuestion").id, Lain::Approval::Verdict::Approve.new) }
        .to raise_error(ArgumentError) { |error|
          expect(error.message).to include("cannot be read")
          expect(error.message).not_to include("rewrite")
        }
    end

    it "lists a gate record whose verdict it cannot read the same way, beside the calls and questions" do
      write_gate_record(gate_record.merge("verdict" => "maybe"))
      Sync do |task|
        park(task)

        expect(kinds(agenda.snapshot)).to contain_exactly("ParkedCall", "Question", "GateQuestion")
        expect(listed("GateQuestion")).to have_attributes(issues: [], question: /maybe/)
        task.stop
      end
    end
  end

  describe "answering routes to the owner" do
    it "records a deny for issue b as `lain epic deny` would, and leaves a parked" do
      defer_wave
      gate = listed("GateQuestion")

      agenda.answer(gate.id, { "b" => Lain::Approval::Verdict::Deny.new(note: "wrong crate") })

      expect(gate_records.last).to include("artifact_digest" => digest_b, "issue_id" => "b", "verdict" => "deny",
                                           "reason" => "wrong crate", "answered_by" => "remote",
                                           "policy" => "signoff")
      expect(listed("GateQuestion").issues).to eq(%w[a])
    end

    it "offers the phone approve, hold and deny only, and refuses a deferred answer to a deferred gate" do
      defer_wave

      expect(gate_records.map { _1["verdict"] }.uniq).to eq(["deferred"])
      expect(Lain::Remote::Wire::Verdict::VARIANTS.values)
        .to eq([Lain::Approval::Verdict::Approve, Lain::Approval::Verdict::Hold, Lain::Approval::Verdict::Deny])
      expect { agenda.answer(listed("GateQuestion").id, Lain::Epic::GateDecision::Deferred.new) }
        .to raise_error(ArgumentError, /not a verdict/)
    end

    it "refuses a hold from an older app build with a reason, journaling nothing, and the gate stays answerable" do
      defer_wave
      before = gate_records.size
      gate = listed("GateQuestion")
      held = { "a" => Lain::Approval::Verdict::Approve.new, "b" => Lain::Approval::Verdict::Hold.new(note: "later") }

      expect { agenda.answer(gate.id, held) }.to raise_error(ArgumentError, /cannot be held/)
      expect { agenda.answer(gate.id, Lain::Approval::Verdict::Hold.new) }
        .to raise_error(ArgumentError, /cannot be held/)
      expect([gate_records.size, listed("GateQuestion").issues]).to eq([before, %w[a b]])
      expect(agenda.answer(gate.id, { "b" => Lain::Approval::Verdict::Deny.new })).to be(true)
    end

    it "refuses a gate answer with no verdicts, journaling nothing, and the gate stays answerable" do
      defer_wave
      before = gate_records.size
      gate = listed("GateQuestion")

      expect { agenda.answer(gate.id, {}) }.to raise_error(ArgumentError, /names no issue.*a, b/)
      expect([gate_records.size, listed("GateQuestion").issues]).to eq([before, %w[a b]])
      expect(agenda.answer(gate.id, { "a" => Lain::Approval::Verdict::Deny.new })).to be(true)
    end

    it "journals the device that answered a gate" do
      defer_wave

      agenda.answer(listed("GateQuestion").id, { "b" => Lain::Approval::Verdict::Deny.new }, surface: "remote:pixel")

      expect(gate_records.last).to include("issue_id" => "b", "answered_by" => "remote:pixel")
    end

    it "approves a parked call as a human on the remote surface" do
      Sync do |task|
        pending = park(task)
        call = listed("ParkedCall")

        expect(agenda.answer(call.id, Lain::Approval::Verdict::Approve.new)).to be(true)
        expect(pending).to have_attributes(approved?: true, surface: "remote", authority: :human)
      end
    end

    it "answers false for an item already settled elsewhere" do
      Sync do |task|
        pending = park(task)
        call = listed("ParkedCall")
        pending.approve(surface: "tty", authority: :human)
        task.yield

        expect(agenda.answer(call.id, Lain::Approval::Verdict::Deny.new)).to be(false)
      end
    end

    it "answers false for a gate the desk answered first" do
      defer_wave
      desk = Lain::CLI::EpicQueue.new(paths:, root:)
      racing = AgendaSpecSupport::RacingGates.new(gates) { desk.deny(_1) }
      raced = described_class.new(queue:, gates: racing, replies:)

      expect(raced.answer(listed_in(raced, "GateQuestion").id,
                          { "b" => Lain::Approval::Verdict::Deny.new })).to be(false)
    end

    it "applies a gate's approvals before its denials, each half in the order given" do
      # 40, because Ruby's sort keeps equal keys in order below about 16 and so cannot show an unstable one.
      issues = (1..40).map { format("i%02d", _1) }
      recording = AgendaSpecSupport::RecordingGates.new(*issues)
      gated = described_class.new(queue:, gates: recording, replies:)
      denied, approved = issues.partition.with_index { |_issue, at| at.even? }
      answer = issues.to_h do |issue|
        [issue, denied.include?(issue) ? Lain::Approval::Verdict::Deny.new : Lain::Approval::Verdict::Approve.new]
      end

      gated.answer(listed_in(gated, "GateQuestion").id, answer)

      expect(recording.answers.map { _1.take(2) })
        .to eq(approved.map { [:approve, "blake3:#{_1}"] } + denied.map { [:deny, "blake3:#{_1}"] })
    end

    it "refuses a stage name as the key of a gate whose rows each name an issue" do
      defer_wave

      expect { agenda.answer(listed("GateQuestion").id, { "issue_plan" => Lain::Approval::Verdict::Deny.new }) }
        .to raise_error(ArgumentError, /"issue_plan" is not in this gate/)
    end

    it "refuses a question's answer that is not text, before it reaches the asker" do
      expect { agenda.answer(listed("Question").id, Lain::Approval::Verdict::Approve.new) }
        .to raise_error(ArgumentError, /text/)
      expect(asker.last_answer).to be_nil
    end

    it "journals the device that answered a question, and \"remote\" when none was named" do
      agenda.answer(listed("Question").id, "the parser crate", surface: "remote:pixel")
      asker.ask("And the lexer?")
      agenda.answer(listed("Question").id, "the same one")

      expect(asked_journal.grep(Lain::Telemetry::QuestionAnswered).map(&:answered_by)).to eq(%w[remote:pixel remote])
    end

    it "refuses an id it never minted" do
      expect { agenda.answer("nope", "x") }.to raise_error(ArgumentError, /nope/)
    end
  end

  describe "a gate with no issues" do
    def defer_research
      Lain::Journal.open(paths:, root:) do |journal|
        journal.record(Lain::Epic::GateDecision.new(artifact_digest: digest_a, epic_slug: "alpha", stage: "research",
                                                    verdict: Lain::Epic::GateDecision::Deferred.new,
                                                    answered_by: "deferred", policy: "deferred", latency: 0.0))
      end
    end

    it "lists the stage name as the one key the app answers by" do
      defer_research

      expect(listed("GateQuestion")).to have_attributes(stage: "research", issues: %w[research])
    end

    it "approves the gate on an answer keyed by that name" do
      recording = AgendaSpecSupport::RecordingGates.new(nil, stage: "research")
      gated = described_class.new(queue:, gates: recording, replies:)

      expect(gated.answer(listed_in(gated, "GateQuestion").id, { "research" => Lain::Approval::Verdict::Approve.new },
                          surface: "remote:pixel")).to be(true)
      expect(recording.answers).to eq([[:approve, "blake3:research", nil, "remote:pixel"]])
    end

    it "approves only the newest revision of the stage, which supersedes the older" do
      recording = AgendaSpecSupport::RecordingGates.new(nil, nil, stage: "research", digests: %w[blake3:r0 blake3:r1])
      gated = described_class.new(queue:, gates: recording, replies:)

      expect(listed_in(gated, "GateQuestion")).to have_attributes(issues: %w[research], digests: %w[blake3:r1])
      gated.answer(listed_in(gated, "GateQuestion").id, { "research" => Lain::Approval::Verdict::Approve.new })

      expect(recording.answers.map { _1.take(2) }).to eq([[:approve, "blake3:r1"]])
    end

    it "denies every revision of the stage, because a denial supersedes none" do
      recording = AgendaSpecSupport::RecordingGates.new(nil, nil, stage: "research", digests: %w[blake3:r0 blake3:r1])
      gated = described_class.new(queue:, gates: recording, replies:)

      gated.answer(listed_in(gated, "GateQuestion").id, { "research" => Lain::Approval::Verdict::Deny.new })

      expect(recording.answers.map { _1.take(2) }).to eq([[:deny, "blake3:r0"], [:deny, "blake3:r1"]])
    end

    it "keeps the item's id when the desk decides the older revision, and the answer still lands" do
      [digest_a, digest_b].each do |digest|
        Lain::Journal.open(paths:, root:) do |journal|
          journal.record(Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: "alpha", stage: "research",
                                                      verdict: Lain::Epic::GateDecision::Deferred.new,
                                                      answered_by: "deferred", policy: "deferred", latency: 0.0))
        end
      end
      id = listed("GateQuestion").id

      gates.deny(digest_a, reason: "stale")

      expect(listed("GateQuestion").id).to eq(id)
      expect(agenda.answer(id, { "research" => Lain::Approval::Verdict::Approve.new })).to be(true)
      expect(gate_records.last).to include("artifact_digest" => digest_b, "verdict" => "approve")
    end

    it "lands a denial on the newest revision when the desk already denied the older" do
      [digest_a, digest_b].each do |digest|
        Lain::Journal.open(paths:, root:) do |journal|
          journal.record(Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: "alpha", stage: "research",
                                                      verdict: Lain::Epic::GateDecision::Deferred.new,
                                                      answered_by: "deferred", policy: "deferred", latency: 0.0))
        end
      end
      id = listed("GateQuestion").id
      gates.deny(digest_a, reason: "stale")

      expect(agenda.answer(id, { "research" => Lain::Approval::Verdict::Deny.new })).to be(true)
      expect(gate_records.select { _1["verdict"] == "deny" }.map { _1["artifact_digest"] }).to eq([digest_a, digest_b])
    end

    it "journals an answer keyed by that name as `lain epic deny` would" do
      defer_research

      agenda.answer(listed("GateQuestion").id, { "research" => Lain::Approval::Verdict::Deny.new(note: "thin") })

      expect(gate_records.last).to include("artifact_digest" => digest_a, "stage" => "research", "verdict" => "deny",
                                           "reason" => "thin", "issue_id" => nil)
      expect(listed("GateQuestion")).to be_nil
    end

    it "refuses an empty answer with a reason, and is still listed to answer again" do
      defer_research

      expect { agenda.answer(listed("GateQuestion").id, {}) }.to raise_error(ArgumentError, /names no issue.*research/)
      expect(listed("GateQuestion")).to have_attributes(issues: %w[research])
    end
  end

  describe "a settled item leaves" do
    it "settles the call's id in the next delta when the desk approves it" do
      Sync do |task|
        pending = park(task)
        cursor, = agenda.delta_since(0)
        call = listed("ParkedCall")
        pending.approve(surface: "tty", authority: :human)
        task.yield

        later, added, settled = agenda.delta_since(cursor)
        expect([later > cursor, added, settled]).to eq([true, [], [call.id]])
      end
    end

    it "drops a decided call at once, before its parked fiber resumes to leave the queue" do
      Sync do |task|
        park(task).approve(surface: "tty", authority: :human)

        expect(kinds(agenda.snapshot)).to eq(["Question"])
        task.stop
      end
    end
  end

  describe "deltas replay to the present" do
    def replayed(items, delta)
      _cursor, added, settled = delta
      (items + added).reject { settled.include?(_1.id) }
    end

    it "applies the deltas since any cursor to that cursor's snapshot to give the current one" do
      seen = [[0, []]]
      look = -> { seen << [agenda.delta_since(0).first, agenda.snapshot] }
      Sync do |task|
        look.call
        first = park(task)
        look.call
        park(task, { "command" => "ls" })
        defer_wave
        look.call
        first.approve(surface: "tty", authority: :human)
        task.yield
        replies.answer("done", question_digest)
        look.call
        agenda.answer(listed("GateQuestion").id,
                      { "a" => Lain::Approval::Verdict::Deny.new })
        look.call

        current = agenda.snapshot
        seen.each do |cursor, items|
          expect(replayed(items, agenda.delta_since(cursor))).to match_array(current), "from cursor #{cursor}"
        end
        task.stop
      end
    end

    it "names no item that came and went after the cursor" do
      Sync do |task|
        agenda.snapshot
        cursor, = agenda.delta_since(0)
        pending = park(task)
        agenda.snapshot
        pending.approve(surface: "tty", authority: :human)
        task.yield

        expect(agenda.delta_since(cursor).drop(1)).to eq([[], []])
      end
    end

    it "refuses a cursor ahead of the agenda" do
      expect { agenda.delta_since(99) }.to raise_error(ArgumentError, /99/)
    end
  end
end
