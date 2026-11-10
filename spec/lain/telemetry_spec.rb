# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe Lain::Telemetry do
  # The Lain::Event name was freed from telemetry (records moved to
  # Lain::Telemetry) and then reused for the event envelope, which the
  # extension now owns as Lain::Ext::Event. No telemetry record may resolve
  # under the envelope's name.
  it "keeps every telemetry record under Lain::Telemetry, none under the event envelope's name" do
    records = %i[ToolOutput Dropped ProviderRetry TurnUsage RequestSent
                 RequestResent MemoryRoot CapabilityDegraded WriteRefused StreamStarted ObserverFailed]
    records.each do |record|
      expect(described_class.const_defined?(record, false)).to be(true)
      expect(Lain::Ext::Event.const_defined?(record, false)).to be(false)
    end
  end

  # The events whose hand-rolled guards moved to validate-then-freeze (Ruling 2).
  # Construction validates a throwaway Lain::Declarative::Carrier BEFORE the
  # auto-frozen Data value exists, so the value never carries ActiveModel's
  # @errors / @context_for_validation ivars and stays Ractor-shareable.
  #
  # The carriers are NAMED (a {Telemetry::Carriers} constant apiece) rather
  # than anonymous declarations, which is what lets a reader resolve one by
  # the record's own type string rather than by matching structure.
  # Compaction's now-deleted re-derivation audit relied on exactly that:
  # building a carrier by name to validate a record it did not write.
  describe "validate-then-freeze construction" do
    it "exposes a reachable ActiveModel carrier per converted event" do
      expect(Lain::Telemetry::Carriers::Dropped.new(count: 0)).to be_invalid
      expect(Lain::Telemetry::Carriers::TurnUsage.new(digest: nil, stop_reason: :x)).to be_invalid
      expect(Lain::Telemetry::Carriers::RequestSent.new(stream: "yes")).to be_invalid
      expect(Lain::Telemetry::Carriers::MemoryRoot.new(turn_digest: nil)).to be_invalid
      expect(Lain::Telemetry::Carriers::WriteRefused.new(pattern: nil)).to be_invalid
      expect(Lain::Telemetry::Carriers::StreamStarted.new(digest: nil)).to be_invalid
    end

    it "raises ArgumentError naming the attribute AND echoing the value, never ActiveModel::ValidationError" do
      expect { Lain::Telemetry::Dropped.new(count: 0) }
        .to raise_error(ArgumentError, "count must be a positive Integer, got 0")
      # %{value} echoes un-inspected: 'got yes', where the hand-rolled guard said 'got "yes"'.
      expect { Lain::Telemetry::RequestSent.new(digest: "d", payload: {}, stream: "yes", extra: {}) }
        .to raise_error(ArgumentError, "stream must be true or false, got yes")
      expect { Lain::Telemetry::RequestSent.new(digest: "d", payload: {}, stream: nil, extra: {}) }
        .to raise_error(ArgumentError, /stream must be true or false/)
    end

    it "leaves every valid converted event deeply frozen, Ractor-shareable, and @errors-free" do
      valid = [
        Lain::Telemetry::Dropped.new(count: 1),
        Lain::Telemetry::TurnUsage.new(digest: "d", model: nil, stop_reason: :end_turn, usage: {}),
        Lain::Telemetry::RequestSent.new(digest: "d", payload: {}, stream: false, extra: {}),
        Lain::Telemetry::MemoryRoot.new(turn_digest: "d", root: nil),
        Lain::Telemetry::WriteRefused.new(tool_use_id: "t", pattern: "p"),
        Lain::Telemetry::StreamStarted.new(digest: "d")
      ]

      valid.each do |event|
        expect(event).to be_deeply_frozen
        expect(event.instance_variables).not_to include(:@errors)
      end
    end

    # A `settle!` constructor must keep EXPLICIT keywords. `def initialize(**attrs)`
    # reads as a tidy delegation and is not one: it hands arity to ActiveModel,
    # which gives every attribute without a declared default a free nil. `Data`
    # was the thing enforcing "you must name this", and a bare `**attrs` throws
    # that away silently -- no validator fires, because nothing here is invalid,
    # only absent.
    #
    # {TodoSnapshot} and {SlotFills} are why this is pinned rather than trusted:
    # `Canonical.normalize(nil)` is `nil`, so a nameless constructor returns a
    # VALID, journalable record carrying nothing. Evidence that names nothing is
    # the one shape a bench's experiment record must not be able to hold.
    it "refuses a nameless construction on every record that settles, rather than defaulting it to nil" do
      settling = [
        Lain::Telemetry::StreamStarted, Lain::Telemetry::ResendDispatched,
        Lain::Telemetry::MemoryRoot, Lain::Telemetry::WriteRefused,
        Lain::Telemetry::SessionRead, Lain::Telemetry::SessionPin,
        Lain::Telemetry::SupersessionRecord, Lain::Telemetry::ToolCancelled,
        Lain::Telemetry::TodoSnapshot, Lain::Telemetry::SlotFills
      ]

      settling.each do |record|
        expect { record.new }.to raise_error(ArgumentError, /missing keyword/),
                                 "#{record}.new built a record from no arguments at all"
      end
    end

    # The sharper half: an attribute declared WITHOUT a rule -- purely so
    # `settle!` hands it back -- is exactly the one whose arity check vanishes,
    # because no presence validator stands behind it to catch the nil.
    it "keeps a rule-less declared attribute required, which declaring it for settle! quietly un-required" do
      expect { Lain::Telemetry::MemoryRoot.new(turn_digest: "blake3:turn") }
        .to raise_error(ArgumentError, /missing keyword: :root/)
      expect { Lain::Telemetry::WriteRefused.new(pattern: "aws access key id") }
        .to raise_error(ArgumentError, /missing keyword: :tool_use_id/)
    end

    it "journals a TodoSnapshot's head, and refuses one that is not a String or nil" do
      snapshot = Lain::Telemetry::TodoSnapshot.new(todos: [], head: "blake3:head")

      expect(snapshot.to_h).to eq(todos: [], head: "blake3:head")
      expect { Lain::Telemetry::TodoSnapshot.new(todos: [], head: 7) }
        .to raise_error(ArgumentError, /head must be a String or nil, got 7/)
    end
  end

  describe Lain::Telemetry::AssistantText do
    it "journals its text under its own type and is deeply frozen" do
      record = described_class.new(text: +"Here are the paragraphs")

      expect(record.to_journal).to include("type" => "assistant_text", "text" => "Here are the paragraphs")
      expect(record).to be_deeply_frozen
    end
  end

  describe "#journal_type" do
    # The discriminator is pinned by recorded journals, so String#underscore
    # (the ActiveSupport form) MUST produce the exact string recorded journals
    # carry for every event -- a future name that underscores differently fails
    # here, not silently in a replayed journal.
    it "derives each type via underscore" do
      require "active_support/core_ext/string/inflections"
      {
        "ToolOutput" => "tool_output", "Dropped" => "dropped",
        "ProviderRetry" => "provider_retry", "TurnUsage" => "turn_usage",
        "RequestSent" => "request_sent", "RequestResent" => "request_resent",
        "MemoryRoot" => "memory_root",
        "CapabilityDegraded" => "capability_degraded", "WriteRefused" => "write_refused",
        "StreamStarted" => "stream_started", "ObserverFailed" => "observer_failed"
      }.each do |name, expected|
        expect(name.underscore).to eq(expected)
      end
    end

    it "answers the same String for every instance of a class" do
      build = -> { Lain::Telemetry::TurnUsage.new(digest: "d", model: nil, stop_reason: :end_turn, usage: {}) }

      expect(build.call.journal_type).to be(build.call.journal_type)
    end

    it "keys a journal hash with the attribute names, in declaration order after the type" do
      record = Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi")
      journal = record.to_journal

      expect(journal.keys).to eq(["type", *record.to_h.keys.map(&:to_s)])
    end

    it "builds a journal hash without allocating a String per key" do
      record = Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi")
      3.times { record.to_journal }

      before = GC.stat(:total_allocated_objects)
      record.to_journal
      allocated = GC.stat(:total_allocated_objects) - before

      expect(allocated).to be <= 6
    end

    it "is what a converted event actually reports" do
      expect(Lain::Telemetry::TurnUsage.new(digest: "d", model: nil, stop_reason: :end_turn, usage: {}).journal_type)
        .to eq("turn_usage")
    end
  end

  # The committed variance fixtures were written before the rename,
  # so they are the regression proof that the wire format (the `type` tags
  # Journalable#to_journal derives from the class name) did not shift under
  # Bench::Session::Loader -- the loader discriminates records by that string,
  # never by resolving a Lain::Telemetry (nee Lain::Event) class reflectively.
  describe "fixture-load regression: recorded journals still load" do
    fixture_dir = File.expand_path("../fixtures/sessions/variance", __dir__)
    fixture_paths = Dir.glob(File.join(fixture_dir, "*.ndjson"))

    it "finds the committed variance fixtures" do
      expect(fixture_paths).not_to be_empty
    end

    it "loads every fixture, and every parsed record keeps its pre-rename type tag" do
      fixture_paths.each do |path|
        lines = File.readlines(path)
        recorded_types = lines.map { |line| JSON.parse(line).fetch("type") }

        recording = Lain::Bench::Session::Loader.new(lines).recording

        expect(recording.timeline).to be_a(Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store).class)
        expect(recorded_types).to include("request_sent", "turn_usage", "turn", "session")
      end
    end
  end

  # One formatter for every priced record. {Compaction} and {SeamDecision} each
  # carried a private `#decimal`, and the two copies had DRIFTED: Compaction's
  # returned nil for nil (its documented REFUSAL), SeamDecision's did not, so a
  # nil figure there died inside `BigDecimal("")` -- an ArgumentError from the
  # formatter's guts rather than a record refusing its own contract.
  #
  # The shared function is nil-tolerant, because nil is a value one of the two
  # records genuinely journals. Loudness moves to the record that has no refusal
  # to express: {Carriers::SeamDecision} now requires both figures, so the nil that
  # used to blow up inside BigDecimal is named at the boundary instead.
  describe ".fixed_point" do
    it "formats fixed-point, never the scientific notation BigDecimal#to_s reaches for" do
      # Lain loads ActiveSupport's BigDecimal#to_s at boot, so every process reads
      # one format whichever spec first formats a price.
      expect(BigDecimal("0.00012345").to_s).to eq("0.00012345")
      expect(BigDecimal("0.00012345").to_s("E")).to eq("0.12345e-3")
      expect(described_class.fixed_point(BigDecimal("0.00012345"))).to eq("0.00012345")
    end

    it "takes anything BigDecimal() takes and hands back a frozen String" do
      expect(described_class.fixed_point("1.5")).to eq("1.5")
      expect(described_class.fixed_point(2)).to eq("2.0")
      expect(described_class.fixed_point(BigDecimal(0))).to eq("0.0")
      expect(described_class.fixed_point("1.5")).to be_frozen
    end

    # `nil?`, not a truthy test: `false` must still reach BigDecimal and raise,
    # or a JSON boolean lands in a money field and answers #priced? about itself.
    it "passes nil through as the refusal, and still refuses a value that is not a number" do
      expect(described_class.fixed_point(nil)).to be_nil
      expect { described_class.fixed_point(false) }.to raise_error(Lain::Declarative::Types::CoercionError)
    end

    it "is what an unpriced Compaction formats through, so its refusal stays nil in the record" do
      refused = Lain::Telemetry::Compaction.new(trigger: %i[token_threshold], cache_state: :cold,
                                                collapse_strategy: "eager", bytes_before: 100, bytes_after: 40,
                                                cost_saved: nil, cost_spent: nil, model: "claude-opus-4-8")
      expect(refused).not_to be_priced
      expect(refused.to_journal).to include("cost_saved" => nil, "cost_spent" => nil)
    end

    # SeamDecision has no refusal reading: #net does BigDecimal(payback)
    # unconditionally, and Plan::SeamDecision only ever quotes both sides. A nil
    # here is a bug, and it now says so by name at construction.
    it "leaves a SeamDecision with an unquoted side failing at its own contract" do
      expect { seam_decision(rewrite_cost: nil) }
        .to raise_error(ArgumentError, /rewrite_cost must quote/)
      expect { seam_decision(payback: nil) }
        .to raise_error(ArgumentError, /payback must quote/)
      expect(seam_decision.net).to eq(BigDecimal("1.0"))
    end

    def seam_decision(rewrite_cost: BigDecimal("0.5"), payback: BigDecimal("1.5"))
      Lain::Telemetry::SeamDecision.new(size: "M", estimated_turns: 8, calibrated: false, bytes_removed: 900,
                                        bytes_after: 100, rewrite_cost:, payback:, verdict: :rewrite_now)
    end
  end

  describe "Journalable#omitting_defaults" do
    before do
      stub_const("Lain::Telemetry::Carriers::Probe", Class.new(Lain::Declarative::Carrier) do
        attribute :notes, default: -> { [] }
        attribute :kind, default: "tool"
        attribute :extra, default: "x"
      end)
      stub_const("Lain::Telemetry::Probe", Data.define(:notes, :kind, :extra) do
        include Lain::Telemetry::Journalable

        def initialize(**attrs) = super(**Lain::Telemetry::Carriers::Probe.settle!(**attrs))

        def to_journal = omitting_defaults(super, Lain::Telemetry::Carriers::Probe, :notes, :kind)
      end)
    end

    it "drops a named field at its default and keeps type first" do
      journal = Lain::Telemetry::Probe.new.to_journal

      expect(journal).to eq("type" => "probe", "extra" => "x")
      expect(journal.keys.first).to eq("type")
    end

    it "keeps a named field off its default" do
      journal = Lain::Telemetry::Probe.new(kind: "command", notes: ["n"]).to_journal

      expect(journal).to include("kind" => "command", "notes" => ["n"])
    end

    it "never drops a field the call did not name" do
      expect(Lain::Telemetry::Probe.new(extra: "x").to_journal).to include("extra" => "x")
    end
  end

  describe ".read" do
    def written(record, chain: nil)
      io = StringIO.new
      Lain::Journal.new(io:, chain:).record(record)
      Lain::Journal.parse(io.string)
    end

    let(:settled) { Lain::Telemetry::AskSettled.new(head: "blake3:head", stop_reason: "end_turn", turns: 2, seconds: 1.5) }

    it "reads a journaled line back as the record written" do
      expect(described_class.read(written(settled))).to eq(settled)
    end

    it "brings back a field the record left off at its default" do
      closed = Lain::Telemetry::SessionClosed.new(head: "blake3:head", reason: :exit)
      line = written(closed)

      expect(line).not_to have_key("error")
      expect(described_class.read(line)).to eq(closed).and have_attributes(error: nil)
    end

    it "carries a type nobody claims whole, without the Journal's stamp" do
      line = written({ "type" => "turn", "digest" => "blake3:t", "role" => "user", "parent" => nil, "meta" => {} })
      read = described_class.read(line)

      expect(read).to be_a(Lain::Telemetry::Untyped).and have_attributes(type: "turn")
      expect(read.fields.keys).to match_array(%w[type digest role parent meta])
    end

    it "refuses a torn record of its own when strict, naming the type, and carries it whole when lenient" do
      torn = written(settled).except("head")

      expect { described_class.read(torn) }.to raise_error(Lain::Telemetry::Unreadable, /ask_settled.*head/)
      expect(described_class.read(torn, strict: false)).to be_a(Lain::Telemetry::Untyped)
        .and have_attributes(type: "ask_settled")
    end

    it "gives a chained line's own link back under its name, and drops the Journal's" do
      line = written({ "type" => "rewound", "prev" => "blake3:own" }, chain: Lain::Journal::Line::ORIGIN)

      expect(described_class.read(line).fields).to eq("type" => "rewound", "prev" => "blake3:own")
    end
  end
end
