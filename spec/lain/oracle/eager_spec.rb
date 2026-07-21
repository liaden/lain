# frozen_string_literal: true

require "stringio"

# PC-7: eager unit summaries on their own fibers. {Oracle::Eager} holds tool-result
# summaries keyed by the result's SOURCE DIGEST (an immutable source can never go
# stale) and fires each on its own transient task, so a slow local oracle never
# blocks the turn that produced the source. {Effect::Handler::Summarizing} is the
# decorator that observes a large tool result and fires its summary while
# interpreting no effect itself. Journaling rides the existing {Telemetry::
# OracleAnswer} path, so a {Oracle::Recorded} tier replays a summary with no live
# call -- the same record/replay discipline the rest of the oracle tier speaks.
RSpec.describe Lain::Oracle::Eager do
  # A tiny summarizer schema + definition, reused across the examples.
  let(:schema) do
    Class.new(Lain::Tool::Input) do
      field :summary, :string, required: true, description: "a terse summary"
    end
  end

  let(:definition) do
    Lain::Oracle::Definition.new(template: %(Summarize:\n<%= render("source") %>), schema:, tier: :model)
  end

  # An oracle whose Promise stays pending until the test resolves it, so a spec
  # can watch the turn return BEFORE the summary does. Counts its calls.
  let(:pending_oracle_class) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = 0
        @promise = Lain::Promise.new
      end

      def ask(_inputs)
        @calls += 1
        @promise
      end

      def resolve(value) = @promise.resolve(value)
    end
  end

  let(:pending_oracle) { pending_oracle_class.new }

  # A synchronous local oracle: a pure predicate resolved through the real schema,
  # so its Promise is pre-resolved and its fire task completes without parking.
  def heuristic_oracle(summary: "a terse summary")
    Lain::Oracle::Heuristic.new(definition:, predicate: ->(_inputs) { { "summary" => summary } })
  end

  # ---- Scenario: firing never blocks the turn -------------------------------

  describe "#fire (spawns and returns at once)" do
    it "returns before the summary resolves and holds nothing until it does" do
      Sync do
        eager = described_class.new(oracle: pending_oracle)
        eager.fire("src-1", "a large tool result")

        expect(pending_oracle.calls).to eq(1)          # the fire happened
        expect(eager.held("src-1")).to be_nil          # but the summary is still in flight
      end
    end

    it "holds the completed summary once its task resolves" do
      Sync do
        eager = described_class.new(oracle: heuristic_oracle(summary: "compressed"))
        eager.fire("src-1", "a large tool result").wait

        expect(eager.held("src-1").summary).to eq("compressed")
      end
    end

    it "fires only once for a repeated digest -- a cache hit, not a second call" do
      Sync do
        eager = described_class.new(oracle: pending_oracle)
        eager.fire("src-1", "a large tool result")
        eager.fire("src-1", "a large tool result")

        expect(pending_oracle.calls).to eq(1)
      end
    end
  end

  describe "#held" do
    it "answers nil for a digest never fired, without blocking" do
      eager = described_class.new(oracle: pending_oracle)

      expect(eager.held("never")).to be_nil
    end
  end

  # ---- Precondition: fire needs an ambient reactor to spawn into -------------

  describe "#fire outside a reactor" do
    it "is a graceful no-op -- no spawn, no hold, returns nil (an absent summary is a miss)" do
      eager = described_class.new(oracle: pending_oracle)

      expect(eager.fire("src-1", "a large tool result")).to be_nil
      expect(pending_oracle.calls).to eq(0)
      expect(eager.held("src-1")).to be_nil
    end

    it "does not mark the digest fired, so a later in-reactor fire still runs" do
      eager = described_class.new(oracle: heuristic_oracle(summary: "compressed"))

      eager.fire("src-1", "text") # no reactor -> no-op, digest NOT consumed
      Sync { eager.fire("src-1", "text").wait }

      expect(eager.held("src-1").summary).to eq("compressed")
    end

    it "degrades to a miss when its reactor is too short-lived to resolve it (a reap, not an error)" do
      eager = described_class.new(oracle: pending_oracle) # never resolves

      # A direct short-lived Sync exits immediately; the transient fire it
      # parents is reaped before the (pending) oracle resolves.
      expect { Sync { eager.fire("src-1", "text") } }.not_to raise_error
      expect(eager.held("src-1")).to be_nil
    end
  end

  # ---- Scenario: a failed fire is contained ---------------------------------

  describe "containment of a failed fire" do
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io) }

    # A tier that raises the moment it is asked, wrapped in the SAME journaling
    # decorator a live tier uses -- so we prove the failure both holds nothing
    # and never reaches the journal write.
    let(:raising_tier) do
      Class.new do
        def ask(_inputs) = raise "oracle unavailable"
        def model = nil
        def usage = {}
      end.new
    end

    let(:oracle) { Lain::Oracle::Recorded::Journaling.new(inner: raising_tier, definition:, journal:) }

    it "holds nothing and journals nothing when the oracle raises" do
      Sync do
        eager = described_class.new(oracle:)
        eager.fire("src-1", "a large tool result").wait

        expect(eager.held("src-1")).to be_nil
        expect(journal_io.string).to be_empty
      end
    end

    it "lets a stop cancel an in-flight fire without surfacing at the reactor" do
      eager = described_class.new(oracle: pending_oracle)

      Sync do |task|
        inner = task.async do |scope|
          eager.fire("src-1", "a large tool result") # transient grandchild parks on the pending oracle
          scope.sleep(60)
        end
        inner.stop # structured cancellation of the subtree
      end

      expect(eager.held("src-1")).to be_nil
    end
  end

  # ---- Scenario: summaries key by source digest and replay ------------------

  describe "journaling and replay via the OracleAnswer path" do
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io) }
    let(:text) { "the source text a tool returned, long enough to be worth summarizing" }
    let(:digest) { Lain::Canonical.digest(text) }

    def response_with(json)
      Lain::Response.new(content: [{ "type" => "text", "text" => json }], stop_reason: :end_turn,
                         usage: Lain::Usage.new(input_tokens: 8, output_tokens: 4))
    end

    it "replays a fired summary from the journal with no live call" do
      provider = Lain::Provider::Mock.new(responses: [response_with(%({"summary":"a fox"}))])
      model_tier = Lain::Oracle::Model.new(definition:, provider:, model: "local-summarizer")
      journaling = Lain::Oracle::Recorded::Journaling.new(inner: model_tier, definition:, journal:)

      Sync { described_class.new(oracle: journaling).fire(digest, text).wait }
      expect(provider.call_count).to eq(1)

      recorded_tier = Lain::Oracle::Recorded.from_journal(journal_io.string.each_line, definition:)
      replay = described_class.new(oracle: recorded_tier)
      Sync { replay.fire(digest, text).wait }

      expect(replay.held(digest).summary).to eq("a fox")
      expect(provider.call_count).to eq(1) # the replay added no further provider round trip
    end
  end

  # ---- Handler::Summarizing: the decorator that observes and fires ----------

  describe Lain::Effect::Handler::Summarizing do
    let(:big) { "x" * 100 }
    let(:small) { "tiny" }
    let(:digest) { Lain::Canonical.digest(big) }
    let(:eager) { Lain::Oracle::Eager.new(oracle: pending_oracle) }

    def with_inner(result)
      Lain::Effect::Handler::Mock.new(default: result)
    end

    def tool_call(id: "tu_1", name: "read_file", input: {})
      Lain::Effect::ToolCall.new(tool_use_id: id, name:, input:)
    end

    it "returns the tool result unchanged while firing the summary" do
      Sync do
        handler = described_class.new(eager:, threshold_bytes: 8, inner: with_inner(big))
        result = handler.call(tool_call, nil)

        expect(result).to be_ok
        expect(result.content).to eq(big) # a summary is a side value, never a rewrite
        expect(pending_oracle.calls).to eq(1)
        expect(eager.held(digest)).to be_nil
      end
    end

    it "fires once for repeated result content, keyed by its source digest" do
      Sync do
        handler = described_class.new(eager:, threshold_bytes: 8, inner: with_inner(big))
        handler.call(tool_call(id: "tu_1"), nil)
        handler.call(tool_call(id: "tu_2"), nil) # same content, different call id

        expect(pending_oracle.calls).to eq(1)
      end
    end

    it "completes and returns the result unchanged when called with NO surrounding reactor" do
      # The 5-0.2 invariant: the handler chain stays runnable as plain synchronous
      # Ruby. With no ambient reactor the fire degrades to a miss; the dispatch
      # still returns the tool result untouched.
      handler = described_class.new(eager:, threshold_bytes: 8, inner: with_inner(big))
      result = handler.call(tool_call, nil)

      expect(result).to be_ok
      expect(result.content).to eq(big)
      expect(pending_oracle.calls).to eq(0)
      expect(eager.held(digest)).to be_nil
    end

    it "leaves a below-threshold result alone" do
      Sync do
        handler = described_class.new(eager:, threshold_bytes: 1024, inner: with_inner(small))
        handler.call(tool_call, nil)

        expect(pending_oracle.calls).to eq(0)
      end
    end

    it "keys firing on the byte threshold: at-threshold never fires, one byte over fires" do
      Sync do
        at = Lain::Oracle::Eager.new(oracle: (at_oracle = pending_oracle_class.new))
        over = Lain::Oracle::Eager.new(oracle: (over_oracle = pending_oracle_class.new))
        described_class.new(eager: at, threshold_bytes: 10, inner: with_inner("x" * 10)).call(tool_call, nil)
        described_class.new(eager: over, threshold_bytes: 10, inner: with_inner("x" * 11)).call(tool_call, nil)

        expect(at_oracle.calls).to eq(0)
        expect(over_oracle.calls).to eq(1)
      end
    end

    it "keys the threshold on bytesize, not character length (multibyte)" do
      Sync do
        # 4 * "あ" == 12 bytes but 4 characters; a length check would miss it.
        multibyte = Lain::Oracle::Eager.new(oracle: (o = pending_oracle_class.new))
        described_class.new(eager: multibyte, threshold_bytes: 10, inner: with_inner("あ" * 4)).call(tool_call, nil)

        expect(o.calls).to eq(1)
      end
    end

    it "does not summarize (or crash on) structured Array content over the byte count" do
      Sync do
        blocks = [{ "type" => "text", "text" => "x" * 5000 }]
        handler = described_class.new(eager:, threshold_bytes: 10, inner: with_inner(blocks))
        result = handler.call(tool_call, nil)

        expect(result.content).to eq(blocks)
        expect(pending_oracle.calls).to eq(0)
      end
    end

    it "does not summarize a failed tool result" do
      Sync do
        errored = Lain::Effect::Handler::Mock.new(default: Lain::Tool::Result.error(big))
        handler = described_class.new(eager:, threshold_bytes: 8, inner: errored)
        handler.call(tool_call, nil)

        expect(pending_oracle.calls).to eq(0)
      end
    end

    it "does not break the dispatch when its fire will fail" do
      raising = Class.new do
        def ask(_inputs) = raise "oracle unavailable"
        def model = nil
        def usage = {}
      end.new

      Sync do
        handler = described_class.new(eager: Lain::Oracle::Eager.new(oracle: raising),
                                      threshold_bytes: 8, inner: with_inner(big))
        result = handler.call(tool_call, nil)

        expect(result.content).to eq(big)
      end
    end
  end
end
