# frozen_string_literal: true

require "json"
require "stringio"
require "tempfile"

# Session.load reads one run back from the NDJSON the Scribe writes: the live
# run's journal (request_sent from an innermost JournalRequests, turn_usage from
# the Agent's journal:) plus the "session" header, one "turn" record per turn
# and the session_closed anchor. From those bytes alone it rebuilds everything a
# DryReplay baseline needs -- so the determinism claim of the whole experiment
# survives a disk round trip, and content-addressing doubles as the integrity
# check over the CONTENT: the transport fields (stream, extra) sit outside
# Request#digest and load unverified.
RSpec.describe Lain::Bench::Session do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:workspace) { Lain::Workspace.empty }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }

  # A genuine two-model-call run (tool_use, then end_turn) whose journal already
  # carries the live-run records a Session extends: request_sent from an
  # INNERMOST JournalRequests (the bytes the provider actually received) and
  # turn_usage from the Agent's journal:.
  let(:run) do
    responses = [tool_response(["tu_1", "echo", { "text" => "hi" }], usage:, model: "claude-opus-4-8"),
                 text_response("done", usage:, model: "claude-opus-4-8")]
    record_journaled_run(responses, journal:, toolset:, context:, workspace:)
  end

  let(:agent) { run.first }
  let(:provider) { run.last }

  def write_session(into: journal, under: context, compaction: {})
    Lain::SessionRecord::Scribe.new(journal: into, context: under, toolset:, workspace:, compaction:,
                                    writer: CoreGraph::NO_WRITER)
                               .catch_up(agent.timeline).close(reason: :exit)
  end

  def load_session
    described_class.load(journal_io.string.each_line)
  end

  def parsed_records
    journal_records(journal_io)
  end

  describe "the header" do
    # The silent failure mode of "the header captures exactly Lain::Context's
    # constructor inputs": Context grows a kwarg, the header records nothing,
    # every spec stays green, and an old recording reloads to a Context that
    # renders different bytes -- booked as DIVERGED instead of failing here.
    # The same members-pin idiom Telemetry::RequestSent uses against Request.
    it "records every Context constructor input, so a new kwarg cannot be dropped in silence" do
      # Written under a NAMED pipeline, because an unnamed one writes no key for
      # its name, and the header spells `pipeline_name` as `context_pipeline`,
      # the flag's word.
      named_io = StringIO.new
      named = Lain::CLI::ContextPipeline.named("default").context(model: "claude-opus-4-8", max_tokens: 1024)
      write_session(into: Lain::Journal.new(io: named_io), under: named)
      header = journal_records(named_io).find { |record| record["type"] == "session" }
      # `ts` is the Journal's own stamp on every record, not part of the header,
      # and `compact_schedule` is the run's compaction, not the Context's.
      recorded = (header.keys - %w[type format compact_schedule context_class tools reminders ts])
                 .map { |key| key == "context_pipeline" ? "pipeline_name" : key }
      # `pipeline` is a live CODE collaborator (a Combinator or ->(workspace)
      # provider), not serializable data -- like a `self.pipeline`-
      # overriding subclass, it is reconstructed by the Loader's injectable
      # context_factory beside the recorded `context_class`, never journaled, so
      # it is excluded from the constructor inputs the header must carry.
      expected = Lain::Context.instance_method(:initialize).parameters.map(&:last) - %i[pipeline]
      expect(recorded.map(&:to_sym)).to match_array(expected)
    end
  end

  describe "round trip" do
    before { write_session }

    it "rebuilds the timeline to the recorded head digest" do
      expect(load_session.timeline.head_digest).to eq(agent.timeline.head_digest)
    end

    it "rebuilds the baseline to the requests the provider actually received, in order" do
      baseline = load_session.baseline
      expect(baseline.map(&:digest)).to eq(provider.requests.map(&:digest))
      expect(baseline).to eq(provider.requests)
    end

    it "prices the ledger_index to the same totals as one built from the live journal directly" do
      recording = load_session
      loaded = Lain::Ledger.new(index: recording.ledger_index)
      direct = Lain::Ledger.from_journal(journal_io.string.each_line)
      expect(loaded.usage(recording.timeline)).to eq(direct.usage(agent.timeline))
      expect(loaded.cost(recording.timeline)).to eq(direct.cost(agent.timeline))
    end

    it "rebuilds a toolset that answers the recorded schema, which is all #render consumes" do
      expect(load_session.toolset.to_schema).to eq(toolset.to_schema)
    end

    # Pure data, never constantized: it lets a consumer (Bench::Variance) tell
    # a harness leak from a custom-pipeline recording reloaded as the default.
    it "surfaces the header's recorded context_class on the Recording" do
      expect(load_session.context_class).to eq("Lain::Context")
    end

    it "loads from a file path the same as from lines" do
      Tempfile.create("session") do |file|
        file.write(journal_io.string)
        file.flush
        expect(described_class.load(file.path).timeline.head_digest).to eq(agent.timeline.head_digest)
      end
    end

    it "skips foreign lines: a shared fd's non-JSON and non-object bytes are somebody else's records" do
      lines = ["not json at all\n", "[1, 2, 3]\n"] + journal_io.string.each_line.to_a
      expect(described_class.load(lines).timeline.head_digest).to eq(agent.timeline.head_digest)
    end
  end

  # A Recording holds a Store (via its Timeline), so like Timeline itself it
  # cannot clear the Ractor.shareable? bar whole; the frozen shell plus
  # shareable members is the same guarantee Timeline gives.
  #
  # Written under a NAMED --compact-strategy, deliberately NOT the shared
  # "round trip" before-hook's own strategy-less session: a nil `compaction`
  # is trivially frozen and would leave this example blind to exactly the
  # member it exists to catch -- {Loader#recording} hands it a plain String
  # off `JSON.parse`, which is unfrozen until this class says otherwise.
  describe "Ractor-shareability" do
    before { write_session(compaction: { "compact_strategy" => "elide", "compact_schedule" => "idle" }) }

    it "is a frozen Recording whose non-Timeline members are Ractor-shareable" do
      recording = load_session
      expect(recording.schedule).to eq("idle")
      expect(recording).to be_frozen
      expect(recording.timeline).to be_frozen
      %i[context context_class toolset workspace baseline ledger_index degraded mode open messages compaction schedule
         compaction_tally]
        .each do |member|
        expect(recording.public_send(member)).to be_deeply_frozen
      end
    end
  end

  describe "identity replay from disk" do
    it "re-renders byte-identical requests under the rebuilt context" do
      write_session
      recording = load_session
      expect(recording.dry_replay.diff(recording.context)).to be_identical
    end

    context "with workspace reminders in effect at record time" do
      let(:workspace) { Lain::Workspace.empty.with("finish the audit") }

      it "round-trips the reminders and still replays to byte identity" do
        write_session
        recording = load_session
        expect(recording.workspace.reminders).to eq(["finish the audit"])
        expect(recording.dry_replay.diff(recording.context)).to be_identical
      end
    end
  end

  describe "tampering" do
    it "raises Session::Corrupt naming the recorded digest when a turn's content was edited under it" do
      write_session
      records = parsed_records
      forged = records.reverse.find { |record| record["type"] == "turn" }
      forged["content"] = [{ "type" => "text", "text" => "forged" }]

      expect { described_class.load(records) }
        .to raise_error(described_class::Corrupt, /#{Regexp.escape(forged.fetch("digest"))}/)
    end

    it "raises Session::Corrupt at load time when a request_sent payload was edited under its digest" do
      write_session
      records = parsed_records
      forged = records.reverse.find { |record| record["type"] == "request_sent" }
      forged["payload"] = forged["payload"].merge("max_tokens" => 999_999)

      expect { described_class.load(records) }
        .to raise_error(described_class::Corrupt, /#{Regexp.escape(forged.fetch("digest"))}/)
    end
  end

  describe "header multiplicity" do
    it "raises Session::Corrupt when two session headers claim one journal" do
      write_session
      records = parsed_records
      duplicate = records.find { |record| record["type"] == "session" }

      expect { described_class.load(records + [duplicate]) }
        .to raise_error(described_class::Corrupt, /header/)
    end
  end

  describe "a Context-subclass session (beyond the default pipeline)" do
    let(:context) do
      stub_const("PruningContext", Class.new(Lain::Context) do
        def self.pipeline(_workspace) = Lain::Context::Prune.new(keep_last: 1)
      end)
      PruningContext.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
    end

    it "records the class as data and round-trips the run, but loads as base Context, forfeiting identity" do
      write_session
      header = parsed_records.find { |record| record["type"] == "session" }
      expect(header.fetch("context_class")).to eq("PruningContext")

      recording = load_session
      expect(recording.timeline.head_digest).to eq(agent.timeline.head_digest)
      expect(recording.baseline.map(&:digest)).to eq(provider.requests.map(&:digest))
      expect(recording.context).to be_an_instance_of(Lain::Context)
      expect(recording.context_class).to eq("PruningContext")
      expect(recording.dry_replay.diff(recording.context)).not_to be_identical
    end
  end

  describe "degraded capabilities" do
    it "folds capability_degraded records into the Recording's degraded set" do
      write_session
      journal << Lain::Telemetry::CapabilityDegraded.new(
        capability: :prompt_caching, requirer: "CacheBreakpoints", provider: "Provider::Mock"
      )
      expect(load_session.degraded).to include(:prompt_caching)
    end
  end

  # A run's mode is the same kind of fact its degraded set is -- what makes
  # two recordings comparable at all -- so it loads off the same journal and
  # rides on the Recording beside it.
  describe "the recorded mode" do
    it "folds mode_switch records into the Recording's mode trajectory" do
      write_session
      journal << Lain::Telemetry::ModeSwitch.new(from_scope: :checkout, to_scope: :checkout, from_approval: :ask,
                                                 to_approval: :bypass, from_layers: [], to_layers: [], surface: "tty")
      expect(load_session.mode.to_s).to eq("checkout/ask → checkout/bypass")
    end

    it "answers unrecorded for a session that journaled no mode switch" do
      write_session
      expect(load_session.mode).to eq(Lain::Compare::Mode::UNRECORDED)
    end
  end

  # A request_sent with no following turn_usage is how a failed call reads
  # (JournalRequests records BEFORE dispatch). The attempt is part of the
  # record, so loading must succeed; a consumer detects the failure because the
  # baseline outnumbers the DAG's assistant turns -- which is exactly the 1:1
  # guard DryReplay raises on, so a replay of a failed session is loud, not wrong.
  describe "a failed call" do
    it "still loads, and the surplus attempt surfaces through DryReplay's guard" do
      write_session
      attempt = provider.requests.last
      journal << Lain::Telemetry::RequestSent.new(digest: attempt.digest, payload: attempt.cache_payload,
                                                  stream: attempt.stream, extra: attempt.extra)

      recording = load_session
      expect(recording.baseline.size).to eq(3)
      expect(recording.timeline.to_a.count { |turn| turn.role == "assistant" }).to eq(2)
      expect { recording.dry_replay }.to raise_error(ArgumentError, /baseline/)
    end
  end

  describe "a journal with no session header" do
    it "raises Session::Corrupt rather than fabricating a context" do
      expect { described_class.load([]) }.to raise_error(described_class::Corrupt, /header/)
    end
  end

  # The door `bench variance` and a resume both come through, on a real
  # journal: a record damaged in a key the rebuild needs must refuse as
  # Corrupt, which is what these callers rescue, rather than as the KeyError
  # (absent key) or the bare Lain::Error out of Event (null role) that reach an
  # operator as a backtrace with neither the file nor the record on it.
  describe "a turn record damaged in a key the rebuild needs" do
    def turn_records
      write_session
      parsed_records.map { |record| record["type"] == "turn" ? yield(record) : record }
    end

    it "refuses as Corrupt naming the record and an absent role" do
      records = turn_records { |record| record.except("role") }

      expect { described_class.load(records) }
        .to raise_error(described_class::Corrupt, /turn record 0 has no role key/)
    end

    it "refuses as Corrupt naming the record and a null role" do
      records = turn_records { |record| record.merge("role" => nil) }

      expect { described_class.load(records) }
        .to raise_error(described_class::Corrupt) { |error|
          expect(error.message).to include("turn record 0", "role")
        }
    end
  end

  # The one place both replays read a record they cannot trust. Exercised
  # directly because the two behaviours that matter are invisible from the
  # happy path: what it refuses, and that it builds no label unless it does.
  describe described_class::RequiredKeys do
    let(:record) { { "digest" => "blake3:abc", "role" => nil } }

    # The refusal's sentence, for comparing two damage shapes that must read
    # alike. nil when nothing refused, which is what keeps the comparison from
    # passing on two silences.
    def refusal(from, key)
      described_class.read_filled(from, key) { "turn record 0" }
      nil
    rescue Lain::Bench::Session::Corrupt => e
      e.message
    end

    describe ".read" do
      it "hands back the value for a key the record carries" do
        expect(described_class.read(record, "digest") { "turn record 0" }).to eq("blake3:abc")
      end

      it "never builds the label for a key the record carries" do
        built = []

        described_class.read(record, "digest") { built << :label }

        expect(built).to be_empty
      end

      # Hash semantics, kept deliberately: a key that is there IS there. The
      # fields whose null nothing downstream can catch go through
      # {.read_filled} instead, and every other field's null announces itself
      # as a content-address mismatch.
      it "treats a key present with a null value as present" do
        expect(described_class.read(record, "role") { "turn record 0" }).to be_nil
      end

      it "refuses an absent key as Corrupt, naming the record and the key" do
        expect { described_class.read(record, "content") { "turn record 0 (user)" } }
          .to raise_error(Lain::Bench::Session::Corrupt) { |error|
            expect(error).to be_a(Lain::Error)
            expect(error.message).to start_with("turn record 0 (user) has no content key")
          }
      end
    end

    describe ".read_filled" do
      it "hands back the value for a key the record carries" do
        expect(described_class.read_filled(record, "digest") { "turn record 0" }).to eq("blake3:abc")
      end

      it "refuses a null value in the same sentence an absent key gets" do
        expect(refusal(record, "role"))
          .to eq(refusal({}, "role")).and(start_with("turn record 0 has no role key"))
      end

      # Its two callers read `role` and `kind`, each a name out of a closed
      # enum, so a `false` there is damage exactly as a null is -- and it
      # reaches the same validator, in the same currency no door rescues.
      it "refuses false in that same sentence too" do
        expect(refusal({ "role" => false }, "role")).to eq(refusal({}, "role"))
      end
    end

    describe ".labelled" do
      it "names the record by noun and index" do
        expect(described_class.labelled("turn", 3, "assistant")).to eq("turn record 3 (assistant)")
      end

      # A record whose naming field is itself damaged gets no parenthetical:
      # "turn record 0 (unnamed role) has no role key" reads as the tool
      # arguing with itself, and the index alone already says which record.
      it "drops the parenthetical for a field the record cannot name" do
        expect(described_class.labelled("rewound", 0)).to eq("rewound record 0")
      end

      it "drops it for a field damaged into a falsey value too, rather than reading '(false)'" do
        expect(described_class.labelled("turn", 0, false)).to eq("turn record 0")
      end

      it "clips a field long enough to bury the sentence that carries it" do
        labelled = described_class.labelled("message", 0, "z" * 20_000)

        expect(labelled.length).to be < 120
        expect(labelled).to start_with("message record 0 (zzz")
      end
    end

    # What a refusal QUOTES, as against what it names the record by. The two
    # bounds cannot be one number: a digest is longer than the label's cap and
    # is the token a reader takes back to the file, so it must never be the
    # thing that got clipped.
    describe ".shown" do
      it "carries a digest through whole" do
        digest = "blake3:#{"ab" * 32}"

        expect(described_class.shown(digest)).to eq(digest.inspect)
      end

      it "clips a value the damage filled with 20,000 characters, marking that it did" do
        shown = described_class.shown("z" * 20_000)

        expect(shown.length).to be < 200
        expect(shown).to end_with("...")
      end

      it "clips a collection no reader could scan, rather than quoting all of it" do
        expect(described_class.shown(Array.new(2_000) { |index| index }).length).to be < 200
      end
    end
  end
end
