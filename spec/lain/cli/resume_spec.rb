# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# T19: resolving `lain chat --resume [SESSION]` into the pieces the exe wires --
# the verified Timeline (T15 injection), the replayed Session run-state and
# memory recorder (T16), the chained-header fields the new journal opens with
# (T14's resumed_from), and the notices the frontend renders. The exe stays
# thin; this object owns every choice.
RSpec.describe Lain::CLI::Resume do
  around do |example|
    Dir.mktmpdir { |dir| @state_home = dir and example.run }
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home }) }
  let(:recorded_context) { Lain::Context.new(model: "recorded-model", max_tokens: 512, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

  subject(:resume) { described_class.new(paths:) }

  def text(body) = [{ "type" => "text", "text" => body }]

  # Roles alternate user/assistant from the root, the ordinary chat shape.
  def chain(*bodies)
    bodies.each_with_index.inject(Lain::Timeline.empty(store: Lain::Store.new)) do |timeline, (body, i)|
      timeline.commit(role: i.even? ? :user : :assistant, content: text(body))
    end
  end

  def open_header(resumed_from: nil)
    header = Lain::SessionRecord.header(context: recorded_context, toolset:, head: nil)
    resumed_from.nil? ? header : header.merge("resumed_from" => resumed_from)
  end

  def turn_records(timeline) = timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) }

  def closed_record(head) = Lain::Telemetry::SessionClosed.new(head:, reason: :exit).to_journal

  def write_session(name, records)
    path = File.join(paths.sessions_dir, name)
    File.write(path, "#{records.map { |record| JSON.generate(record) }.join("\n")}\n")
    path
  end

  def write_closed(name, timeline, extra: [])
    write_session(name, [open_header] + turn_records(timeline) + extra + [closed_record(timeline.head_digest)])
  end

  describe "restoring the whole conversation (a closed session of three turns)" do
    let(:three) { chain("first", "ack", "second") }
    before { write_closed("20260101T000000-1.ndjson", three) }

    it "rebuilds the verified Timeline, closed, with the chained-header fields for the new journal" do
      result = resume.call

      expect(result.timeline.to_a.map(&:digest)).to eq(three.to_a.map(&:digest))
      expect(result.open?).to be(false)
      expect(result.resumed_from).to eq("file" => "20260101T000000-1.ndjson", "head" => three.head_digest)
      expect(result.written).to eq(three.to_a.map(&:digest))
    end

    it "carries all three prior turns into the next request, and the new file's header chains to the old" do
      result = resume.call
      journal_io = StringIO.new
      chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io))
      chronicle.start(context: recorded_context, toolset:,
                      resumed_from: result.resumed_from, written: result.written)

      provider = Lain::Provider::Mock.new(responses: [text_response("answered")])
      agent = Lain::Agent.new(provider:, toolset:, context: recorded_context, timeline: result.timeline)
      agent.ask("third")
      chronicle.catch_up(agent.timeline)

      expect(provider.last_request.messages.map { |message| message["content"].first["text"] })
        .to eq(%w[first ack second third])

      new_records = journal_io.string.each_line.map { |line| JSON.parse(line) }
      header = new_records.find { |record| record["type"] == "session" }
      expect(header["resumed_from"]).to eq(result.resumed_from)

      # Only the NEW turns land in the new file; the Loader then reads the
      # chain back as ONE verified conversation with no duplicates.
      expect(new_records.count { |record| record["type"] == "turn" }).to eq(2)
      resolver = lambda { |basename|
        basename == result.file ? File.foreach(File.join(paths.sessions_dir, result.file)) : nil
      }
      loaded = Lain::Bench::Session::Loader.new(new_records, resolve: resolver).recording
      expect(loaded.timeline.to_a.map(&:digest)).to eq(agent.timeline.to_a.map(&:digest))
    end
  end

  describe "selection" do
    let(:first) { chain("one") }
    let(:second) { chain("two") }
    before do
      write_closed("20260101T000000-1.ndjson", first)
      write_closed("20260202T000000-1.ndjson", second)
    end

    it "bare --resume picks the newest session" do
      expect(resume.call.file).to eq("20260202T000000-1.ndjson")
    end

    it "an exact filename picks that session" do
      expect(resume.call(selector: "20260101T000000-1.ndjson").file).to eq("20260101T000000-1.ndjson")
    end

    it "a unique prefix picks its session" do
      expect(resume.call(selector: "20260101").file).to eq("20260101T000000-1.ndjson")
    end

    it "refuses an ambiguous prefix, naming the candidates" do
      expect { resume.call(selector: "2026") }.to raise_error(described_class::Refusal) do |error|
        expect(error.message).to include("20260101T000000-1.ndjson", "20260202T000000-1.ndjson")
      end
    end

    it "refuses a selector matching nothing, naming it and the directory" do
      expect { resume.call(selector: "nope") }
        .to raise_error(described_class::Refusal) { |error|
              expect(error.message).to include("nope", paths.sessions_dir)
            }
    end
  end

  it "refuses namedly when there is nothing to resume" do
    expect { resume.call }
      .to raise_error(described_class::Refusal) { |error| expect(error.message).to include(paths.sessions_dir) }
  end

  describe "idempotence: resuming a resumed session that exited immediately" do
    let(:three) { chain("first", "ack", "second") }

    before do
      write_closed("20260101T000000-1.ndjson", three)
      chained = open_header(resumed_from: { "file" => "20260101T000000-1.ndjson", "head" => three.head_digest })
      write_session("20260101T000100-1.ndjson", [chained, closed_record(three.head_digest)])
    end

    it "resumes the head of the CHAIN: same turns once, chained to the newest file, no fork" do
      result = resume.call

      expect(result.file).to eq("20260101T000100-1.ndjson")
      digests = result.timeline.to_a.map(&:digest)
      expect(digests).to eq(three.to_a.map(&:digest))
      expect(digests).to eq(digests.uniq)
      expect(result.resumed_from).to eq("file" => "20260101T000100-1.ndjson", "head" => three.head_digest)
    end
  end

  describe "an open (SIGKILL'd) session" do
    let(:two) { chain("hi", "hello") }
    before { write_session("20260101T000000-1.ndjson", [open_header] + turn_records(two)) }

    it "loads the verified turns, reports the open state, and chat continues" do
      result = resume.call

      expect(result.open?).to be(true)
      expect(result.timeline.head_digest).to eq(two.head_digest)
      expect(result.notices.join).to include("20260101T000000-1.ndjson", "not gracefully closed")
    end
  end

  describe "run-state and memory replay" do
    let(:memory_chain) do
      Lain::Timeline.empty(store: Lain::Store.new)
                    .commit(role: :user, content: text("remember aspirin"))
                    .commit(role: :assistant,
                            content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
                                        "input" => { "id" => "aspirin", "description" => "dosing",
                                                     "body" => "40mg/kg" } }])
                    .commit(role: :user,
                            content: [{ "type" => "tool_result", "tool_use_id" => "tu_1",
                                        "content" => [{ "type" => "text", "text" => "ok" }],
                                        "is_error" => false }])
    end

    let(:run_state_records) do
      [{ "type" => "session_read", "path" => "/tmp/app.rb" },
       { "type" => "todo_snapshot", "todos" => [{ "content" => "check dosing", "status" => "pending" }] }]
    end

    before { write_closed("20260101T000000-1.ndjson", memory_chain, extra: run_state_records) }

    it "folds reads and todos back into the Session" do
      result = resume.call

      expect(result.session.read?("/tmp/app.rb")).to be(true)
      expect(result.session.reminders.join).to include("check dosing")
    end

    it "rebuilds memory from the recorded writes, and the recorder IS the session's manifest source" do
      result = resume.call

      expect(result.session.reminders.join).to include("aspirin")
      result.recorder.write(Lain::Memory::Item.new(id: "ibuprofen", description: "alt", body: "10mg/kg"))
      expect(result.session.reminders.join).to include("ibuprofen")
    end

    it "folds run-state from EVERY file of a resume chain, not just the resumed head" do
      chained = open_header(resumed_from: { "file" => "20260101T000000-1.ndjson",
                                            "head" => memory_chain.head_digest })
      write_session("20260101T000100-1.ndjson",
                    [chained, { "type" => "session_read", "path" => "/tmp/later.rb" },
                     closed_record(memory_chain.head_digest)])

      result = resume.call

      expect(result.file).to eq("20260101T000100-1.ndjson")
      expect(result.session.read?("/tmp/app.rb")).to be(true)
      expect(result.session.read?("/tmp/later.rb")).to be(true)
      expect(result.session.reminders.join).to include("aspirin")
    end
  end

  describe "the model-mismatch notice (LOUD, then continue with the flags)" do
    before { write_closed("20260101T000000-1.ndjson", chain("hi", "yo")) }

    it "names both models when the current flags disagree with the recording" do
      notices = resume.call(model: "other-model").notices
      expect(notices.join).to include("recorded-model", "other-model")
    end

    it "stays silent when they agree" do
      expect(resume.call(model: "recorded-model").notices).to be_empty
    end
  end

  describe "refusals name the file and the reason, never a backtrace" do
    it "refuses a corrupt session (a tampered turn)" do
      records = [open_header] + turn_records(chain("hi", "yo"))
      records[1] = records[1].merge("content" => text("tampered"))
      write_session("20260101T000000-1.ndjson", records)

      expect { resume.call }.to raise_error(described_class::Refusal) do |error|
        expect(error).to be_a(Lain::Error)
        expect(error.message).to include("20260101T000000-1.ndjson", "content address")
      end
    end

    it "refuses a pre-scribe (headerless, --nvim-era) journal namedly" do
      write_session("20260101T000000-1.ndjson", [{ "type" => "request_sent", "digest" => "blake3:#{"a" * 64}" }])

      expect { resume.call }.to raise_error(described_class::Refusal) do |error|
        expect(error.message).to include("20260101T000000-1.ndjson", "header")
      end
    end

    # Panel fix round (finding 2): the run-state walk carries its OWN cycle
    # guard -- driven here at the seam directly, so its safety is proven
    # independent of the Loader having refused the cycle first (an ordering
    # invariant a reorder of rebuild's statements would silently break).
    it "refuses a cyclic chain in the run-state walk itself, never a SystemStackError" do
      a = open_header(resumed_from: { "file" => "20260102T000000-1.ndjson", "head" => "blake3:#{"1" * 64}" })
      b = open_header(resumed_from: { "file" => "20260101T000000-1.ndjson", "head" => "blake3:#{"2" * 64}" })
      write_session("20260101T000000-1.ndjson", [a])
      write_session("20260102T000000-1.ndjson", [b])

      expect { resume.send(:chain_paths, File.join(paths.sessions_dir, "20260101T000000-1.ndjson")) }
        .to raise_error(described_class::Refusal) do |error|
          expect(error.message).to include("20260101T000000-1.ndjson", "cycle")
        end
    end

    # Committing synthetic tool_results is a design decision, not an
    # implementation detail (the card's hard trigger): a head still awaiting
    # its tool results refuses with the re-ask shape instead of resuming into
    # a request the API must reject.
    it "refuses an open session whose head is a tool_use turn awaiting results (crash mid-tool)" do
      mid_tool = Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: text("echo hi"))
                               .commit(role: :assistant,
                                       content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "echo",
                                                   "input" => { "text" => "hi" } }])
      write_session("20260101T000000-1.ndjson", [open_header] + turn_records(mid_tool))

      expect { resume.call }.to raise_error(described_class::Refusal) do |error|
        expect(error.message).to include("20260101T000000-1.ndjson", "tool", "re-ask")
      end
    end
  end
end
