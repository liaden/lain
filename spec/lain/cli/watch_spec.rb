# frozen_string_literal: true

require "json"
require "socket"
require "stringio"
require "tmpdir"
require "fileutils"

# `lain watch SELECTOR` -- a read-only live view of ONE actor's stream.
# It tails a live session journal, admits only records whose lineage chains
# to the watched spawn S (decided from the Message records' explicit NDJSON
# fields alone -- from/to/causal_parents -- never by Store reconstruction),
# renders each through an injected sink, and exits 0 on session_closed -- or
# 1 once the writer its header records is gone without having closed it.
RSpec.describe Lain::CLI::Watch do
  around do |example|
    Dir.mktmpdir { |dir| @state_home = dir and example.run }
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home }) }
  let(:context) { Lain::Context.new(model: "recorded-model", max_tokens: 512, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

  let(:parent_correlation) { "9f00111122223333444455556666777788889999aaaabbbbccccddddeeeeffff" }
  let(:s_spawn_digest)     { "5aaa111122223333444455556666777788889999aaaabbbbccccddddeeeeffff" }
  let(:t_spawn_digest)     { "7bbb111122223333444455556666777788889999aaaabbbbccccddddeeeeffff" }
  let(:s_reply_digest)     { "5ccc111122223333444455556666777788889999aaaabbbbccccddddeeeeffff" }
  let(:selector) { "5aaa" }

  let(:output) { StringIO.new }

  let(:parent_chain) do
    Lain::Timeline.empty(store: Lain::Store.new)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "find the papers" }])
  end

  def header_record
    Lain::SessionRecord.header(context:, toolset:).merge("ts" => "2026-07-23T00:00:00.000000Z")
  end

  def spawn_record(digest:)
    Lain::Telemetry::Message.new(
      digest:, kind: :spawn, from: parent_correlation, to: nil,
      payload: { "prefix" => "worker", "posture" => "trusted", "only" => nil,
                 "spawned_from" => parent_chain.head_digest, "lifecycle" => "launched" },
      causal_parents: [parent_chain.head_digest], correlation: parent_correlation
    ).to_journal
  end

  def message_record(digest:, from:, to:, text:, causal_parents:, lifecycle: nil)
    payload = lifecycle.nil? ? { "text" => text } : { "text" => text, "lifecycle" => lifecycle }
    Lain::Telemetry::Message.new(digest:, kind: :message, from:, to:, payload:,
                                 causal_parents:, correlation: parent_correlation).to_journal
  end

  def closed_record = Lain::Telemetry::SessionClosed.new(head: parent_chain.head_digest, reason: :exit).to_journal

  # The parent's tell, addressed TO the spawn -- chains by `to`, not `from`.
  def tell_record
    message_record(digest: "1add#{s_spawn_digest[4..]}", from: parent_correlation, to: s_spawn_digest,
                   text: "narrow to RCTs", causal_parents: [s_spawn_digest])
  end

  # The session's opening act: header, one parent turn, and BOTH actors'
  # spawns -- present before the interleaved traffic in every scenario.
  def opening_records
    [header_record] +
      parent_chain.to_a.map { |turn| Lain::SessionRecord.turn(turn) } +
      [spawn_record(digest: s_spawn_digest), spawn_record(digest: t_spawn_digest), tell_record]
  end

  # The interleaved tails of both actors, plus one record that chains to S
  # only TRANSITIVELY (its causal parent is S's reply, not S's spawn).
  def traffic_records
    [message_record(digest: "7ddd#{t_spawn_digest[4..]}", from: t_spawn_digest, to: parent_correlation,
                    text: "T finished", causal_parents: [t_spawn_digest], lifecycle: "settled"),
     message_record(digest: s_reply_digest, from: s_spawn_digest, to: parent_correlation,
                    text: "S found 3 papers", causal_parents: [s_spawn_digest], lifecycle: "settled"),
     message_record(digest: "5eee#{s_reply_digest[4..]}", from: "otherchain", to: parent_correlation,
                    text: "S addendum", causal_parents: [s_reply_digest])]
  end

  def write_journal(records, name: "20260723T000000-1.ndjson")
    path = File.join(paths.sessions_dir, name)
    File.write(path, "#{records.map { |record| JSON.generate(record) }.join("\n")}\n")
    path
  end

  def append_journal(path, records)
    File.open(path, "ab") { |io| records.each { |record| io.write("#{JSON.generate(record)}\n") } }
  end

  def append_bytes(path, bytes)
    File.open(path, "ab") { |io| io.write(bytes) }
  end

  describe "following one actor's stream" do
    subject(:watch) { described_class.new(selector:, path:, sink: output, paths:) }

    let!(:path) { write_journal(opening_records + traffic_records + [closed_record]) }

    it "exits 0 on session_closed" do
      expect(watch.run).to eq(0)
    end

    it "renders S's spawn, the messages addressed to and from S, and the transitive chain" do
      watch.run
      expect(output.string).to include("narrow to RCTs").and include("S found 3 papers").and include("S addendum")
    end

    it "renders nothing of the other actor's stream" do
      watch.run
      expect(output.string).not_to include("T finished")
      expect(output.string).not_to include(t_spawn_digest[0, 8])
    end

    it "renders no parent turn records" do
      watch.run
      expect(output.string).not_to include("find the papers")
    end
  end

  # Every fixture above spells its digests bare (no "blake3:" scheme) for
  # brevity; a REAL session records the full "blake3:<hex>" address
  # ({Canonical#digest_of}), and a human copies a bare hex prefix off wherever
  # they saw it -- `lain watch`'s own {View}, a journal line, a spawn's
  # `lineage.rb` note -- never the scheme. This group is the one place the
  # fixture carries the real shape, so the selector's own hex-below-the-scheme
  # matching (`CLI::ForkPoint`'s idiom) is exercised rather than accidentally
  # passing because every digest here happens to start with hex already.
  describe "a bare hex prefix, against a digest recorded with its full blake3: scheme" do
    subject(:watch) { described_class.new(selector: "c81907db9d1c", path:, sink: output, paths:) }

    let(:scheme_spawn_digest) { "blake3:c81907db9d1c111122223333444455556666777788889999aaaabbbbccccdddd" }
    let!(:path) do
      write_journal([header_record, spawn_record(digest: scheme_spawn_digest), closed_record])
    end

    it "anchors and renders the lineage" do
      expect(watch.run).to eq(0)
      expect(output.string).to include("spawned from")
    end
  end

  # A one-shot's completion carries a terminal lifecycle mark now, and this
  # view prefixes any mark it finds -- so an operator tailing a one-shot reads
  # "(stopped) <result>" where the line used to be bare. That is the same
  # shape an actor's farewell already rendered in, which is the point, but a
  # line an operator reads is not allowed to change unpinned: nothing else in
  # this file renders a `result` body at all.
  describe "a one-shot child's completion" do
    subject(:watch) { described_class.new(selector:, path:, sink: output, paths:) }

    # The BODY comes from the real writer rather than being spelled out here,
    # unlike every other record in this file: what this example is about is
    # that what {Tools::Subagent::Lineage#message} writes today renders with a
    # mark, so a hand-written body would pin the renderer and miss the change.
    # Only the chaining fields are synthetic, so it reaches the watched spawn.
    let(:completion_body) do
      policy = Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: [])
      lineage = Lain::Tools::Subagent::Lineage.new(policy:)
      child = Lain::Timeline.empty(store: parent_chain.store)
                            .commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
      lineage.message(parent_chain, lineage.spawn(parent_chain, prompt: "go"), child,
                      Data.define(:text).new(text: "child answer")).body
    end

    let(:completion) do
      Lain::Telemetry::Message.new(
        digest: "5fff#{s_reply_digest[4..]}", kind: :message, from: s_spawn_digest,
        to: parent_correlation, payload: completion_body,
        causal_parents: [s_spawn_digest], correlation: parent_correlation
      ).to_journal
    end
    let!(:path) { write_journal(opening_records + [completion, closed_record]) }

    it "renders the result behind its terminal mark" do
      watch.run

      expect(output.string).to include("(stopped) child answer")
    end
  end

  # The address `--windows` hands a pane: two subagent calls in one assistant
  # turn spawn from one head, and a watch given one of them has to follow that
  # child alone. Every record comes from the real writer, since what separates
  # the two is the spawn body it writes and nothing a fixture could stamp.
  describe "one of two one-shots spawned from one head" do
    let(:policy) { Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []) }
    let(:lineage) { Lain::Tools::Subagent::Lineage.new(policy:) }
    let(:answer) { Data.define(:text) }

    def child_of(prompt)
      Lain::Timeline.empty(store: parent_chain.store)
                    .commit(role: :user, content: [{ "type" => "text", "text" => prompt }])
    end

    def journaled(event) = Lain::Telemetry::Message.from_event(event).to_journal

    it "renders only the watched child's result" do
      aspirin = lineage.spawn(parent_chain, prompt: "survey the aspirin trials")
      statin = lineage.spawn(parent_chain, prompt: "survey the statin trials")
      completions = [lineage.message(parent_chain, aspirin, child_of("aspirin"), answer.new(text: "ASPIRIN-RESULT")),
                     lineage.message(parent_chain, statin, child_of("statin"), answer.new(text: "STATIN-RESULT"))]
      records = [header_record] + parent_chain.to_a.map { |turn| Lain::SessionRecord.turn(turn) } +
                [aspirin, statin, *completions].map { |event| journaled(event) } + [closed_record]
      path = write_journal(records)

      described_class.new(selector: aspirin.digest, path:, sink: output, paths:).run

      expect(output.string).to include("ASPIRIN-RESULT")
      expect(output.string).not_to include("STATIN-RESULT")
    end
  end

  describe "tailing a live file" do
    it "picks up records appended after EOF and exits 0 once the closer lands" do
      path = write_journal(opening_records)
      appended = false
      sleeper = lambda do |_seconds|
        raise "watch polled again after the closer was appended" if appended

        appended = true
        append_journal(path, traffic_records + [closed_record])
      end
      watch = described_class.new(selector:, path:, sink: output, paths:, sleeper:)

      expect(watch.run).to eq(0)
      expect(output.string).to include("S found 3 papers")
    end
  end

  # A writer's line can be torn at the tail: IO#gets at EOF returns the
  # written half WITHOUT a newline. A tailer that consumes it desyncs -- both
  # halves fail parse separately and the record is silently lost.
  describe "torn writes" do
    let(:torn_reply) do
      JSON.generate(message_record(digest: s_reply_digest, from: s_spawn_digest, to: parent_correlation,
                                   text: "TORN-RECORD-TEXT", causal_parents: [s_spawn_digest]))
    end

    def watch_with_steps(path, steps)
      exhausted = -> { raise "watch polled again after the closer landed" }
      described_class.new(selector:, path:, sink: output, paths:,
                          sleeper: ->(_seconds) { (steps.shift || exhausted).call })
    end

    it "holds a torn record's fragment and renders it whole once the second half lands" do
      path = write_journal(opening_records)
      half = torn_reply.bytesize / 2
      steps = [
        -> { append_bytes(path, torn_reply.byteslice(0, half)) },
        -> { append_bytes(path, "#{torn_reply.byteslice(half..)}\n") },
        -> { append_journal(path, [closed_record]) }
      ]

      expect(watch_with_steps(path, steps).run).to eq(0)
      expect(output.string).to include("TORN-RECORD-TEXT")
    end

    it "recognizes a session_closed record torn across two polls" do
      path = write_journal(opening_records)
      closer = JSON.generate(closed_record)
      half = closer.bytesize / 2
      steps = [
        -> { append_bytes(path, closer.byteslice(0, half)) },
        -> { append_bytes(path, "#{closer.byteslice(half..)}\n") }
      ]

      expect(watch_with_steps(path, steps).run).to eq(0)
    end
  end

  describe "an ambiguous selector" do
    subject(:watch) { described_class.new(selector: "5", path:, sink: output, paths:) }

    let(:second_spawn_digest) { "5bbb222233334444555566667777888899990000aaaabbbbccccddddeeeeffff" }

    let!(:path) do
      write_journal([header_record,
                     spawn_record(digest: s_spawn_digest),
                     spawn_record(digest: second_spawn_digest),
                     message_record(digest: "1111#{s_spawn_digest[4..]}", from: s_spawn_digest,
                                    to: parent_correlation, text: "FROM-ACTOR-ONE",
                                    causal_parents: [s_spawn_digest]),
                     message_record(digest: "2222#{second_spawn_digest[4..]}", from: second_spawn_digest,
                                    to: parent_correlation, text: "FROM-ACTOR-TWO",
                                    causal_parents: [second_spawn_digest]),
                     closed_record])
    end

    it "anchors the FIRST matching spawn only" do
      watch.run
      expect(output.string).to include("FROM-ACTOR-ONE")
      expect(output.string).not_to include("FROM-ACTOR-TWO")
    end

    it "names the ignored spawn loudly" do
      watch.run
      expect(output.string)
        .to include("selector also matches #{second_spawn_digest}; watching #{s_spawn_digest} only")
    end
  end

  # Old-reader tolerance: raw garbage, unknown record types, journal_error
  # records, and a CHAINED message whose payload is not a Hash (an old or
  # foreign writer's shape) must all be tolerated, never crash the tail.
  describe "malformed and foreign lines" do
    subject(:watch) { described_class.new(selector:, path:, sink: output, paths:) }

    let!(:path) do
      write_journal(opening_records).tap do |journal|
        append_bytes(journal, "this is not json at all\n")
        append_journal(journal, [{ "type" => "future_record", "digest" => "x" },
                                 { "type" => "journal_error", "error" => "boom" },
                                 { "type" => "message", "kind" => "message", "digest" => "3333#{"c" * 60}",
                                   "from" => s_spawn_digest, "to" => parent_correlation,
                                   "payload" => ["weird"], "causal_parents" => [s_spawn_digest] },
                                 { "type" => "message", "kind" => "message", "digest" => "4444#{"d" * 60}",
                                   "from" => s_spawn_digest, "to" => parent_correlation,
                                   "payload" => nil, "causal_parents" => [s_spawn_digest] },
                                 closed_record])
      end
    end

    it "survives them all and still exits 0 on the closer" do
      expect(watch.run).to eq(0)
    end

    it "renders a chained non-Hash payload as nothing, like other tolerated garbage" do
      watch.run
      expect(output.string).not_to include("weird")
    end
  end

  describe "a selector matching no spawn" do
    subject(:watch) { described_class.new(selector: "beef", path:, sink: output, paths:) }

    let!(:path) { write_journal(opening_records + [closed_record]) }

    it "says so instead of ending silent, naming the session file it searched" do
      watch.run
      expect(output.string).to include('no spawn matched selector "beef"', File.basename(path))
    end

    it "answers exit status 1, distinguishable from a quiet actor" do
      expect(watch.run).to eq(1)
    end
  end

  describe "read-only by construction" do
    subject(:watch) { described_class.new(selector:, path:, sink: output, paths:) }

    let!(:path) { write_journal(opening_records + [closed_record]) }

    it "opens the journal read-only and leaves its bytes untouched" do
      modes = []
      allow(File).to receive(:open).and_wrap_original do |original, *args, **kwargs, &block|
        modes << args[1]
        original.call(*args, **kwargs, &block)
      end
      before_bytes = File.binread(path)

      watch.run

      expect(modes).to eq(["r"])
      expect(File.binread(path)).to eq(before_bytes)
    end

    it "holds no Store, no provider, and no Channel" do
      watch.run
      held = watch.instance_variables.map { |name| watch.instance_variable_get(name) }
      expect(held.grep(Lain::Store)).to be_empty
      expect(held.grep(Lain::Provider)).to be_empty
      expect(held.grep(Lain::Channel)).to be_empty
    end
  end

  describe "refusals" do
    it "refuses an empty selector loudly" do
      expect { described_class.new(selector: "", path: "anywhere", sink: output) }
        .to raise_error(Lain::Error, /selector/)
    end

    it "refuses to guess when no session exists" do
      watch = described_class.new(selector:, sink: output, paths:)
      expect { watch.run }.to raise_error(Lain::Error, /no sessions/)
    end
  end

  # A fix round: the newest-session pick filtered on the ".ndjson" suffix
  # ALONE, so it admitted both a zero-byte file (Journal.open creates the file
  # before the header lands) and a `.btw` scratch session that `lain sessions`
  # and `--resume` both hide. Tailing an empty file is unbounded by
  # construction: the session_closed that stops the poll can never arrive in a
  # file nobody is writing.
  describe "choosing the newest session with no --session" do
    # Any poll here is the bug: every fixture below either closes or refuses.
    subject(:watch) { described_class.new(selector:, sink: output, paths:, sleeper:) }

    let(:sleeper) { ->(_seconds) { raise "watch polled a file that can never close" } }

    def write_empty(name) = File.write(File.join(paths.sessions_dir, name), "")

    it "refuses a zero-byte newest session with a message instead of polling it forever" do
      write_empty("20260724T000000-1.ndjson")

      expect { watch.run }.to raise_error(Lain::Error, /no sessions/)
    end

    # "No sessions" while `ls` shows files is a refusal the user stops
    # believing. Name what was passed over, and why it could never have ended.
    it "counts what it skipped rather than claiming an empty directory" do
      write_empty("20260724T000000-1.ndjson")
      write_empty("20260725T000000-1.ndjson")
      write_journal(opening_records, name: "20260726T000000-9.btw.ndjson")

      expect { watch.run }
        .to raise_error(Lain::Error) { |error|
              expect(error.message).to include(paths.sessions_dir, "2 empty", "1 ephemeral")
            }
    end

    it "skips a zero-byte newest for the newest session that can actually close" do
      write_journal(opening_records + traffic_records + [closed_record])
      write_empty("20260724T000000-1.ndjson")

      expect(watch.run).to eq(0)
      expect(output.string).to include("S found 3 papers")
    end

    it "ignores an ephemeral newest, choosing the newest durable session instead" do
      write_journal(opening_records + traffic_records + [closed_record])
      write_journal(opening_records, name: "20260724T000000-9.btw.ndjson")

      expect(watch.run).to eq(0)
      expect(output.string).to include("S found 3 papers")
    end
  end

  # An explicitly named file is an instruction, not a guess, so watch honors it
  # even when it holds nothing yet -- a live session IS empty for the instant
  # between Journal.open and its header. But an unbounded wait with no output
  # and no exit is indistinguishable from a hang, and the reviewer's probe sat
  # through 500+ polls in silence. Saying so costs one line and turns it into a
  # deliberate wait.
  describe "an explicit --session naming a file with no records yet" do
    it "says it is waiting, naming the file, before the first poll" do
      path = File.join(paths.sessions_dir, "20260723T000000-1.ndjson")
      File.write(path, "")
      polls = 0
      sleeper = lambda do |_seconds|
        polls += 1
        raise "polled without ever saying why" if output.string.empty?

        append_journal(path, [closed_record])
      end

      described_class.new(selector:, path:, sink: output, paths:, sleeper:).run

      expect(output.string).to include("waiting for records", path)
      expect(polls).to eq(1)
    end

    it "stays silent about waiting for a file that already has records" do
      path = write_journal(opening_records + traffic_records + [closed_record])

      described_class.new(selector:, path:, sink: output, paths:).run

      expect(output.string).not_to include("waiting for records")
    end
  end

  # A live chat's header records its writer as a lease does: pid, start in
  # clock ticks since boot, and host. A session killed before it could write
  # session_closed leaves nothing else that would ever end the tail.
  describe "a session whose writer is gone without closing it" do
    let(:never_poll) { ->(_seconds) { raise "watch polled a session whose writer is gone" } }

    def start_of(pid) = File.read("/proc/#{pid}/stat").rpartition(")").last.split.fetch(19)

    def dead_pid = Process.spawn("true").tap { |pid| Process.wait(pid) }

    def writer(pid, start) = { "writer" => { "pid" => pid, "start" => start, "host" => Socket.gethostname } }

    def opened_by(fields) = [header_record.merge(fields), *opening_records.drop(1)]

    it "renders what the writer left, says it ended without closing the session, and exits 1" do
      path = write_journal(opened_by(writer(dead_pid, start_of(Process.pid))) + traffic_records)

      status = described_class.new(selector:, path:, sink: output, paths:, sleeper: never_poll).run

      expect(status).to eq(1)
      expect(output.string).to include("S found 3 papers")
      expect(output.string).to include("ended without closing the session", File.basename(path))
    end

    it "reads a pid now held by a later process as the writer gone" do
      path = write_journal(opened_by(writer(Process.pid, "1")))

      expect(described_class.new(selector:, path:, sink: output, paths:, sleeper: never_poll).run).to eq(1)
    end

    it "still says no spawn matched, beside the writer's end" do
      path = write_journal(opened_by(writer(dead_pid, "1")))

      described_class.new(selector: "beef", path:, sink: output, paths:, sleeper: never_poll).run

      expect(output.string).to include("ended without closing the session", 'no spawn matched selector "beef"')
    end

    # The writer can land its last records and exit between the read that hit
    # the end of the file and the question whether it still runs.
    it "reads what the writer landed before it exited, once it is found gone" do
      path = write_journal(opened_by(writer(Process.pid, start_of(Process.pid))))
      probe = instance_double(Lain::Liveness::Probe)
      allow(probe).to receive(:of) do
        append_journal(path, traffic_records)
        :dead
      end

      status = described_class.new(selector:, path:, sink: output, paths:, probe:, sleeper: never_poll).run

      expect([status, output.string]).to match([1, a_string_including("S found 3 papers")])
    end
  end

  describe "a session whose writer may still be writing it" do
    def start_of(pid) = File.read("/proc/#{pid}/stat").rpartition(")").last.split.fetch(19)

    def writer(pid, start) = { "writer" => { "pid" => pid, "start" => start, "host" => Socket.gethostname } }

    # Appends the closer on the third poll, so a watch that concluded early
    # returns before it and one that waited returns 0.
    def watch_until_closed(path, **)
      polls = 0
      sleeper = lambda do |_seconds|
        polls += 1
        append_journal(path, [closed_record]) if polls == 3
      end
      [described_class.new(selector:, path:, sink: output, paths:, sleeper:, **).run, polls]
    end

    it "keeps tailing while the writer its header records is live" do
      path = write_journal([header_record.merge(writer(Process.pid, start_of(Process.pid))),
                            *opening_records.drop(1)])

      expect(watch_until_closed(path)).to eq([0, 3])
    end

    # The system clock stepping forward moves nothing a start in clock ticks is
    # compared against, so a live writer stays live however far it steps.
    it "keeps tailing a live writer after the wall clock steps forward by hours" do
      Dir.mktmpdir("lain-proc") do |proc_root|
        FileUtils.mkdir_p(File.join(proc_root, Process.pid.to_s))
        # Read and written rather than copied: a procfs file reports its size as zero.
        File.write(File.join(proc_root, Process.pid.to_s, "stat"), File.read("/proc/#{Process.pid}/stat"))
        stepped = File.read("/proc/stat").sub(/^btime (\d+)$/) { "btime #{Integer(Regexp.last_match(1)) + (3 * 3600)}" }
        File.write(File.join(proc_root, "stat"), stepped)
        name = "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}.ndjson"
        path = write_journal([header_record.merge(writer(Process.pid, start_of(Process.pid)))] +
                             opening_records.drop(1), name:)

        expect(watch_until_closed(path, probe: Lain::Liveness::Probe.new(proc_root:))).to eq([0, 3])
      end
    end

    # A header written before writers were recorded says nothing about its
    # writer, whatever pid its file's name carries.
    it "keeps tailing a session whose header records no writer" do
      gone = Process.spawn("true").tap { |pid| Process.wait(pid) }
      path = write_journal(opening_records, name: "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{gone}.ndjson")

      expect(watch_until_closed(path)).to eq([0, 3])
    end

    it "keeps waiting on an empty file, which has no header to name a writer yet" do
      path = File.join(paths.sessions_dir, "20260723T000000-1.ndjson")
      File.write(path, "")

      expect(watch_until_closed(path).last).to eq(3)
    end
  end
end
