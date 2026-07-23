# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# T7: `lain watch SELECTOR` -- a read-only live view of ONE actor's stream.
# It tails a live session journal, admits only records whose lineage chains
# to the watched spawn S (decided from the Message records' explicit NDJSON
# fields alone -- from/to/causal_parents -- never by Store reconstruction),
# renders each through an injected sink, and exits 0 on session_closed.
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
    let!(:path) { write_journal(opening_records + traffic_records + [closed_record]) }

    subject(:watch) { described_class.new(selector:, path:, sink: output, paths:) }

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

    subject(:watch) { described_class.new(selector: "5", path:, sink: output, paths:) }

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

    subject(:watch) { described_class.new(selector:, path:, sink: output, paths:) }

    it "survives them all and still exits 0 on the closer" do
      expect(watch.run).to eq(0)
    end

    it "renders a chained non-Hash payload as nothing, like other tolerated garbage" do
      watch.run
      expect(output.string).not_to include("weird")
    end
  end

  describe "a selector matching no spawn" do
    let!(:path) { write_journal(opening_records + [closed_record]) }

    subject(:watch) { described_class.new(selector: "beef", path:, sink: output, paths:) }

    it "says so instead of ending silent" do
      watch.run
      expect(output.string).to include('no spawn matched selector "beef"')
    end

    it "answers exit status 1, distinguishable from a quiet actor" do
      expect(watch.run).to eq(1)
    end
  end

  describe "read-only by construction" do
    let!(:path) { write_journal(opening_records + [closed_record]) }

    subject(:watch) { described_class.new(selector:, path:, sink: output, paths:) }

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
end
