# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Epic::GateDecision do
  verdicts = Lain::Approval::Verdict

  def decision(verdict, policy: "signoff")
    described_class.new(artifact_digest: "blake3:plan", epic_slug: "alpha", stage: "epic_plan", verdict:,
                        answered_by: policy, policy:, latency: 0.1)
  end

  describe "the deferred verdict" do
    it "is deferred, and neither approved, held nor denied" do
      deferred = described_class::Deferred.new(note: "unsure")

      expect([deferred.deferred?, deferred.approved?, deferred.held?, deferred.denied?, deferred.note])
        .to eq([true, false, false, false, "unsure"])
    end

    it "refuses a note that is not a String, by the rule every verdict's note follows" do
      expect { described_class::Deferred.new(note: 5) }.to raise_error(ArgumentError, /note must be a String or nil/)
    end
  end

  describe ".coerce" do
    it "returns each of approve, hold, deny and deferred as given" do
      given = [verdicts::Approve.new, verdicts::Hold.new, verdicts::Deny.new, described_class::Deferred.new]

      expect(given.map { described_class.coerce(_1) }).to eq(given)
    end

    it "refuses a word, a boolean or a symbol" do
      ["deferred", true, :deny].each do |value|
        expect { described_class.coerce(value) }.to raise_error(ArgumentError, /not a gate verdict/)
      end
    end
  end

  describe "the journaled verdict" do
    it "keeps a deny under the deferred policy a deny, since a verdict is never read off its policy" do
      expect(decision(verdicts::Deny.new(note: "doubt"), policy: "deferred").to_journal)
        .to include("verdict" => "deny", "reason" => "doubt", "policy" => "deferred")
    end

    it "says deferred for a deferred verdict handed over as one" do
      expect(decision(described_class::Deferred.new).to_journal).to include("verdict" => "deferred")
    end

    it "reads a deferred record back as the deferred verdict, its reason as the note" do
      record = decision(described_class::Deferred.new(note: "later")).to_journal

      expect(described_class.verdict_in(record)).to eq(described_class::Deferred.new(note: "later"))
    end

    it "refuses a record carrying only the old approved boolean, naming no rewrite command" do
      record = decision(verdicts::Deny.new).to_journal.except("verdict").merge("approved" => false)

      expect { described_class.verdict_in(record) }.to raise_error(ArgumentError) { |error|
        expect(error.message).to include("verdict must be one of approve, hold, deny, deferred")
        expect(error.message).not_to include("rewrite")
      }
    end
  end

  # Scenario: landing refuses a change outside scope unless the gate admitted it
  describe "#admitted" do
    def approved(note) = decision(Lain::Approval::Verdict::Approve.new(note:))

    it "reads the path prefixes an approval's note admits" do
      expect(approved("admit spike/").admitted).to eq(["spike/"])
    end

    it "reads several, split by commas or spaces, after other words of the note" do
      expect(approved("re-signed; admit spike/, docs/notes.md").admitted).to eq(["spike/", "docs/notes.md"])
    end

    it "stops at the first word that is not a path" do
      expect(approved("approve, admit spike/ for lib").admitted).to eq(["spike/"])
    end

    it "admits nothing when the word after admit is not a path" do
      expect(approved("cannot admit defeat").admitted).to eq([])
    end

    it "reads admit only as a word of its own, never inside another" do
      expect(approved("readmit spike/").admitted).to eq([])
    end

    it "admits nothing for a bare ./, so no empty prefix is journaled" do
      expect(approved("admit ./").admitted).to eq([])
    end

    it "drops an entry that names no path segment" do
      ["admit .", "admit /", "admit ././", "admit ./, /"].each do |note|
        expect(approved(note).admitted).to eq([]), note
      end
    end

    it "calls a path with a comma unnameable, since the reply splits on it" do
      expect(described_class.admit_advice(["a,b.md"]))
        .to eq("a,b.md cannot be admitted by name; remove it from the commit")
    end

    it "advises admitting the paths a reply can name, and removing those it cannot" do
      expect(described_class.admit_advice(["spike/src/main.rs", "my file.rb", "a;b"]))
        .to eq('answer admit <path> to land it anyway, as in "approve, admit spike/src/main.rs"; ' \
               "my file.rb, a;b cannot be admitted by name; remove them from the commit")
      expect(described_class.admit_advice(["a\tb"])).to eq("a\tb cannot be admitted by name; remove it from the commit")
    end

    it "reads a root file written as ./Makefile as Makefile" do
      expect(approved("admit ./Makefile").admitted).to eq(["Makefile"])
    end

    it "words an admit reply for every path, root files included, in a form it reads back whole" do
      paths = ["spike/src/main.rs", "Makefile", ".env"]
      reply = described_class.admit_reply(paths)

      expect(reply).to eq("approve, admit spike/src/main.rs, ./Makefile, .env")
      expect(described_class.admitted_in(Lain::Epic::GateReply.read(reply))).to eq(paths)
    end

    it "admits nothing for an approval without the word, or none at all" do
      expect([approved("looks right").admitted, decision(verdicts::Approve.new).admitted]).to eq([[], []])
    end

    it "admits nothing on a deny or a hold, whatever its note says" do
      expect([decision(verdicts::Deny.new(note: "admit spike/")).admitted,
              decision(verdicts::Hold.new(note: "admit spike/")).admitted]).to eq([[], []])
    end

    it "journals the admitted prefixes beside the reason" do
      expect(approved("admit spike/").to_journal).to include("admitted" => ["spike/"], "reason" => "admit spike/")
    end

    it "journals no admitted key when it admits nothing, so the wire shape of every other decision stands" do
      expect(approved("looks right").to_journal).not_to have_key("admitted")
    end

    it "reads an old record without the field as admitting nothing" do
      record = decision(verdicts::Approve.new).to_journal.except("admitted")

      expect(described_class.admitted_in(described_class.verdict_in(record))).to eq([])
    end

    it "reads the prefixes back off a journaled approval's verdict" do
      record = approved("admit spike/").to_journal

      expect(described_class.admitted_in(described_class.verdict_in(record))).to eq(["spike/"])
    end

    it "is deeply frozen" do
      expect(Ractor.shareable?(approved("admit spike/"))).to be(true)
    end
  end

  describe "a gate with policy deferred" do
    it "journals the parked submission's verdict as deferred" do
      io = StringIO.new
      journal = Lain::Journal.new(io:)
      queue = Lain::Epic::SignoffQueue.new
      policy = Lain::Epic::Gate::Policy::Deferred.new(queue:, digests: nil, journal:)
      plan = Data.define(:digest, :gate_question).new(digest: "blake3:plan", gate_question: "Approve the research?")
      gate = Lain::Epic::Gate.new(journal:, timeout: 0.5)

      Sync { policy.decide(plan, gate:, stage: "research", epic_slug: "alpha") }

      expect(journal_records(io, "gate_decision")).to contain_exactly(include("verdict" => "deferred"))
      expect(Lain::Epic::SignoffQueue.from_journal(io.string.lines).parked("alpha", "research").map(&:artifact_digest))
        .to eq(["blake3:plan"])
    end
  end
end
