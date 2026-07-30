# frozen_string_literal: true

# Coverage for Lain::Approval::Gate.from_journal and the private registry fold
# it is built on (#absorb). Started life as 17 adversarial review probes; the
# ones that found real defects are
# converted here to pin the FIXED behaviour (panel doctrine: probes that find
# a real defect become specs, they are not deleted). The ones that found
# nothing wrong are kept as regression coverage and documentation.
RSpec.describe "Lain::Approval::Gate.from_journal -- T3 fix round" do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:clock) { -> { 0.0 } }

  def gate = Lain::Approval::Gate.new(journal:, clock:)
  def rebuild(entries) = Lain::Approval::Gate.from_journal(entries, journal:, clock:)

  def decision(digest:, approved:, **overrides)
    { "type" => "gate_decision", "artifact_digest" => digest, "epic_slug" => "lain-epics",
      "stage" => "epic_plan", "approved" => approved, "answered_by" => "human",
      "policy" => "interactive", "latency" => 0.1, "evidence_digest" => nil, "reason" => nil }
      .merge(overrides)
  end

  def artifact(digest)
    Struct.new(:digest, :gate_question).new(digest, "ok?")
  end

  # Fix 1: from_journal used to restate #initialize's defaults
  # (`timeout: DEFAULT_TIMEOUT, clock: MONOTONIC`) instead of forwarding to
  # them, and the restated `MONOTONIC` went stale when the real constant moved
  # to RunClock::MONOTONIC -- raising NameError on every call that omitted
  # `clock:`. Fixed by forwarding `**options` straight to `.new` so this class
  # of drift can't recur.
  describe "forwarding #initialize's own defaults, not restating them" do
    it "does not raise when clock: (or timeout:) is omitted -- there is no second copy of the default to go stale" do
      expect { Lain::Approval::Gate.from_journal([], journal:) }.not_to raise_error
    end

    it "still forwards an explicitly given timeout:, the same as a plain .new would" do
      rebuilt = Lain::Approval::Gate.from_journal([], journal:, timeout: 0.01, clock:)

      expect { Sync { rebuilt.call(artifact("x"), asker: silent_asker, stage: "s", epic_slug: "e") } }
        .not_to raise_error
      expect(JSON.parse(journal_io.string.lines.first))
        .to include("approved" => false, "answered_by" => "timeout", "latency" => 0.01)
    end
  end

  # Confirmed good by the panel -- add-only means no order of the same records
  # can disagree, so this is left exactly as found (do not churn it).
  describe "fold-order independence -- add-only means any order agrees" do
    it "agrees on approve-then-deny and deny-then-approve of ONE digest" do
      forward = [decision(digest: "d", approved: true), decision(digest: "d", approved: false)]

      expect(rebuild(forward).approved?("d")).to be(true)
      expect(rebuild(forward.reverse).approved?("d")).to be(true)
    end

    it "is idempotent under duplicate approvals and associative under any permutation" do
      records = [decision(digest: "a", approved: true), decision(digest: "a", approved: true),
                 decision(digest: "b", approved: false), decision(digest: "c", approved: true)]

      results = records.permutation.map { |order| rebuild(order).to_a.sort }

      expect(results.uniq).to eq([%w[a c]])
    end

    it "agrees with the incremental live path -- fold == replayed #call" do
      Sync do
        live = gate
        live.call(artifact("d"), asker: asker(true), stage: "s", epic_slug: "e")
        live.call(artifact("d"), asker: asker(false), stage: "s", epic_slug: "e")
        expect(rebuild(journal_io.string.lines).to_a).to eq(live.to_a)
      end
    end
  end

  # Fix 2 + Fix 3 (they collapsed into one guard, as anticipated): the fold
  # used to be a public #apply reachable on any Gate with any Hash at all --
  # unlike SignoffQueue#apply, it had no field guard, and it had no caller that
  # needed the publicity (#call registers directly; nothing folds one live
  # decision at a time here). Both are fixed together: the fold moved private
  # (reached only from .from_journal, via #absorb) and gained
  # Guards::RegistryEntry, the same TRUNCATION CANARY reasoning
  # SignoffQueue::Guards::Decision already applies to this wire shape.
  describe "the fold is private and guards the two fields it reads" do
    it "has no public #apply a live Gate could be tricked into registering an unjournaled approval through" do
      expect(gate).not_to respond_to(:apply)
    end

    it "raises rather than registering an approval when `approved` arrives as the STRING \"false\"" do
      expect { rebuild([decision(digest: "d", approved: "false")]) }
        .to raise_error(ArgumentError, /approved/)
    end

    it "raises rather than registering nil when artifact_digest is missing" do
      expect { rebuild([decision(digest: nil, approved: true)]) }
        .to raise_error(ArgumentError, /artifact_digest/)
    end

    it "never reaches a turn_usage record with the fold at all -- from_journal's type filter runs first" do
      foreign = { "type" => "turn_usage", "artifact_digest" => "d", "approved" => true }

      expect(rebuild([foreign]).approved?("d")).to be(false)
    end
  end

  # NEGATIVE RESULT, kept as documentation: the folded digest is a raw String
  # off the Hash with no explicit dup/freeze in #absorb, but Set is
  # Hash-backed and Hash#[]= dup-freezes a String key, so a caller mutating
  # the source Hash's digest after from_journal returns cannot corrupt the
  # registry. Rewritten to go through from_journal (the only surface left)
  # rather than the removed #apply.
  describe "string mutability of the folded digest (NOT a defect)" do
    it "keeps the approval even when the caller mutates the source Hash's digest String afterwards" do
      digest = +"blake3:abc"
      rebuilt = rebuild([decision(digest:, approved: true)])
      digest << "-tampered"

      expect(rebuilt.approved?("blake3:abc")).to be(true)
      expect(rebuilt.to_a.first).to be_frozen
    end
  end

  # Confirmed good -- malformed NDJSON is handled the same way every other
  # Journal reader handles it, and the missing (epic_slug, stage) partition
  # filter is documented scope (see .from_journal's own comment), not a bug.
  describe "malformed / foreign entries" do
    it "skips a truncated NDJSON line rather than raising" do
      lines = [%({"type":"gate_decision","artifact_digest":"d","approved":tr),
               JSON.generate(decision(digest: "e", approved: true))]

      expect(rebuild(lines).to_a).to eq(%w[e])
    end

    it "folds an empty entry list into an empty registry" do
      expect(rebuild([]).to_a).to be_empty
    end

    it "registers a gate_decision from a DIFFERENT epic_slug -- no partition filter, by design" do
      foreign = decision(digest: "d", approved: true, "epic_slug" => "some-other-epic")

      expect(rebuild([foreign]).approved?("d")).to be(true)
    end

    it "skips a bare JSON array line and a non-JSON line" do
      expect { rebuild(["[1,2,3]\n", "not json at all\n"]) }.not_to raise_error
    end
  end

  # Confirmed good -- a rebuilt Gate behaves exactly like a normal one.
  describe "a rebuilt Gate behaves as a normal Gate" do
    it "still journals its own future verdicts, and #each/#ensure_approved! work" do
      rebuilt = rebuild([decision(digest: "old", approved: true)])

      Sync { rebuilt.call(artifact("new"), asker: asker(true), stage: "s", epic_slug: "e") }

      expect(rebuilt.to_a.sort).to eq(%w[new old])
      expect(rebuilt.ensure_approved!(artifact("old"))).to eq("old")
      expect(journal_io.string.lines.size).to eq(1)
      expect(JSON.parse(journal_io.string.lines.first)).to include("artifact_digest" => "new")
    end

    it "still raises NoReactor outside a reactor" do
      rebuilt = rebuild([])

      expect { rebuilt.call(artifact("x"), asker: asker(true), stage: "s", epic_slug: "e") }
        .to raise_error(Lain::Approval::Gate::NoReactor)
    end

    it "does NOT re-journal the entries it replayed" do
      rebuild([decision(digest: "d", approved: true)])

      expect(journal_io.string).to be_empty
    end
  end

  def asker(verdict)
    surface = "human"
    Class.new do
      define_method(:ask) do |_question|
        Lain::Promise.new.tap { |p| p.resolve(Lain::Approval::Gate::Answer.new(approved: verdict, surface:)) }
      end
    end.new
  end

  def silent_asker
    Class.new { def ask(_question) = Lain::Promise.new }.new
  end
end
