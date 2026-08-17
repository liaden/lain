# frozen_string_literal: true

require "json"
require "tmpdir"

# T19: `lain sessions` -- an honest listing of this project's recorded
# sessions, newest first. Derivation only reads the records (header, turn
# count, closer, resumed_from); it never re-verifies the Merkle chain, which
# is the Loader's job at resume time. Returns a String; only the frontend
# renders (output discipline).
RSpec.describe Lain::CLI::Sessions do
  subject(:sessions) { described_class.new(paths:) }

  around do |example|
    Dir.mktmpdir { |dir| @state_home = dir and example.run }
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home }) }
  let(:context) { Lain::Context.new(model: "recorded-model", max_tokens: 512, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

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
      let(:lines) { sessions.listing.lines.map(&:chomp) }

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

    # T3 fix round: both are headerless, but they have different causes and
    # different fixes -- a zero-byte file is Journal.open's artifact from a
    # chat that died before its header, while an unreadable one holds bytes
    # nobody can load. Calling the empty one "unreadable" sends a reader
    # hunting corruption that is not there.
    it "reads a zero-byte session as empty and a headerless one as unreadable" do
      File.write(File.join(paths.sessions_dir, "20260101T000000-1.ndjson"), "")
      File.write(File.join(paths.sessions_dir, "20260102T000000-1.ndjson"), "not json at all\n")

      expect(sessions.listing).to match(/20260102T000000-1\.ndjson.*unreadable/)
        .and match(/20260101T000000-1\.ndjson.*\bempty\b/)
    end

    # The THIRD headerless case, and it arrived with `lain review`: a file whose
    # records load perfectly and simply are not a chat's. It is neither empty nor
    # corrupt, so both existing words are wrong about it -- and "unreadable" is
    # wrong in the expensive direction, sending a reader hunting damage that is
    # not there, which is the confusion the empty/unreadable split already exists
    # to end. Named by what it holds instead.
    it "names a headerless file whose records DO load, rather than calling it unreadable" do
      File.write(File.join(paths.sessions_dir, "20260103T000000-1.ndjson"),
                 %({"ts":"2026-01-03T00:00:00Z","type":"changeset_opened","source":"local_branch"}\n))

      expect(sessions.listing).to match(/20260103T000000-1\.ndjson.*changeset_opened/)
      expect(sessions.listing).not_to match(/20260103T000000-1\.ndjson.*unreadable/)
    end

    # F6/T7: Journal.records' skip-foreign-bytes contract (journal.rb:131-136)
    # is sound -- the fd can be shared with Rust tracing spans -- but applied to
    # lain's OWN torn record it left a damaged session looking intact: the same
    # header, the same "open"/"closed" status, just one turn short under an
    # unmoved head digest. These three examples are T7's Gherkin ACs verbatim.
    # "unparsed", not "torn": the row states exactly what was measured (a line
    # that did not parse), not a cause it cannot know -- a single blank line
    # in an otherwise-perfect session is unparsed, not corruption.
    it "reports how many lines a torn turn record cost, among otherwise-valid records" do
      turn_records = chain("one", "two").to_a.map { |turn| Lain::SessionRecord.turn(turn) }
      lines = [
        JSON.generate(header(started_at: "2026-01-01T00:00:00.000000Z")),
        JSON.generate(turn_records[0]),
        "not json at all",
        JSON.generate(turn_records[1]),
        "{torn"
      ]
      File.write(File.join(paths.sessions_dir, "20260101T000000-1.ndjson"), "#{lines.join("\n")}\n")

      expect(sessions.listing).to match(/20260101T000000-1\.ndjson.*2 lines unparsed/)
    end

    # Pins the FULL row, not just the absence of a word -- a weak
    # `not_to include("unparsed")` would still pass a mutant that always
    # appended damage text under a different word. Only an exact match on the
    # intact row rules that out.
    it "carries no damage indication when every line parses" do
      intact = chain("one")
      write_session("20260101T000000-1.ndjson",
                    [header(started_at: "2026-01-01T00:00:00.000000Z")] +
                    intact.to_a.map { |turn| Lain::SessionRecord.turn(turn) })

      expect(sessions.listing)
        .to eq("20260101T000000-1.ndjson  2026-01-01T00:00:00  1 turns  open  #{intact.head_digest[0, 19]}")
    end

    # Exactly one unparseable line -- the singular arm of the pluralisation.
    # Without this, a mutant collapsing `@skipped == 1 ? "line" : "lines"` to
    # always answer "lines" survives the whole suite.
    it "still lists a damaged session, by name and status, and pluralises singular damage correctly" do
      turn_records = chain("one").to_a.map { |turn| Lain::SessionRecord.turn(turn) }
      lines = [
        JSON.generate(header(started_at: "2026-01-01T00:00:00.000000Z")),
        JSON.generate(turn_records[0]),
        "garbage"
      ]
      File.write(File.join(paths.sessions_dir, "20260101T000000-1.ndjson"), "#{lines.join("\n")}\n")

      expect(sessions.listing).to include("20260101T000000-1.ndjson", "open", "1 line unparsed")
    end

    # The headerless branch (`unloadable`) returns early, BEFORE the normal
    # render line -- so damage on that path used to be invisible, and worse:
    # a session whose header itself is torn, but whose first surviving record
    # happens to be a `turn`, was mislabelled "turn, not a chat" -- a POSITIVE
    # false claim that sends a reader away from real damage, the exact
    # opposite of what `unloadable`'s own third-case comment exists to avoid.
    it "still names its damage when the header itself failed to parse" do
      turn = Lain::SessionRecord.turn(chain("one").to_a.first)
      File.write(File.join(paths.sessions_dir, "20260101T000000-1.ndjson"),
                 "{\"type\":\"sessio\n#{JSON.generate(turn)}\nalso torn\n{{{\n")

      expect(sessions.listing).to match(/20260101T000000-1\.ndjson.*3 lines unparsed/)
    end
  end

  # F6/T7 review fix: LineCount is a public constant with a public
  # attr_reader, and `include Enumerable` promises `#each` is safe to drive
  # more than once -- so `lines_read` must describe only the MOST RECENT walk,
  # never an accumulation across walks. Not reachable through `Row.for` today
  # (which walks its LineCount exactly once), but nothing about the public
  # shape says a future caller may not re-enumerate it.
  describe Lain::CLI::Sessions::LineCount do
    it "reports only the most recent walk's count, not an accumulation across repeated enumeration" do
      counter = described_class.new([1, 2, 3])

      counter.to_a
      counter.to_a

      expect(counter.lines_read).to eq(3)
    end
  end
end
