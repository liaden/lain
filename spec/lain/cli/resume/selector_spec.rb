# frozen_string_literal: true

require "json"
require "tmpdir"

# "Which file does --resume mean". The rule this file pins: the bare and prefix
# picks answer only with something the Loader can actually load, because
# UTC-timestamped names make the newest file the one the bare pick lands on and
# `sessions_dir` is not a chat's private directory -- `lain epic approve`
# appends its sign-off decision there too (T13).
#
# Naming a file EXACTLY stays honored either way: salvaging a crashed session is
# deliberate, not an accident of sorting.
RSpec.describe Lain::CLI::Resume::Selector do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:context) { Lain::Context.new(model: "recorded-model", max_tokens: 512, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

  subject(:selector) { described_class.new(dir: @dir) }

  def write(name, records)
    path = File.join(@dir, name)
    File.write(path, records.empty? ? "" : "#{records.map { |r| JSON.generate(r) }.join("\n")}\n")
    path
  end

  # A real chat: {SessionRecord::Scribe} writes the header at construction, so
  # it is always a session file's FIRST record.
  def session(name, at:)
    write(name, [Lain::SessionRecord.header(context:, toolset:, head: nil).merge("ts" => at)])
  end

  # What `lain epic approve` leaves behind: a durable, non-ephemeral, non-empty
  # journal holding one terminal gate decision and no session header.
  def drain(name, at:)
    write(name, [Lain::Approval::GateDecision.new(artifact_digest: "blake3:#{"a" * 64}", epic_slug: "alpha",
                                                  stage: "research", approved: true, answered_by: "human",
                                                  policy: "signoff", latency: 3.0).to_journal.merge("ts" => at)])
  end

  def picked(input = nil) = File.basename(selector.call(input))

  describe "the bare pick" do
    it "answers with the real session, not the drain file written after it" do
      session("20260727T090000-111.ndjson", at: "2026-07-27T09:00:00Z")
      drain("20260728T080000-222.ndjson", at: "2026-07-28T08:00:00Z")

      expect(picked).to eq("20260727T090000-111.ndjson")
    end

    it "still answers with the newest genuine session" do
      session("20260727T090000-111.ndjson", at: "2026-07-27T09:00:00Z")
      session("20260728T090000-222.ndjson", at: "2026-07-28T09:00:00Z")
      drain("20260728T100000-333.ndjson", at: "2026-07-28T10:00:00Z")

      expect(picked).to eq("20260728T090000-222.ndjson")
    end

    # The idempotence claim the class defends: a resumed session writes its
    # header before it can exit, so the head of the chain is never a file this
    # skips -- a second --resume continues the chain rather than forking it.
    it "keeps a resumed session selectable, so --resume stays idempotent" do
      session("20260727T090000-111.ndjson", at: "2026-07-27T09:00:00Z")
      resumed = Lain::SessionRecord.header(context:, toolset:, head: nil)
                                   .merge("ts" => "2026-07-28T09:00:00Z",
                                          "resumed_from" => { "file" => "20260727T090000-111.ndjson" })
      write("20260728T090000-222.ndjson", [resumed])

      expect(picked).to eq("20260728T090000-222.ndjson")
    end

    it "refuses namedly when a drain file is the only thing in the directory" do
      drain("20260728T080000-222.ndjson", at: "2026-07-28T08:00:00Z")

      expect { selector.call(nil) }.to raise_error(Lain::CLI::Resume::Refusal, /no sessions to resume/)
    end

    # "No sessions" said about a directory the user can SEE files in is a
    # refusal they stop believing, and the count is what makes it actionable.
    it "counts the skipped drain file separately from an empty one" do
      drain("20260728T080000-222.ndjson", at: "2026-07-28T08:00:00Z")
      write("20260728T081000-333.ndjson", [])

      expect { selector.call(nil) }.to raise_error(Lain::CLI::Resume::Refusal,
                                                   /1 empty .*and 1 with no session header/m)
    end

    # Named, not merely counted: it is the one skip that stays selectable, so
    # hiding the filename would hide the only thing that lets a reader act.
    it "names the skipped file and says what it probably is" do
      drain("20260728T080000-222.ndjson", at: "2026-07-28T08:00:00Z")

      expect { selector.call(nil) }
        .to raise_error(Lain::CLI::Resume::Refusal, /20260728T080000-222\.ndjson.*sign-off journal/m)
    end

    # The advice used to read "name one exactly to load it anyway", and it was
    # simply false: a headerless file refuses at the Loader too, by exact name
    # or not. Identify the file; promise nothing.
    it "does not promise that naming it exactly will load it" do
      drain("20260728T080000-222.ndjson", at: "2026-07-28T08:00:00Z")

      expect { selector.call(nil) }.to raise_error(Lain::CLI::Resume::Refusal) do |error|
        expect(error.message).not_to match(/load it anyway/)
      end
    end

    # A reader acts on the most recent one, so that is the end that gets named.
    it "names the NEWEST few and summarizes the older ones" do
      5.times { |i| drain("20260728T08000#{i}-22#{i}.ndjson", at: "2026-07-28T08:0#{i}:00Z") }

      expect { selector.call(nil) }.to raise_error(Lain::CLI::Resume::Refusal) do |error|
        expect(error.message).to include("20260728T080004-224.ndjson", "+2 older")
        expect(error.message).not_to include("20260728T080000-220.ndjson")
      end
    end

    it "separates three reasons with commas rather than chaining them on 'and'" do
      write("20260728T080000-111.ndjson", [])
      drain("20260728T080001-222.ndjson", at: "2026-07-28T08:01:00Z")
      drain("20260728T080002-223.ndjson", at: "2026-07-28T08:02:00Z")
      session("20260728T080003-224.btw.ndjson", at: "2026-07-28T08:03:00Z")

      expect { selector.call(nil) }.to raise_error(Lain::CLI::Resume::Refusal, /, and 1 ephemeral/)
    end
  end

  describe "the prefix pick" do
    # The prefix matches BOTH files, so this can only pass by the drain file
    # being filtered out -- a prefix unique to the session would have passed
    # against the old code too, and proved nothing.
    it "skips a drain file, so a prefix matching both answers with the session" do
      session("20260728T090000-111.ndjson", at: "2026-07-28T09:00:00Z")
      drain("20260728T090000-222.ndjson", at: "2026-07-28T09:30:00Z")

      expect(picked("20260728T090000-")).to eq("20260728T090000-111.ndjson")
    end

    it "is still ambiguous between two genuine sessions" do
      session("20260728T090000-111.ndjson", at: "2026-07-28T09:00:00Z")
      session("20260728T090000-222.ndjson", at: "2026-07-28T09:30:00Z")

      expect { selector.call("20260728T090000-") }
        .to raise_error(Lain::CLI::Resume::Refusal, /is ambiguous/)
    end

    it "refuses a prefix that uniquely names a drain file, rather than handing back a Corrupt load" do
      session("20260727T090000-111.ndjson", at: "2026-07-27T09:00:00Z")
      drain("20260728T080000-222.ndjson", at: "2026-07-28T08:00:00Z")

      expect { selector.call("20260728") }
        .to raise_error(Lain::CLI::Resume::Refusal, /has no "session" header record.*sign-off journal/m)
    end
  end

  describe "the exact-filename pick" do
    # Deliberate, not an accident of sorting: someone naming a drain file has
    # said which file they mean, and this class does not second-guess that.
    it "stays honored for a headerless file" do
      drain("20260728T080000-222.ndjson", at: "2026-07-28T08:00:00Z")

      expect(picked("20260728T080000-222.ndjson")).to eq("20260728T080000-222.ndjson")
    end

    it "still refuses a named empty file, saying exactly that" do
      write("20260728T080000-222.ndjson", [])

      expect { selector.call("20260728T080000-222.ndjson") }
        .to raise_error(Lain::CLI::Resume::Refusal, /nothing was ever recorded into it/)
    end
  end

  # `Journal.empty?` answers "absent" and "zero bytes" alike with true, so the
  # short-circuit covers a file reaped before the header read. It cannot cover
  # everything: a name that lists but will not open as a stream of lines reaches
  # the read itself, and unpickable is the only honest answer.
  describe "a listed name that cannot be read as a journal" do
    it "is skipped rather than raising out of the pick" do
      session("20260727T090000-111.ndjson", at: "2026-07-27T09:00:00Z")
      Dir.mkdir(File.join(@dir, "20260728T090000-222.ndjson"))

      expect(picked).to eq("20260727T090000-111.ndjson")
    end
  end

  # The documented window: a live session is genuinely zero bytes between
  # Journal.open and the moment the Scribe writes its header, so it is skipped
  # today by the empty check and is NOT newly excluded by the header check.
  describe "a session starting right now" do
    it "is skipped for being empty, exactly as before" do
      session("20260727T090000-111.ndjson", at: "2026-07-27T09:00:00Z")
      write("20260728T090000-222.ndjson", [])

      expect(picked).to eq("20260727T090000-111.ndjson")
    end
  end
end
