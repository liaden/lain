# frozen_string_literal: true

require "json"
require "tmpdir"

# T19: `lain sessions` -- an honest listing of this project's recorded
# sessions, newest first. Derivation only reads the records (header, turn
# count, closer, resumed_from); it never re-verifies the Merkle chain, which
# is the Loader's job at resume time. Returns a String; only the frontend
# renders (output discipline).
RSpec.describe Lain::CLI::Sessions do
  around do |example|
    Dir.mktmpdir { |dir| @state_home = dir and example.run }
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home }) }
  let(:context) { Lain::Context.new(model: "recorded-model", max_tokens: 512, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

  subject(:sessions) { described_class.new(paths:) }

  def text(body) = [{ "type" => "text", "text" => body }]

  def chain(*bodies)
    bodies.each_with_index.inject(Lain::Timeline.empty(store: Lain::Store.new)) do |timeline, (body, i)|
      timeline.commit(role: i.even? ? :user : :assistant, content: text(body))
    end
  end

  # A real file stamps every record with "ts" (Journal#record does); the
  # fixture stamps the header the same way so started-at has a source.
  def header(started_at:, resumed_from: nil)
    record = Lain::SessionRecord.header(context:, toolset:, head: nil).merge("ts" => started_at)
    resumed_from.nil? ? record : record.merge("resumed_from" => resumed_from)
  end

  def write_session(name, records)
    path = File.join(paths.sessions_dir, name)
    File.write(path, "#{records.map { |record| JSON.generate(record) }.join("\n")}\n")
    path
  end

  def closed_record(head) = Lain::Telemetry::SessionClosed.new(head:, reason: :exit).to_journal

  describe "#listing" do
    context "with two closed sessions and one open one" do
      let(:oldest) { chain("one", "two") }
      let(:open_chain) { chain("three") }
      let(:newest) { chain("four", "five") }

      before do
        write_session("20260101T000000-1.ndjson",
                      [header(started_at: "2026-01-01T00:00:00.000000Z")] +
                      oldest.to_a.map { |turn| Lain::SessionRecord.turn(turn) } +
                      [closed_record(oldest.head_digest)])
        write_session("20260102T000000-1.ndjson",
                      [header(started_at: "2026-01-02T00:00:00.000000Z")] +
                      open_chain.to_a.map { |turn| Lain::SessionRecord.turn(turn) })
        write_session("20260103T000000-1.ndjson",
                      [header(started_at: "2026-01-03T00:00:00.000000Z",
                              resumed_from: { "file" => "20260101T000000-1.ndjson",
                                              "head" => oldest.head_digest })] +
                      newest.to_a.map { |turn| Lain::SessionRecord.turn(turn) } +
                      [closed_record(newest.head_digest)])
      end

      let(:lines) { sessions.listing.lines.map(&:chomp) }

      it "lists newest first" do
        expect(lines.map { |line| line[/\S+/] })
          .to eq(%w[20260103T000000-1.ndjson 20260102T000000-1.ndjson 20260101T000000-1.ndjson])
      end

      it "marks each open or closed, honestly" do
        expect(lines[0]).to include("closed")
        expect(lines[1]).to include("open")
        expect(lines[1]).not_to include("closed")
        expect(lines[2]).to include("closed")
      end

      it "marks the resumed session as chained" do
        expect(lines[0]).to include("chained")
        expect(lines[1]).not_to include("chained")
        expect(lines[2]).not_to include("chained")
      end

      it "shows started-at, the turn count, and the short head digest" do
        expect(lines[2]).to include("2026-01-01", "2 turns", oldest.head_digest[0, 19])
        expect(lines[1]).to include("1 turns", open_chain.head_digest[0, 19])
      end
    end

    # T3: ephemerality lives in the FILENAME (<ts>-<pid>.btw.ndjson), so the
    # listing's default view is the durable record only; --all is the honest
    # escape hatch, and promotion (a rename) moves a file between the two
    # views with no record rewritten.
    context "with an ephemeral (--btw) session beside a durable one" do
      let(:durable) { chain("one", "two") }
      let(:scratch) { chain("three") }

      before do
        write_session("20260101T000000-1.ndjson",
                      [header(started_at: "2026-01-01T00:00:00.000000Z")] +
                      durable.to_a.map { |turn| Lain::SessionRecord.turn(turn) } +
                      [closed_record(durable.head_digest)])
        write_session("20260102T000000-9.btw.ndjson",
                      [header(started_at: "2026-01-02T00:00:00.000000Z")] +
                      scratch.to_a.map { |turn| Lain::SessionRecord.turn(turn) })
      end

      it "hides the ephemeral by default" do
        expect(sessions.listing).to include("20260101T000000-1.ndjson")
        expect(sessions.listing).not_to include(".btw.ndjson")
      end

      it "lists it under all:" do
        expect(sessions.listing(all: true))
          .to include("20260101T000000-1.ndjson", "20260102T000000-9.btw.ndjson")
      end

      it "hides an ephemeral-only directory into the honest empty state by default" do
        File.delete(File.join(paths.sessions_dir, "20260101T000000-1.ndjson"))

        expect(sessions.listing).to include("no sessions")
      end

      it "lists a promoted session in the default view -- promotion is just the rename" do
        Lain::Paths::Ephemeral.new(File.join(paths.sessions_dir, "20260102T000000-9.btw.ndjson")).promote!

        expect(sessions.listing).to include("20260102T000000-9.ndjson")
        expect(sessions.listing).not_to include(".btw.ndjson")
      end
    end

    it "answers an honest empty-state line naming the directory" do
      expect(sessions.listing).to include("no sessions", paths.sessions_dir)
    end

    it "lists a headerless file as unreadable instead of raising" do
      File.write(File.join(paths.sessions_dir, "20260101T000000-1.ndjson"), "not json at all\n")

      expect(sessions.listing).to include("20260101T000000-1.ndjson", "unreadable")
    end
  end
end
