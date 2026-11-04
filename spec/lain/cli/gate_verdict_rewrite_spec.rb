# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# `lain epic rewrite-verdicts`: rewrites gate_decision records written before
# decisions carried a verdict into the shape every reader now reads, in place,
# keeping a backup and the record chain.
RSpec.describe Lain::CLI::GateVerdictRewrite do
  subject(:rewrite) { described_class.new(paths:, root:) }

  around do |example|
    Dir.mktmpdir("lain-verdict-rewrite") do |state|
      @state = state
      example.run
    end
  end

  let(:root) { File.join(@state, "project").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }) }
  let(:dir) { paths.filing_dir(root:).tap { |path| FileUtils.mkdir_p(path) } }
  let(:session) { File.join(dir, "20261102T170908-346239.ndjson") }

  def old_gate(digest, approved:, answered_by: "human", reason: nil)
    { "type" => "gate_decision", "artifact_digest" => digest, "epic_slug" => "demo", "stage" => "issue_plan",
      "approved" => approved, "answered_by" => answered_by, "policy" => "interactive", "latency" => 1.5,
      "evidence_digest" => nil, "reason" => reason, "issue_id" => "a", "criteria_digest" => nil }
  end

  def unrelated(note) = { "type" => "turn_usage", "note" => note, "nested" => { "prev" => "not a link" } }

  def fixture
    [unrelated("before"),
     old_gate("blake3:approved", approved: true),
     unrelated("between"),
     old_gate("blake3:held", approved: false, answered_by: "held", reason: "after lunch"),
     old_gate("blake3:denied", approved: false, reason: "wrong crate"),
     unrelated("after")]
  end

  def write_session(chain:, path: session)
    Lain::Journal.open(path, chain:, clock: -> { "2026-11-02T17:09:08.000000Z" }) do |journal|
      fixture.each { |record| journal.record(record) }
    end
    path
  end

  def records(path = session) = File.readlines(path).map { |line| JSON.parse(line) }

  def gates(path = session) = records(path).select { |record| record["type"] == "gate_decision" }

  def without_link(record) = record.except(Lain::Journal::LINK)

  describe "the 3 old shapes" do
    it "rewrites approved true to approve, a false held to hold and any other false to deny, keeping the note" do
      write_session(chain: true)

      rewrite.call

      expect(gates.map { |record| record.values_at("artifact_digest", "verdict", "reason") })
        .to eq([["blake3:approved", "approve", nil], ["blake3:held", "hold", "after lunch"],
                ["blake3:denied", "deny", "wrong crate"]])
      expect(gates).to all(satisfy { |record| !record.key?("approved") })
    end

    it "leaves every rewritten record readable by the sign-off fold" do
      write_session(chain: false)

      rewrite.call

      expect { Lain::Epic::SignoffQueue.from_journal(File.readlines(session)) }.not_to raise_error
    end
  end

  describe "every other line" do
    it "keeps each non-gate record's content, its chain link aside" do
      write_session(chain: true)
      before = records.reject { |record| record["type"] == "gate_decision" }.map { without_link(_1) }

      rewrite.call

      after = records.reject { |record| record["type"] == "gate_decision" }.map { without_link(_1) }
      expect(after).to eq(before)
      expect(gates.map { |record| record["verdict"] }).to eq(%w[approve hold deny])
    end

    it "keeps an unchained file's non-gate lines byte for byte" do
      write_session(chain: false)
      before = File.readlines(session).reject { |line| line.include?('"gate_decision"') }

      rewrite.call

      expect(File.readlines(session).reject { |line| line.include?('"gate_decision"') }).to eq(before)
      expect(gates.map { |record| record["verdict"] }).to eq(%w[approve hold deny])
    end
  end

  describe "the record chain" do
    it "re-links a chained file so lain verify reads it intact" do
      write_session(chain: true)

      rewrite.call

      expect(Lain::Journal::Verify.new(session).call.reason).to eq(:intact)
      expect(gates.map { |record| record["verdict"] }).to eq(%w[approve hold deny])
    end

    it "prints each file it changed, its count of rewritten records, and its old and new tip" do
      write_session(chain: true)
      old_tip = Lain::Journal::Verify.new(session).call.tip

      said = rewrite.call

      new_tip = Lain::Journal::Verify.new(session).call.tip
      expect(said).to include(session, "3 gate_decision records rewritten", "tip #{old_tip} -> #{new_tip}")
      expect(new_tip).not_to eq(old_tip)
    end

    it "refuses a file whose chain is already broken, naming it and changing nothing" do
      write_session(chain: true)
      lines = File.readlines(session)
      lines[2] = lines[2].sub("between", "betwixt")
      File.write(session, lines.join)
      before = File.binread(session)

      expect { rewrite.call }.to raise_error(described_class::Refused, /#{Regexp.escape(session)}.*chain/)
      expect(File.binread(session)).to eq(before)
      expect(File.exist?("#{session}#{described_class::BACKUP}")).to be(false)
    end
  end

  describe "the backup" do
    it "keeps the original bytes beside the file, its chain still verifiable" do
      write_session(chain: true)
      original = File.binread(session)

      rewrite.call

      backup = "#{session}#{described_class::BACKUP}"
      expect(File.binread(backup)).to eq(original)
      expect(Lain::Journal::Verify.new(backup).call.reason).to eq(:intact)
    end

    it "is not a session file any reader folds" do
      write_session(chain: true)

      rewrite.call

      expect(Lain::Paths.ndjson_in(dir)).to eq([session])
      expect(Dir.children(dir)).to contain_exactly(File.basename(session),
                                                   "#{File.basename(session)}#{described_class::BACKUP}")
    end
  end

  # Each refusal comes on the SECOND file, so a run that checked one file and
  # wrote it before reaching the next would show here.
  describe "a refusal on the second file" do
    let(:second) { File.join(dir, "20261103T005255-29709.ndjson") }

    before do
      write_session(chain: true)
      write_session(chain: true, path: second)
      @first = File.binread(session)
    end

    def expect_refusal_leaving_first_untouched
      yield

      expect { rewrite.call }.to raise_error(described_class::Refused, /#{Regexp.escape(second)}/)
      expect_first_untouched
    end

    def expect_first_untouched
      expect(File.binread(session)).to eq(@first)
      expect(File.exist?("#{session}#{described_class::BACKUP}")).to be(false)
    end

    it "refuses a backup already in the way, writing no file" do
      expect_refusal_leaving_first_untouched { File.write("#{second}#{described_class::BACKUP}", "kept") }
    end

    it "refuses a broken chain, writing no file" do
      expect_refusal_leaving_first_untouched { File.write(second, File.read(second).sub("between", "betwixt")) }
    end

    it "refuses a session that is a symlink, writing no file and leaving its target alone" do
      target = File.join(@state, "elsewhere.ndjson")
      expect_refusal_leaving_first_untouched do
        FileUtils.mv(second, target)
        File.symlink(target, second)
      end
      expect(File.symlink?(second)).to be(true)
      expect(File.read(target)).not_to include('"verdict"')
    end
  end

  describe "file modes" do
    it "keeps a 0600 session at 0600, and writes its backup 0600 too" do
      write_session(chain: true)
      File.chmod(0o600, session)

      rewrite.call

      expect(File.stat(session).mode & 0o777).to eq(0o600)
      expect(File.stat("#{session}#{described_class::BACKUP}").mode & 0o777).to eq(0o600)
    end

    it "keeps a 0644 session at 0644, and writes its backup 0644 too" do
      write_session(chain: true)
      File.chmod(0o644, session)

      rewrite.call

      expect(File.stat(session).mode & 0o777).to eq(0o644)
      expect(File.stat("#{session}#{described_class::BACKUP}").mode & 0o777).to eq(0o644)
    end
  end

  describe "the rewritten record" do
    it "carries its verdict where approved stood, every other key in its place" do
      write_session(chain: false)
      old_keys = File.readlines(session).map { |line| JSON.parse(line) }
                     .select { |record| record["type"] == "gate_decision" }.map(&:keys)

      rewrite.call

      expect(gates.map(&:keys)).to eq(old_keys.map { |keys| keys.map { _1 == "approved" ? "verdict" : _1 } })
    end
  end

  # A line a session writes after the run looked but before it locked must
  # land in both the rewrite and the backup, so the file is read only once locked.
  describe "a line written just before the lock" do
    it "is kept in the rewritten file and in the backup" do
      write_session(chain: false)
      late = %({"type":"turn_usage","note":"late"}\n)
      allow(File).to receive(:open).and_wrap_original do |original, *args, **options, &block|
        File.write(session, late, mode: "a") if args.first == session && args[1] == "rb" && !@appended
        @appended = true if args.first == session && args[1] == "rb"
        original.call(*args, **options, &block)
      end

      rewrite.call

      expect(File.read(session)).to include('"late"')
      expect(File.read("#{session}#{described_class::BACKUP}")).to include('"late"')
    end
  end

  describe "a second run" do
    it "changes nothing, and says so" do
      write_session(chain: true)
      rewrite.call
      after_first = File.binread(session)

      said = described_class.new(paths:, root:).call

      expect(File.binread(session)).to eq(after_first)
      expect(said).to include("nothing changed")
    end
  end

  describe "a live session" do
    it "refuses a file another writer holds open, naming it and rewriting no file" do
      write_session(chain: false)
      other = write_session(chain: true, path: File.join(dir, "20261103T005255-29709.ndjson"))
      before = File.binread(other)

      Lain::Journal.open(session) do
        expect { rewrite.call }.to raise_error(described_class::Refused, /#{Regexp.escape(session)}.*live/)
      end

      expect(File.binread(other)).to eq(before)
    end
  end

  describe "a project with no sessions" do
    it "says nothing changed" do
      expect(rewrite.call).to include("nothing changed")
    end
  end
end
