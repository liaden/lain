# frozen_string_literal: true

require "json"
require "stringio"
require "thor"
require "tmpdir"

# Resolving `lain chat --resume [SESSION]` into the pieces the exe wires --
# the verified Timeline (injected), the replayed Session run-state and memory
# recorder, the chained-header fields the new journal opens with
# (`resumed_from`), and the notices the frontend renders. The exe stays
# thin; this object owns every choice.
RSpec.describe Lain::CLI::Resume do
  subject(:resume) { described_class.new(paths:) }

  around do |example|
    Dir.mktmpdir { |dir| @state_home = dir and example.run }
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home }) }
  let(:recorded_context) { Lain::Context.new(model: "recorded-model", max_tokens: 512, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

  def text(body) = [{ "type" => "text", "text" => body }]

  # Roles alternate user/assistant from the root, the ordinary chat shape.
  def chain(*bodies)
    bodies.each_with_index.inject(Lain::Timeline.empty(store: Lain::Store.new)) do |timeline, (body, i)|
      timeline.commit(role: i.even? ? :user : :assistant, content: text(body))
    end
  end

  # `provider:` merges in only when given -- absence is no key, never a nil
  # value, the same discipline `resumed_from` already follows here: a header
  # written before `provider` existed genuinely has no "provider" key at all,
  # not a nil-valued one, and the fixture must be able to say that.
  def open_header(resumed_from: nil, provider: nil)
    header = Lain::SessionRecord.header(context: recorded_context, toolset:, head: nil)
    header = header.merge("resumed_from" => resumed_from) unless resumed_from.nil?
    header = header.merge("provider" => provider) unless provider.nil?
    header
  end

  def turn_records(timeline) = timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) }

  # A journal is bytes, and bytes rot. A null INSIDE causal_parents is
  # malformed rather than dangling, and it used to slip through MessageReplay's
  # `compact`ing reachability check to be refused by the Store as a bare
  # Store::MissingObject -- from the sweep, where no translation reached it.
  # MessageReplay shape-checks the field now, so it refuses one layer down; the
  # two examples below pin what a USER gets, which is the same named refusal
  # from either door regardless of which layer catches it.
  def null_parent_message
    payload = Lain::Event::Payload.new(kind: :message, body: { "text" => "which dose?" })
    event = Lain::Event.new(kind: :message, carried_payload: payload, from: "agent", to: "human")
    Lain::Telemetry::Message.from_event(event).to_journal.merge("causal_parents" => [nil])
  end

  def closed_record(head) = Lain::Telemetry::SessionClosed.new(head:, reason: :exit).to_journal

  def write_session(name, records)
    path = File.join(paths.sessions_dir, name)
    File.write(path, "#{records.map { |record| JSON.generate(record) }.join("\n")}\n")
    path
  end

  def write_closed(name, timeline, extra: [], provider: nil)
    write_session(name,
                  [open_header(provider:)] + turn_records(timeline) + extra + [closed_record(timeline.head_digest)])
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

    # The selector's bare/prefix view must agree with `lain
    # sessions` -- an ephemeral scratch file is not silently the "newest"
    # session, and a fork/resume must not manufacture the accepted-edge
    # resumed_from against a name promotion will later break. The EXACT
    # filename stays selectable: salvaging a crashed --btw session.
    context "with an ephemeral (--btw) scratch session newest in the directory" do
      let(:scratch) { chain("scratchy") }

      before { write_session("20260303T000000-9.btw.ndjson", [open_header] + turn_records(scratch)) }

      it "bare --resume picks the newest DURABLE session, mirroring `lain sessions`" do
        expect(resume.call.file).to eq("20260202T000000-1.ndjson")
      end

      it "a prefix matches only durable sessions, refusing namedly" do
        expect { resume.call(selector: "20260303") }
          .to raise_error(described_class::Refusal, /20260303/)
      end

      it "the exact .btw filename still resumes -- a crashed scratch session stays salvageable" do
        result = resume.call(selector: "20260303T000000-9.btw.ndjson")

        expect(result.file).to eq("20260303T000000-9.btw.ndjson")
        expect(result.timeline.head_digest).to eq(scratch.head_digest)
      end
    end

    # Journal.open creates the session file long before the
    # scribe writes its header, so a chat that died in that window leaves a
    # zero-byte .ndjson -- and it sorts NEWEST, so a bare --resume picked it
    # and the Loader raised Corrupt on a file that is not corrupt, merely
    # empty. The writer now cleans up after itself; these pin the reader's
    # defence for the file a hard kill still leaves.
    context "with a zero-byte session newest in the directory" do
      let(:empty_name) { "20260404T000000-1.ndjson" }

      before { File.write(File.join(paths.sessions_dir, empty_name), "") }

      it "bare --resume skips it for the newest session that has records" do
        expect(resume.call.file).to eq("20260202T000000-1.ndjson")
      end

      it "naming it exactly refuses saying it is EMPTY, never that it is corrupt" do
        expect { resume.call(selector: empty_name) }
          .to raise_error(described_class::Refusal) { |error|
                expect(error.message).to include(empty_name, "empty")
                expect(error.message).not_to match(/corrupt/i)
              }
      end

      it "a unique prefix naming it refuses the same way, not with 'no session matching'" do
        expect { resume.call(selector: "20260404") }
          .to raise_error(described_class::Refusal, /empty/)
      end

      # "No sessions" while `ls` shows three files is a refusal the user stops
      # believing, and they cannot act on it: the fix (delete them, or name one
      # exactly) depends entirely on WHY each was passed over.
      it "refuses a bare --resume when every durable session is empty, counting what it skipped" do
        %w[20260101T000000-1.ndjson 20260202T000000-1.ndjson]
          .each { |name| File.write(File.join(paths.sessions_dir, name), "") }
        write_session("20260505T000000-9.btw.ndjson", [open_header])

        expect { resume.call }
          .to raise_error(described_class::Refusal) { |error|
                expect(error.message).to include(paths.sessions_dir, "3 empty", "1 ephemeral")
              }
      end

      # Resume::Selector is shared with ForkPoint, so --fork's "newest" moves
      # with --resume's. The two must not disagree about which file is real.
      it "--fork's newest agrees: the empty file is no fork parent either" do
        point = Lain::CLI::ForkPoint.new(dir: paths.sessions_dir)
                                    .call("@#{second.head_digest.delete_prefix("blake3:")[0, 8]}")

        expect(File.basename(point.path)).to eq("20260202T000000-1.ndjson")
      end
    end

    it "refuses a bare --resume when only ephemerals exist, naming the directory" do
      Dir.children(paths.sessions_dir).each { |name| File.delete(File.join(paths.sessions_dir, name)) }
      write_session("20260303T000000-9.btw.ndjson", [open_header] + turn_records(chain("scratchy")))

      expect { resume.call }
        .to raise_error(described_class::Refusal) { |error| expect(error.message).to include(paths.sessions_dir) }
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

  # The writer's pid rides IN the filename ({Journal.open}'s naming), so an
  # open session whose writer is still running can be told apart from one a
  # crash actually left behind -- "not gracefully closed" reads as abandoned,
  # which is false while the process is still writing it.
  describe "an open session whose writer process is still alive" do
    let(:two) { chain("hi", "hello") }
    let(:name) { "20260101T000000-#{Process.pid}.ndjson" }

    before { write_session(name, [open_header] + turn_records(two)) }

    it "says the session is still open in that process, not that it wasn't gracefully closed" do
      result = resume.call

      expect(result.notices.join).to include(name, "still open in process #{Process.pid}")
      expect(result.notices.join).not_to include("not gracefully closed")
    end
  end

  # An open session whose crash left an unanswered request_sent gets one
  # salvage attempt before anything else about it is decided.
  describe "salvage on resume" do
    let(:committed) { chain("hi", "hello") }

    def in_flight_request
      Lain::Request.new(model: "recorded-model", max_tokens: 512, messages: [{ role: "user", content: "third" }])
    end

    def request_sent_record(request)
      Lain::Telemetry::RequestSent.new(digest: request.digest, payload: request.cache_payload,
                                       stream: request.stream, extra: request.extra,
                                       prefix_digests: request.prefix_digests).to_journal
    end

    def wal_path_for(name) = Lain::Paths.wal_for(File.join(paths.sessions_dir, name))

    def canned_response
      Lain::Response.new(id: "msg_salvaged", model: "recorded-model", stop_reason: :end_turn,
                         content: text("salvaged reply"), usage: Lain::Usage.new(input_tokens: 5, output_tokens: 2))
    end

    def write_crashed_session(name, request)
      write_session(name, [open_header] + turn_records(committed) + [request_sent_record(request)])
    end

    def write_complete_frame(name, request, response)
      frame = Lain::Provider::ResponseWal.new(wal_path_for(name)).open_frame(request_digest: request.digest)
      frame.append(AnthropicSSE.body(response))
      frame.close(complete: true)
    end

    # Salvager REOPENS a file it did not create (salvager.rb:60) and may append
    # nothing to it. Its safety used to be borrowed: the only thing keeping a
    # zero-byte file away from this reopen was Selector refusing it -- a
    # different class, on a different card, that a future caller need not go
    # through. Journal.open now only ever removes a file it created itself, so
    # the invariant is structural; pinned HERE because this is the class that
    # would pay for it being broken.
    describe "the salvage reopen never destroys the file it salvages" do
      it "keeps a crashed session's bytes intact across a reopen that appends nothing" do
        path = write_session("20260101T000000-1.ndjson", [open_header] + turn_records(committed))
        before = File.read(path)

        Lain::CLI::Resume::Salvager.new(path:, timeline: committed).outcome
        Lain::Journal.open(path, fsync: true).close

        expect(File.read(path)).to eq(before)
      end

      it "keeps even a zero-byte file handed to the same reopen" do
        path = File.join(paths.sessions_dir, "20260101T000000-1.ndjson")
        File.write(path, "")

        Lain::Journal.open(path, fsync: true).close

        expect(File).to exist(path)
      end
    end

    describe "a complete uncommitted response" do
      it "recovers the response as the session's new turn, closing the file, without spending again" do
        request = in_flight_request
        write_crashed_session("20260101T000000-1.ndjson", request)
        write_complete_frame("20260101T000000-1.ndjson", request, canned_response)

        result = resume.call

        expect(result.open?).to be(false)
        expect(result.timeline.to_a.size).to eq(3)
        expect(result.timeline.head.content).to eq(canned_response.content)
        expect(result.notices.join).to include("recovered", request.digest)
        expect(result.resumed_from).to eq("file" => "20260101T000000-1.ndjson", "head" => result.timeline.head_digest)
        expect(result.written).to eq(result.timeline.to_a.map(&:digest))
      end

      it "appends the salvage record, the recovered turn, and a session_closed anchor to the crashed file" do
        request = in_flight_request
        write_crashed_session("20260101T000000-1.ndjson", request)
        write_complete_frame("20260101T000000-1.ndjson", request, canned_response)

        resume.call

        path = File.join(paths.sessions_dir, "20260101T000000-1.ndjson")
        records = File.foreach(path).map { |line| JSON.parse(line) }
        expect(records.map { |record| record["type"] }).to include("salvaged", "turn", "session_closed")
        expect(records.last["type"]).to eq("session_closed")
        salvaged = records.find { |record| record["type"] == "salvaged" }
        expect(salvaged["request_digest"]).to eq(request.digest)
        expect(salvaged["head_before"]).to eq(committed.head_digest)
        expect(salvaged["head_after"]).to eq(records.last["head"])
      end

      it "chains cleanly into a further resume: the recovered turn survives a second load" do
        request = in_flight_request
        write_crashed_session("20260101T000000-1.ndjson", request)
        write_complete_frame("20260101T000000-1.ndjson", request, canned_response)
        result = resume.call

        journal_io = StringIO.new
        chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io))
        chronicle.start(context: recorded_context, toolset:,
                        resumed_from: result.resumed_from, written: result.written)
        provider = Lain::Provider::Mock.new(responses: [text_response("answered")])
        agent = Lain::Agent.new(provider:, toolset:, context: recorded_context, timeline: result.timeline)
        agent.ask("fourth")
        chronicle.catch_up(agent.timeline)

        new_records = journal_io.string.each_line.map { |line| JSON.parse(line) }
        resolver = lambda { |basename|
          basename == result.file ? File.foreach(File.join(paths.sessions_dir, result.file)) : nil
        }
        loaded = Lain::Bench::Session::Loader.new(new_records, resolve: resolver).recording
        expect(loaded.timeline.to_a.map(&:digest)).to eq(agent.timeline.to_a.map(&:digest))
      end
    end

    # Panel blocker (Torvalds): a SECOND SIGKILL landing between the `turn`
    # write and the `session_closed` write left a durable state where
    # re-resume salvaged AGAIN -- Salvage decided from request_sent-without-
    # turn_usage (a salvaged turn carries no turn_usage by design), committed
    # a second copy onto the already-recovered head, and the file loaded with
    # two consecutive duplicate assistant turns. Every prefix of the
    # three-record append (`salvaged`, `turn`, `session_closed`) must
    # re-resume to exactly one recovery, never a duplicate.
    describe "idempotency across a second crash mid-close" do
      # Rebuilds the SAME three records {Salvager#close!} would append --
      # driving {SessionRecord::Salvage} directly against the file exactly as
      # {Salvager} does, so the manually-truncated prefix is byte-for-byte
      # what a real interrupted append would have left, not an approximation.
      def wal_frames(name) = Lain::Provider::ResponseWal.new(wal_path_for(name)).frames

      def recording_for(name)
        Lain::Bench::Session::Loader.new(File.foreach(name_path(name))).recording
      end

      def name_path(name) = File.join(paths.sessions_dir, name)

      def salvage_outcome(name)
        recording = recording_for(name)
        Lain::SessionRecord::Salvage.new(entries: File.foreach(name_path(name)), frames: wal_frames(name),
                                         timeline: recording.timeline).call
      end

      def salvage_append_records(name)
        outcome = salvage_outcome(name)
        head_before = recording_for(name).timeline.head_digest
        [Lain::Telemetry::Salvaged.new(request_digest: outcome.request_digest, head_before:,
                                       head_after: outcome.turn.digest).to_journal,
         Lain::SessionRecord.turn(outcome.turn),
         Lain::Telemetry::SessionClosed.new(head: outcome.turn.digest, reason: :salvaged).to_journal]
      end

      def append_prefix(name, count)
        File.open(name_path(name), "a") do |file|
          salvage_append_records(name).first(count).each { |record| file.puts(JSON.generate(record)) }
        end
      end

      # roles ending [..., "assistant", "assistant"] IS the correct shape here
      # (the crashed request was a follow-up with no new user turn in
      # between, by this fixture's construction) -- the BUG this guards is a
      # THIRD consecutive assistant turn (a duplicate recovery), not the
      # legitimate pair.
      [0, 1, 2, 3].each do |prefix|
        it "recovers exactly once when #{prefix} of the 3 closing records already landed before the crash" do
          name = "20260101T000000-1.ndjson"
          request = in_flight_request
          write_crashed_session(name, request)
          write_complete_frame(name, request, canned_response)
          append_prefix(name, prefix) if prefix.positive?

          result = resume.call

          expect(result.timeline.to_a.map(&:role)).to eq(%w[user assistant assistant])
          expect(result.timeline.to_a.size).to eq(3) # committed (2) + exactly ONE recovery, never a duplicate
          expect(result.timeline.head.content).to eq(canned_response.content)
          expect(result.open?).to be(false)

          # A further resume is now a clean no-op: the file is closed.
          again = resume.call
          expect(again.timeline.to_a.map(&:digest)).to eq(result.timeline.to_a.map(&:digest))
        end
      end
    end

    # A legacy interleaved WAL leaves a mis-slotted region the strict Reader
    # refuses. Resume must salvage a CLEAN frame written after it, report the
    # skip as a notice, and proceed -- never let a raw CorruptFrame escape and
    # block resume of a session whose paid-for response is still recoverable.
    describe "a corrupt region in the response log before a clean frame" do
      def write_corrupt_then_complete_frame(name, request, response)
        wal = Lain::Provider::ResponseWal
        clean_sse = AnthropicSSE.body(response)
        corrupt = "#{wal.header_record("corrupt-old")}body#{wal.terminator_record(4, true)}TRAILING"
        clean = wal.header_record(request.digest) + clean_sse + wal.terminator_record(clean_sse.bytesize, true)
        File.binwrite(wal_path_for(name), corrupt + clean)
      end

      it "recovers the clean frame, reports the skipped region, and resumes closed" do
        request = in_flight_request
        write_crashed_session("20260101T000000-1.ndjson", request)
        write_corrupt_then_complete_frame("20260101T000000-1.ndjson", request, canned_response)

        result = resume.call

        expect(result.open?).to be(false)
        expect(result.timeline.head.content).to eq(canned_response.content)
        expect(result.notices.join).to include("recovered", "corrupt region")
      end
    end

    # A crash BETWEEN promotion's two renames leaves
    # {x.btw.ndjson, x.wal} -- the derived x.btw.wal no longer exists, so a
    # naive salvage would find NOTHING and the paid-for frames would sit
    # unreachable with nothing ever triggering the healing retry. Salvage
    # falls back to the promoted sibling basename.
    describe "salvage of a half-promoted ephemeral (crash between the renames)" do
      it "finds the frames through the promoted wal name and recovers the response" do
        name = "20260101T000000-1.btw.ndjson"
        request = in_flight_request
        write_crashed_session(name, request)
        write_complete_frame(name, request, canned_response)
        # The pinned crash window: the wal leg of promote! completed, the
        # journal leg did not.
        File.rename(wal_path_for(name),
                    Lain::Paths.wal_for(File.join(paths.sessions_dir, "20260101T000000-1.ndjson")))

        result = resume.call(selector: name)

        expect(result.open?).to be(false)
        expect(result.timeline.head.content).to eq(canned_response.content)
        expect(result.notices.join).to include("recovered", request.digest)
      end

      it "still reads the marked wal when no promotion ever started" do
        name = "20260101T000000-1.btw.ndjson"
        request = in_flight_request
        write_crashed_session(name, request)
        write_complete_frame(name, request, canned_response)

        result = resume.call(selector: name)

        expect(result.open?).to be(false)
        expect(result.timeline.head.content).to eq(canned_response.content)
      end
    end

    describe "an incomplete frame" do
      it "surfaces provenance and leaves the session open, the file untouched" do
        request = in_flight_request
        write_crashed_session("20260101T000000-1.ndjson", request)
        raw = "event: message_start\ndata: {\"type\":\"message_start\""
        Lain::Provider::ResponseWal.new(wal_path_for("20260101T000000-1.ndjson"))
                                   .open_frame(request_digest: request.digest).append(raw)
        # crash: never closed -- the terminator never lands

        path = File.join(paths.sessions_dir, "20260101T000000-1.ndjson")
        lines_before = File.readlines(path).size

        result = resume.call

        expect(result.open?).to be(true)
        expect(result.timeline.head_digest).to eq(committed.head_digest)
        expect(result.notices.join).to include("did not finish", request.digest)
        expect(File.readlines(path).size).to eq(lines_before)
      end
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

  # Fork mode. `--fork "<session>@<digest-prefix>"` starts a NEW run at an
  # arbitrary recorded head of the parent. Read-only by construction: the fork
  # path never salvages and never opens a writable handle on the parent, so a
  # LIVE parent's journal stays exactly as its owner is writing it.
  describe "fork mode" do
    let(:three) { chain("first", "ack", "second") }
    let(:ancestor) { three.to_a[1].digest }

    def prefix_for(digest) = digest.delete_prefix("blake3:")[0, 12]

    def parent_path(name = "20260101T000000-1.ndjson") = File.join(paths.sessions_dir, name)

    describe "from a CLOSED session at an ancestor head" do
      before { write_closed("20260101T000000-1.ndjson", three) }

      it "checks out the fork point as the new head and chains resumed_from {file, A}" do
        result = resume.fork(selector: "20260101@#{prefix_for(ancestor)}")

        expect(result.timeline.head_digest).to eq(ancestor)
        expect(result.timeline.to_a.map(&:digest)).to eq(three.to_a.map(&:digest).first(2))
        expect(result.resumed_from).to eq("file" => "20260101T000000-1.ndjson", "head" => ancestor)
        expect(result.written).to eq(three.to_a.map(&:digest).first(2))
      end

      it "forks from the final head too, when the selector names it" do
        result = resume.fork(selector: "20260101@#{prefix_for(three.head_digest)}")

        expect(result.timeline.head_digest).to eq(three.head_digest)
      end

      it "leaves the parent journal byte-identical" do
        before_bytes = File.binread(parent_path)

        resume.fork(selector: "20260101@#{prefix_for(ancestor)}")

        expect(File.binread(parent_path)).to eq(before_bytes)
      end

      it "the forked run writes a new journal the Loader reads back as one verified chain from A" do
        result = resume.fork(selector: "20260101@#{prefix_for(ancestor)}")
        journal_io = StringIO.new
        chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io))
        chronicle.start(context: recorded_context, toolset:,
                        resumed_from: result.resumed_from, written: result.written)
        provider = Lain::Provider::Mock.new(responses: [text_response("forked answer")])
        agent = Lain::Agent.new(provider:, toolset:, context: recorded_context, timeline: result.timeline)
        agent.ask("a different second question")
        chronicle.catch_up(agent.timeline)

        new_records = journal_io.string.each_line.map { |line| JSON.parse(line) }
        expect(new_records.find { |record| record["type"] == "session" }["resumed_from"])
          .to eq("file" => "20260101T000000-1.ndjson", "head" => ancestor)

        resolver = ->(basename) { basename == result.file ? File.foreach(parent_path(result.file)) : nil }
        loaded = Lain::Bench::Session::Loader.new(new_records, resolve: resolver).recording
        expect(loaded.timeline.to_a.map(&:digest)).to eq(agent.timeline.to_a.map(&:digest))
        expect(loaded.timeline.to_a.map(&:digest)).not_to include(three.head_digest)
      end
    end

    describe "from a LIVE (open) session whose owner is still appending" do
      let(:two) { chain("hi", "hello") }

      before { write_session("20260101T000000-1.ndjson", [open_header] + turn_records(two)) }

      it "never constructs a Salvager and appends nothing to the parent" do
        expect(described_class::Salvager).not_to receive(:new)
        before_bytes = File.binread(parent_path)

        result = resume.fork(selector: "20260101@#{prefix_for(two.head_digest)}")

        expect(result.timeline.head_digest).to eq(two.head_digest)
        expect(File.binread(parent_path)).to eq(before_bytes)
        expect(Dir.children(paths.sessions_dir)).to eq(["20260101T000000-1.ndjson"])
      end

      it "keeps the parent loadable through its subsequent appends and close" do
        resume.fork(selector: "20260101@#{prefix_for(two.head_digest)}")

        extended = two.commit(role: :user, content: text("owner kept going"))
        File.open(parent_path, "a") do |file|
          file.puts(JSON.generate(Lain::SessionRecord.turn(extended.head)))
          file.puts(JSON.generate(closed_record(extended.head_digest)))
        end

        loaded = Lain::Bench::Session::Loader.new(File.foreach(parent_path)).recording
        expect(loaded.open?).to be(false)
        expect(loaded.timeline.head_digest).to eq(extended.head_digest)
      end
    end

    # This door's refusal was replaced with a repair: a fork point that is an
    # assistant tool_use turn still awaiting its results gets the cancellation
    # projected onto it, exactly as a resume of the same head does. What stays
    # fork-specific is the ANCHOR -- the chained header must keep naming the
    # fork point the parent recorded, never the projected turn, or the child's
    # own resume chain would name a digest the parent's fold never verified.
    it "repairs a fork point that is a mid-tool head, still anchored on the recorded fork point" do
      mid_tool = Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: text("echo hi"))
                               .commit(role: :assistant,
                                       content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "echo",
                                                   "input" => { "text" => "hi" } }])
      write_closed("20260101T000000-1.ndjson", mid_tool)

      forked = resume.fork(selector: "20260101@#{prefix_for(mid_tool.head_digest)}")

      expect(forked.timeline.head.content.first)
        .to include("type" => "tool_result", "tool_use_id" => "tu_1")
      expect(forked.resumed_from)
        .to eq("file" => "20260101T000000-1.ndjson", "head" => mid_tool.head_digest)
    end

    # The TOCTOU between ForkPoint's read and this
    # path's own Loader re-open -- a reap or rename can win that race, and a
    # raw Errno::ENOENT must not escape to the exe.
    it "maps the parent vanishing between resolution and load to a named Refusal" do
      write_closed("20260101T000000-1.ndjson", three)
      gone = File.join(paths.sessions_dir, "20260199T000000-1.ndjson")
      point = Lain::CLI::ForkPoint::Point.new(path: gone, digest: three.head_digest)
      allow(Lain::CLI::ForkPoint).to receive(:new).and_return(instance_double(Lain::CLI::ForkPoint, call: point))

      expect { resume.fork(selector: "whatever@abcd") }
        .to raise_error(described_class::Refusal, /20260199T000000-1\.ndjson/)
    end

    it "maps a corrupt parent to the same named Refusal resume gives" do
      records = [open_header] + turn_records(three)
      tampered = records[1].merge("content" => text("tampered"))
      write_session("20260101T000000-1.ndjson", [records[0], tampered, *records[2..]])

      expect { resume.fork(selector: "20260101@#{prefix_for(three.to_a[0].digest)}") }
        .to raise_error(described_class::Refusal, /20260101T000000-1\.ndjson/)
    end

    # Defence in depth alongside the turn-record translation. This case USED to
    # reach the fold as a bare Store::MissingObject, and no longer does: the
    # Loader's fixpoint forces its remainder through MessageReplay#forced_put,
    # which translates the Store's refusal into the same Corrupt a bad turn
    # raises. What is pinned here is unchanged and is the part that matters to a
    # user -- whichever currency the fold picks, the refusal arrives NAMED, with
    # the file attached, never as a raw store message with no provenance.
    it "refuses a fork over a message record citing a digest never journaled" do
      payload = Lain::Event::Payload.new(kind: :message, body: { "text" => "81 mg" })
      dangling_digest = "blake3:#{"a" * 64}"
      cited = Lain::Event.new(kind: :message, carried_payload: payload, from: "human", to: "agent",
                              causal_parents: [dangling_digest])
      write_closed("20260101T000000-1.ndjson", three,
                   extra: [Lain::Telemetry::Message.from_event(cited).to_journal])

      expect { resume.fork(selector: "20260101@#{prefix_for(ancestor)}") }
        .to raise_error(described_class::Refusal) do |error|
          expect(error.message).to include("20260101T000000-1.ndjson", dangling_digest)
        end
    end

    # End to end over a REAL damaged journal rather than a stub. This shape is
    # refused by MessageReplay's own shape check now, so what it pins here is
    # the door's behaviour, not the rescue arm's: whichever layer catches it,
    # `--fork` names the file. It goes red if the shape check regresses.
    it "refuses a fork over a message record whose causal_parents holds a null" do
      write_closed("20260101T000000-1.ndjson", three, extra: [null_parent_message])

      expect { resume.fork(selector: "20260101@#{prefix_for(ancestor)}") }
        .to raise_error(described_class::Refusal, /20260101T000000-1\.ndjson/)
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

  # The same LOUD-and-continue policy `model` already has, over every field of
  # the run profile the header records. Only a field the human TYPED can
  # disagree: an untyped one resolves to the recording.
  describe "the profile-mismatch notice (LOUD, then continue with the flags)" do
    before { write_closed("20260101T000000-1.ndjson", chain("hi", "yo"), provider: "ollama") }

    def typed(**options) = Lain::CLI::RunProfile.from_options(options)

    it "resolves a typed provider over the recording, and the notice names both" do
      profile = typed(provider: "anthropic").over(resume.recorded_profile(resume.locate("")))

      expect(profile.provider).to eq("anthropic")
      expect(resume.call(profile:).notices.join).to include("recorded with provider ollama", "anthropic")
    end

    it "stays silent when a typed provider agrees with the recording" do
      expect(resume.call(profile: typed(provider: "ollama")).notices).to be_empty
    end

    it "stays silent when nothing was typed, and resolves to the recording" do
      profile = typed.with_defaults(provider: "anthropic").over(resume.recorded_profile(resume.locate("")))

      expect(profile.provider).to eq("ollama")
      expect(resume.call(profile:).notices).to be_empty
    end

    # A field the header left unset is no recorded value, so a typed one
    # overrides nothing and there is nothing to be loud about.
    it "stays silent for a typed field the recording left unset" do
      expect(resume.call(profile: typed(num_batch: 512)).notices).to be_empty
    end
  end

  describe "a typed runner knob against a recorded one" do
    before do
      timeline = chain("hi", "yo")
      write_session("20260101T000000-1.ndjson",
                    [open_header(provider: "ollama").merge("num_batch" => 2048), *turn_records(timeline),
                     closed_record(timeline.head_digest)])
    end

    it "names both when they disagree" do
      notices = resume.call(profile: Lain::CLI::RunProfile.from_options(num_batch: 512)).notices

      expect(notices.join).to include("recorded with num_batch 2048", "512")
    end
  end

  describe "the recorded profile a door reads before anything is resolved" do
    before { write_closed("20260101T000000-1.ndjson", chain("hi", "yo"), provider: "ollama") }

    it "reads the header a --fork selector names, without writing to it" do
      path = File.join(paths.sessions_dir, "20260101T000000-1.ndjson")
      before = File.read(path)

      head = chain("hi", "yo").head_digest.delete_prefix("blake3:")[0, 12]
      recorded = resume.recorded_profile(resume.fork_point("20260101@#{head}").path)

      expect(recorded).to have_attributes(provider: "ollama", model: "recorded-model")
      expect(File.read(path)).to eq(before)
    end
  end

  # A header written before this field existed carries no "provider" key
  # at all -- resume must still proceed (never a refusal), naming the gap.
  describe "a header recorded with no provider field (old-caller compatibility)" do
    before { write_closed("20260101T000000-1.ndjson", chain("hi", "yo")) }

    it "proceeds with a 'provider unrecorded' notice rather than a refusal" do
      result = resume.call(profile: Lain::CLI::RunProfile.from_options(provider: "ollama"))

      expect(result.timeline.head_digest).not_to be_nil
      expect(result.notices.join).to include("provider unrecorded", "ollama")
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

    # The review fix, end to end -- and STILL legitimate after the Loader's
    # fixpoint. This journal writes no `message` record at all, so the cited
    # event is genuinely dangling rather than merely not-landed-yet, and no
    # amount of alternation between the two folds can resolve it. An assistant
    # turn can cite an answered ask_human question (ToolRunner#delivery's causal
    # edge -- ask_human is in the LIVE toolset), so the refusal has to be the
    # named one Resume builds a Refusal from, never a raw MissingObject.
    it "refuses a session whose turn cites a causal parent the fold cannot resolve" do
      store = Lain::Store.new
      payload = Lain::Event::Payload.new(kind: :message, body: { "text" => "81 mg" })
      store.put(payload)
      answered = Lain::Event.new(kind: :message, carried_payload: payload, from: "human", to: "agent")
      store.put(answered)
      cited = Lain::Timeline.empty(store:)
                            .commit(role: :user, content: text("dose?"))
                            .commit(role: :assistant, content: text("81 mg"), causal_parents: [answered.digest])
      write_session("20260101T000000-1.ndjson", [open_header] + turn_records(cited))

      expect { resume.call }.to raise_error(described_class::Refusal) do |error|
        expect(error).to be_a(Lain::Error)
        expect(error.message).to include("20260101T000000-1.ndjson", answered.digest)
      end
    end

    # The asymmetry this card deleted: #fork rescued Store::MissingObject beside
    # Corrupt and #rebuild did not, so when this shape still escaped the rebuild
    # the SAME damaged file refused namedly from `--fork` and arrived as a raw
    # store message -- no file, no session, a backtrace -- from `--resume`.
    # Which door a user came through decided whether they were told anything
    # useful. Both doors are pinned now, so neither can drift alone again.
    it "refuses a session whose message record holds a null causal parent" do
      write_closed("20260101T000000-1.ndjson", chain("hi", "yo"), extra: [null_parent_message])

      expect { resume.call }.to raise_error(described_class::Refusal) do |error|
        expect(error).to be_a(Lain::Error)
        expect(error.message).to include("20260101T000000-1.ndjson")
      end
    end

    # The Loader folds the run's mode trajectory off its own mode_switch records,
    # so the axis's chaining and roster refusals reach EVERY session load rather
    # than only `bench variance`. This door rescues Corrupt by name; anything else
    # makes a chat session unresumable over one bad line, with a backtrace and
    # no file on it -- which is the asymmetry the examples above exist to close.
    # A flip whose live sink failed commits on the durable record, so a retry
    # writes nothing and the session this produced resumes.
    it "resumes a session whose /mode flip hit a live-sink failure and was retried" do
      io = StringIO.new
      sink = Object.new
      def sink.<<(_event) = raise(IOError, "state file write failed")
      switch = Lain::Mode::Switch.new(Lain::Mode.new, journal: Lain::CLI::JournalTee.new(Lain::Journal.new(io:), sink))
      2.times do
        switch.switch(Lain::Mode.new(approval: :auto), surface: "tty")
      rescue IOError
        nil
      end

      flips = io.string.lines.map { |line| JSON.parse(line) }
      write_closed("20260101T000000-1.ndjson", chain("hi", "yo"), extra: flips)

      expect { resume.call }.not_to raise_error
    end

    describe "a damaged mode_switch record" do
      def resume_over(*flips)
        write_closed("20260101T000000-1.ndjson", chain("hi", "yo"), extra: flips)
        resume.call
      end

      def flip(from, to)
        { "type" => "mode_switch", "from_scope" => "checkout", "from_approval" => from,
          "to_scope" => "checkout", "to_approval" => to }
      end

      it "refuses an unchainable pair namedly, never a raw Lain::Error" do
        expect { resume_over(flip("ask", "auto"), flip("ask", "auto")) }
          .to raise_error(described_class::Refusal, /20260101T000000-1\.ndjson.*mode_switch/m)
      end

      it "refuses an approval off the roster namedly, never a raw ArgumentError" do
        expect { resume_over(flip("ask", "autto")) }
          .to raise_error(described_class::Refusal, /20260101T000000-1\.ndjson.*autto/m)
      end

      it "refuses a flip missing a side namedly, never a raw ArgumentError" do
        expect { resume_over(flip("ask", "auto").except("from_approval")) }
          .to raise_error(described_class::Refusal, /20260101T000000-1\.ndjson/)
      end
    end

    it "refuses a pre-scribe (headerless, --nvim-era) journal namedly" do
      write_session("20260101T000000-1.ndjson", [{ "type" => "request_sent", "digest" => "blake3:#{"a" * 64}" }])

      expect { resume.call }.to raise_error(described_class::Refusal) do |error|
        expect(error.message).to include("20260101T000000-1.ndjson", "header")
      end
    end

    # Panel fix round (finding 2): the run-state walk carries its OWN cycle
    # guard -- driven here at the seam directly (now {Resume::ChainWalk}, its
    # own extracted object), so its safety is proven independent of the Loader
    # having refused the cycle first (an ordering invariant a reorder of
    # rebuild's statements would silently break).
    it "refuses a cyclic chain in the run-state walk itself, never a SystemStackError" do
      a = open_header(resumed_from: { "file" => "20260102T000000-1.ndjson", "head" => "blake3:#{"1" * 64}" })
      b = open_header(resumed_from: { "file" => "20260101T000000-1.ndjson", "head" => "blake3:#{"2" * 64}" })
      write_session("20260101T000000-1.ndjson", [a])
      write_session("20260102T000000-1.ndjson", [b])

      walk = described_class::ChainWalk.new(dir: paths.sessions_dir)
      expect { walk.paths(File.join(paths.sessions_dir, "20260101T000000-1.ndjson")) }
        .to raise_error(described_class::Refusal) do |error|
          expect(error.message).to include("20260101T000000-1.ndjson", "cycle")
        end
    end

    # Resume repairs a torn head instead of refusing it -- but not a head whose
    # stranded call names no tool_use, which no projection can answer
    # ({Tool::ResultBlock}'s gate 4). That shape must still refuse HERE, with
    # the file on it: deleting the backstop would leave it escaping the exe as
    # a bare ArgumentError with nothing to act on.
    it "refuses an open session whose stranded tool_use names no id, naming the file" do
      anonymous = Lain::Timeline.empty(store: Lain::Store.new)
                                .commit(role: :user, content: text("echo hi"))
                                .commit(role: :assistant,
                                        content: [{ "type" => "tool_use", "name" => "echo",
                                                    "input" => { "text" => "hi" } }])
      write_session("20260101T000000-1.ndjson", [open_header] + turn_records(anonymous))

      expect { resume.call }.to raise_error(described_class::Refusal) do |error|
        expect(error.message).to include("20260101T000000-1.ndjson", "tool")
      end
    end
  end

  # A run stopped between the assistant's `tool_use` commit
  # (agent.rb:433) and the tool_result commit (:516-517) leaves a head no
  # request can be built from: the Messages API rejects an unanswered
  # tool_use. The repair is a PROJECTION onto the rebuilt in-memory
  # timeline -- one user turn answering every stranded call with a
  # cancellation -- and the NDJSON keeps the honest torn record, which is
  # what separates it from the fabrication the backstop refused (that gate
  # collapsed into {Resume::MidTool}; the refusal itself is unchanged).
  describe "a session torn mid-tool (F46)" do
    def tool_use(id) = { "type" => "tool_use", "id" => id, "name" => "echo", "input" => { "text" => "hi" } }

    def rendered(timeline) = recorded_context.render(timeline:, toolset:).messages

    def digest_prefix(digest) = digest.delete_prefix("blake3:")[0, 12]

    let(:torn) do
      Lain::Timeline.empty(store: Lain::Store.new)
                    .commit(role: :user, content: text("echo hi"))
                    .commit(role: :assistant, content: [tool_use("tu_1")])
    end

    let(:path) { write_closed("20260101T000000-1.ndjson", torn) }

    before { path }

    it "resumes rather than refusing" do
      expect { resume.call }.not_to raise_error
    end

    it "forks at its advertised head rather than refusing" do
      expect { resume.fork(selector: "20260101@#{digest_prefix(torn.head_digest)}") }.not_to raise_error
    end

    it "rebuilds a chain the Messages API would accept, with no unanswered tool_use" do
      expect(Lain::Context::Conversation.new(rendered(resume.call.timeline))).to be_valid
    end

    it "answers every stranded call in ONE user turn committed above the recorded head" do
      timeline = resume.call.timeline

      expect(timeline.length).to eq(torn.length + 1)
      expect(timeline.head.role).to eq("user")
      expect(timeline.head.parent).to eq(torn.head_digest)
    end

    it "reports the call as cancelled, and reports no output for the tool" do
      block = resume.call.timeline.head.content.first

      expect(block).to include("type" => "tool_result", "tool_use_id" => "tu_1", "is_error" => true)
      expect(block["content"]).to match(/cancel/i).and match(/no output/i)
    end

    # BLOCKER from review. A fork point can sit BELOW results the journal
    # really recorded: nothing was interrupted, the call returned, and its
    # output is in the very file being forked. The only fact the repair knows
    # is that the conversation IT is continuing carries no result -- so that is
    # the only thing the block may claim.
    it "claims no interruption when forking below results the journal recorded" do
      answered = Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: text("echo hi"))
                               .commit(role: :assistant, content: [tool_use("tu_1")])
      settled = answered
                .commit(role: :user,
                        content: [{ "type" => "tool_result", "tool_use_id" => "tu_1",
                                    "content" => "hi\n", "is_error" => false }])
                .commit(role: :assistant, content: text("done"))
      write_closed("20260105T000000-1.ndjson", settled)

      forked = resume.fork(selector: "20260105@#{digest_prefix(answered.head_digest)}")
      block = forked.timeline.head.content.first

      expect(block).to include("tool_use_id" => "tu_1")
      expect(block["content"]).not_to match(/interrupt/i)
      expect(block["content"]).to match(/no result/i)

      # The SAME standard on the human-facing string: that file did not stop
      # and tu_1 was not unanswered -- it returned, and the session ran on for
      # two more turns. Only the continuation carries no result for it.
      expect(forked.notices).to include(a_string_matching(/no result/i))
      expect(forked.notices).not_to include(a_string_matching(/stopped|unanswered/i))
    end

    # The same falsehood on the other door: an OPEN session is one whose owner
    # may still be appending, so "the run was interrupted" is a guess here too.
    it "claims no interruption when resuming a session that is still open" do
      write_session("20260106T000000-1.ndjson", [open_header] + turn_records(torn))

      block = resume.call(selector: "20260106").timeline.head.content.first

      expect(block["content"]).not_to match(/interrupt/i)
      expect(block["content"]).to match(/no result/i)
    end

    # The tear's own shape: it leaves the file OPEN, so the resume salvages
    # first and repairs second. Both must land.
    it "repairs a torn head in an OPEN (crashed) session too, after salvage" do
      write_session("20260104T000000-1.ndjson", [open_header] + turn_records(torn))

      result = resume.call(selector: "20260104")

      expect(result.open?).to be(true)
      expect(result.timeline.head.content.first).to include("tool_use_id" => "tu_1")
      expect(Lain::Context::Conversation.new(rendered(result.timeline))).to be_valid
    end

    it "leaves the journal file's records byte-identical" do
      before_bytes = File.binread(path)

      resume.call

      expect(File.binread(path)).to eq(before_bytes)
    end

    # The chained header is a claim about the PRIOR FILE, so it must name the
    # digest that file recorded -- never the projected turn, which no journal
    # has ever held. Getting this wrong is silent: the new session writes
    # fine and only refuses as Corrupt when IT is later resumed.
    it "chains the new journal to the recorded head, never to the projected turn" do
      result = resume.call

      expect(result.resumed_from).to eq("file" => File.basename(path), "head" => torn.head_digest)
      expect(result.written).to eq(torn.to_a.map(&:digest))
    end

    # The projection is the new session's own commit, so the new record is
    # where it lands -- and the whole chain must still reload as one verified
    # conversation across the two files.
    it "journals the projected turn into the NEW record, and the chain reloads" do
      result = resume.call
      journal_io = StringIO.new
      chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io))
      chronicle.start(context: recorded_context, toolset:,
                      resumed_from: result.resumed_from, written: result.written)
      chronicle.catch_up(result.timeline)

      new_records = journal_io.string.each_line.map { |line| JSON.parse(line) }
      expect(new_records.select { |record| record["type"] == "turn" }.map { |record| record["digest"] })
        .to eq([result.timeline.head_digest])

      resolver = ->(basename) { basename == result.file ? File.foreach(path) : nil }
      loaded = Lain::Bench::Session::Loader.new(new_records, resolve: resolver)
      expect(loaded.timeline.to_a.map(&:digest)).to eq(result.timeline.to_a.map(&:digest))
    end

    # The one shape the projection cannot answer: {Tool::ResultBlock}'s gate 4
    # refuses to build a block that names no tool_use, and nothing projected
    # would make that chain valid. So the door still refuses -- this is the
    # backstop, now stated by {Resume::MidTool} from {Resume#cancellation}'s
    # rescue arm rather than by a gate that re-asks what that arm already knows.
    it "still refuses namedly when a stranded tool_use carries no pairable id" do
      anonymous = Lain::Timeline.empty(store: Lain::Store.new)
                                .commit(role: :user, content: text("echo hi"))
                                .commit(role: :assistant,
                                        content: [{ "type" => "tool_use", "name" => "echo", "input" => {} }])
      write_closed("20260102T000000-1.ndjson", anonymous)

      expect { resume.call(selector: "20260102") }.to raise_error(described_class::Refusal) do |error|
        expect(error.message).to include("20260102T000000-1.ndjson", "tool")
        # The real reason, not the old one: projecting a result falsifies
        # nothing, so "fabricating results would falsify the record" is now
        # false at the only door that reaches this.
        expect(error.message).to match(/names no tool_use id|nothing can answer/i)
        expect(error.message).not_to match(/falsify|re-ask/i)
      end
    end

    # A journal whose orphan already has user text committed on top of it is
    # damaged history, not a torn head: answering it would mean rewriting a
    # turn the file recorded. The door refuses rather than heals, and says
    # WHERE, so the human can fork at that turn -- where the repair applies.
    context "with user text committed on top of an unanswered tool_use" do
      let(:buried) do
        torn.commit(role: :user, content: text("never mind"))
            .commit(role: :assistant, content: text("ok"))
      end

      before { write_closed("20260104T000000-1.ndjson", buried) }

      it "refuses at both doors, naming the orphan's position and digest" do
        orphan = buried.to_a[1]

        [-> { resume.call(selector: "20260104") },
         -> { resume.fork(selector: "20260104@#{digest_prefix(buried.head_digest)}") }].each do |door|
          expect(&door).to raise_error(described_class::Refusal) do |error|
            expect(error.message).to include("20260104T000000-1.ndjson", "turn 2 of 4", digest_prefix(orphan.digest))
            expect(error.message).to include("tu_1")
          end
        end
      end

      it "names a fork at the orphan itself, which the repair can answer" do
        expect { resume.call(selector: "20260104") }.to raise_error(described_class::Refusal) do |error|
          expect(error.message).to include("--fork 20260104T000000-1.ndjson@#{digest_prefix(buried.to_a[1].digest)}")
        end
      end

      it "says how many recorded turns that fork leaves behind" do
        expect { resume.call(selector: "20260104") }
          .to raise_error(described_class::Refusal, /drops the 2 turns recorded after it/)
      end

      it "forks below the damage without refusing" do
        forked = resume.fork(selector: "20260104@#{digest_prefix(buried.to_a[1].digest)}")

        expect(Lain::Context::Conversation.new(rendered(forked.timeline))).to be_valid
      end
    end

    # A repair that silently changes what the model sees, with no word to the
    # operator, is the invisible mutation the Journal doctrine exists against.
    # Open decision 5 defers the retry AFFORDANCE; disclosure is not that.
    it "tells the human the session was repaired, not only the model" do
      result = resume.call

      expect(result).to be_repaired
      expect(result.notices).to include(a_string_matching(/cancel/i))
    end

    it "projects an untorn session exactly as before: no cancellation result appears" do
      settled = chain("first", "ack", "second")
      write_closed("20260103T000000-1.ndjson", settled)

      result = resume.call(selector: "20260103")

      expect(result.timeline.to_a.map(&:digest)).to eq(settled.to_a.map(&:digest))
      expect(result.timeline.head.content.map { |block| block["type"] }).to eq(["text"])
      expect(result).not_to be_repaired
      expect(result.notices).to be_empty
    end
  end

  # Once the projection repair landed, this refusal fires for exactly ONE
  # shape -- a stranded tool_use naming no id, which {Tool::ResultBlock}'s
  # gate 4 will not pair a result with -- and what it says is the whole of
  # what a human gets. Two things were wrong with what it said. It hardcoded
  # "cannot resume" at a door the user may well have opened with `--fork`,
  # and it sent them to "re-ask the question in a new session", which throws
  # the chain away.
  #
  # The remedy has to be one reachable FROM HERE, which is what rules
  # `/rewind` out even though it can already decline a torn turn:
  # {Lain::CLI::Command::Rewind#call} reads `env.timeline` and `env.agent` --
  # a live REPL -- and this fires while a session is still being loaded, before
  # one exists. `--fork` is reachable, because {Resume#fork} checks out first
  # and refuses second.
  describe "the torn-head refusal names its own door and a reachable remedy (T5)" do
    def prefix_for(digest) = digest.delete_prefix("blake3:")[0, 12]

    # The one shape the projection cannot answer.
    let(:unpairable) do
      Lain::Timeline.empty(store: Lain::Store.new)
                    .commit(role: :user, content: text("echo hi"))
                    .commit(role: :assistant,
                            content: [{ "type" => "tool_use", "name" => "echo", "input" => {} }])
    end

    let(:file) { "20260101T000000-1.ndjson" }

    before { write_closed(file, unpairable) }

    def raised
      yield
      raise "expected a Refusal, none was raised"
    rescue described_class::Refusal => e
      e
    end

    # BOTH doors, driven for real. The card is that they say different things,
    # so nothing here may assert against one of them alone.
    def refusals
      { "resume" => raised { resume.call },
        "fork" => raised { resume.fork(selector: "20260101@#{prefix_for(unpairable.head_digest)}") } }
    end

    it "says resume at the resume door" do
      expect(refusals["resume"].message).to start_with("cannot resume #{file}:")
    end

    it "says fork at the fork door" do
      expect(refusals["fork"].message).to start_with("cannot fork #{file}:")
    end

    it "gives both doors the same reason, in the same words" do
      resumed, forked = refusals.values_at("resume", "fork").map(&:message)

      expect(forked.delete_prefix("cannot fork")).to eq(resumed.delete_prefix("cannot resume"))
      expect(resumed).to include("awaiting tool results")
    end

    it "names forking at an earlier settled turn, at both doors" do
      refusals.each_value do |refusal|
        expect(refusal.message).to include("lain chat --fork", file).and include("earlier").and include("settled")
      end
    end

    # The defect this card exists to fix: a remedy the human cannot reach.
    # Every command that needs a live REPL is a slash command, so "names no
    # slash command" is the mechanical form of the AC -- and `/rewind`, the
    # tempting one, is named explicitly so a later edit cannot re-add it.
    #
    # The lookbehind covers this codebase's own way of writing one. An earlier
    # spelling anchored on whitespace, which reads a bare `/sessions` but not
    # the BACKTICKED `/sessions` every doc comment here uses -- so the guard
    # would have watched a form nobody writes. It excludes `\w` and `.` so a
    # path (`lib/lain`) and a filename are not slash commands; it must NOT
    # exclude the backtick, or it re-opens the very leak it closes.
    it "names no command that needs a live session" do
      refusals.each_value do |refusal|
        expect(refusal.message).not_to match(/rewind/i)
        expect(refusal.message).not_to match(%r{(?<![\w.])/[a-z]+}i)
      end
    end

    it "is a Lain::Error at both doors, so the exe maps it to a message rather than a backtrace" do
      refusals.each_value { |refusal| expect(refusal).to be_a(Lain::Error) }
    end

    # `Lain::Error` is only half the AC: the PROCESS status and whether a frame
    # is printed are Thor's decisions, downstream of exe/lain's
    # `rescue Lain::Error => e; raise Thor::Error, e.message`. A throwaway Thor
    # carrying exactly that line is the smallest thing that can be asked.
    #
    # NO `debug: true` here, deliberately -- debug re-raises and the exit
    # status IS the assertion -- so the SystemExit is caught by {#catch_exit}
    # rather than left to escape. RSpec does not rescue SystemExit inside an
    # example, and a truncated run reports what had already passed as a pass.
    it "exits non-zero at both doors, printing the message and no backtrace frame" do
      refusals.each do |door, refusal|
        status, printed = exe_exit { raise refusal }

        expect(status).to be_positive, "the #{door} door exited #{status.inspect}"
        expect(printed).to include(refusal.message)
        expect(printed).not_to match(/\.rb:\d+:in|^\s+from /)
      end
    end

    def exe_exit(&door)
      captured = StringIO.new
      status = with_stderr(captured) { catch_exit { thor_door(door).start(["door"]) } }
      [status, captured.string]
    end

    def with_stderr(io)
      original = $stderr
      $stderr = io
      yield
    ensure
      $stderr = original
    end

    def catch_exit
      yield
      nil
    rescue SystemExit => e
      e.status
    end

    def thor_door(door)
      Class.new(Thor) do
        def self.exit_on_failure? = true

        desc "door", "the door under test"
        define_method(:door) do
          door.call
        rescue Lain::Error => e
          raise Thor::Error, e.message
        end
      end
    end
  end

  # The spawn-boundary defect, at the door a user actually walks through. A
  # session that spawned writes its child's turns as `child_turn` records and
  # the lineage message that cites them as a `message` record -- and the
  # parent's OWN next turn cites that message back, so the flat records and the
  # render chain cite each other across the spawn boundary. Neither pass can run
  # first, which stranded every spawned session from both `--fork` and
  # `--resume`; the Loader's fixpoint is what re-opens them.
  describe "a session that spawned a subagent" do
    let(:spawn_store) { Lain::Store.new }
    let(:parent) { Lain::Timeline.empty(store: spawn_store).commit(role: :user, content: text("spawn a helper")) }
    let(:child) { Lain::Timeline.empty(store: spawn_store).commit(role: :user, content: text("helper brief")) }

    let(:lineage) do
      Lain::Event::ChainWriter.new.put(parent, kind: :message, from: "child", to: "agent",
                                               causal_parents: [child.head_digest, parent.head_digest],
                                               body: { "summary" => "helper finished" })
    end

    let(:continued) do
      parent.commit(role: :assistant, content: text("helper finished"), causal_parents: [lineage.digest])
    end

    before do
      write_session("20260101T000000-1.ndjson",
                    [open_header, Lain::SessionRecord.turn(parent.head),
                     Lain::Telemetry::ChildTurn.from_event(child.head).to_journal,
                     Lain::Telemetry::Message.from_event(lineage).to_journal,
                     Lain::SessionRecord.turn(continued.head),
                     closed_record(continued.head_digest)])
    end

    it "resumes onto the parent's own recorded head" do
      result = resume.call

      expect(result.timeline.to_a.map(&:digest)).to eq(continued.to_a.map(&:digest))
      expect(result.open?).to be(false)
    end

    it "forks at that same head" do
      forked = resume.fork(selector: "20260101@#{continued.head_digest.delete_prefix("blake3:")[0, 12]}")

      expect(forked.timeline.head_digest).to eq(continued.head_digest)
      expect(forked.resumed_from).to eq("file" => "20260101T000000-1.ndjson", "head" => continued.head_digest)
    end
  end
end
