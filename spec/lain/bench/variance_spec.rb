# frozen_string_literal: true

require "stringio"

require "lain/bench/variance"

require "lain/agent"
require "lain/bench/session"
require "lain/capability/guard"
require "lain/context"
require "lain/context/prune"
require "lain/event"
require "lain/journal"
require "lain/ledger"
require "lain/middleware"
require "lain/provider/mock"
require "lain/response"
require "lain/tool"
require "lain/toolset"
require "lain/usage"
require "lain/workspace"

# Variance is the experiment engine (design decision D3): n mock- or
# live-recorded runs of ONE task, reported along three axes. Determinism --
# each recording must dry-replay to byte identity under its own Context, the
# harness-determinism claim. Divergence -- where the recordings' actually-sent
# bytes first part ways from the reference, named to the model call and the
# cache_payload field. Distribution -- Compare's token/cost table, because a
# single pair of runs is noise. The report is a returned String, never stdout.
RSpec.describe Lain::Bench::Variance do
  echo_tool = Class.new(Lain::Tool) do
    def name = "echo"
    def description = "Echoes its input back."
    def input_schema = { type: :object, properties: { text: { type: :string } }, required: [:text] }

    def perform(input, _context) = Lain::Tool::Result.ok(input.fetch("text"))
  end

  let(:toolset) { Lain::Toolset.new([echo_tool.new]) }
  # The mock responses carry a priceable model ("sonnet" family) so the
  # default PriceBook prices the ledger without needing a fallback.
  let(:context) { Lain::Context.new(model: "claude-sonnet-4-6", max_tokens: 1024, system: "be terse") }
  let(:workspace) { Lain::Workspace.empty }
  let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }

  def tool_response(id, text)
    Lain::Response.new(
      content: [{ "type" => "tool_use", "id" => id, "name" => "echo", "input" => { "text" => text } }],
      stop_reason: :tool_use, usage: usage, model: "claude-sonnet-4-6"
    )
  end

  def text_response(text)
    Lain::Response.new(content: [{ "type" => "text", "text" => text }],
                       stop_reason: :end_turn, usage: usage, model: "claude-sonnet-4-6")
  end

  # One mock-recorded run of the task, round-tripped through Session so the
  # Recording under test is exactly what B4's driver will hold.
  def record(responses, degrade: nil)
    Lain::Bench::Session.load(session_bytes(responses, degrade: degrade).each_line)
  end

  def session_bytes(responses, degrade: nil)
    io = StringIO.new
    journal = Lain::Journal.new(io: io)
    run_and_write(journal, responses)
    degrade!(journal, degrade)
    io.string
  end

  def run_and_write(journal, responses)
    agent = Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: responses),
                            toolset: toolset, context: context, workspace: workspace,
                            journal: journal, model_middleware: journaling_stack(journal))
    agent.ask("please echo hi")
    Lain::Bench::Session.write(journal, timeline: agent.timeline, context: context,
                                        toolset: toolset, workspace: workspace)
  end

  def journaling_stack(journal)
    Lain::Middleware::Stack.new([Lain::Middleware::JournalRequests.new(journal: journal)])
  end

  def degrade!(journal, capability)
    return if capability.nil?

    journal << Lain::Event::CapabilityDegraded.new(capability: capability, requirer: "Spec",
                                                   provider: "Provider::Mock")
  end

  let(:reference) { record([tool_response("tu_1", "hi"), text_response("done")]) }
  # Same first model call, so the first divergence lands at model call 2: the
  # differing tool_use input (and its echoed result) changes its messages.
  let(:diverging) do
    record([tool_response("tu_1", "hi there, at considerably greater length"), text_response("done, and then some")])
  end
  # One extra tool round trip: three model calls whose first two render the
  # same bytes as the reference's two.
  let(:extended) { record([tool_response("tu_1", "hi"), tool_response("tu_2", "hi"), text_response("done")]) }

  describe "the headline report" do
    let(:variance) { described_class.new(recordings: [reference, diverging, extended]) }
    let(:report) { variance.report }

    it "returns a String and writes nothing to stdout or stderr" do
      expect { variance.report }.not_to output.to_stdout
      expect { variance.report }.not_to output.to_stderr
      expect(report).to be_a(String)
    end

    it "marks each recording's self-replay byte-identity in the determinism section" do
      expect(report).to include("1: byte-identical", "2: byte-identical", "3: byte-identical")
    end

    # 1-based "model call k" language throughout, translated at the formatting
    # boundary from StepDiff's 0-based index, so the experimenter never does
    # off-by-one arithmetic against the 1-based recording ordinals.
    it "names, for the diverging recording, the first differing model call and the changed cache_payload fields" do
      expect(report).to include("2: first divergence at model call 2 (messages)")
    end

    it "reports the extended recording's call-count difference and compares over the shorter length" do
      expect(report).to include("3: 3 model calls vs reference 2; cache-identical over the shared 2 model calls")
    end

    it "includes Compare's distribution table with nonzero token and cost figures" do
      cost = Lain::Ledger.new(index: reference.ledger_index).cost(reference.timeline)
      expect(cost).to be > 0
      expect(report).to include("total tokens", "cost (USD)", format("%.6f", cost))
    end
  end

  describe "a recording that matches the reference exactly" do
    it "is reported cache-identical to the reference" do
      twin = record([tool_response("tu_1", "hi"), text_response("done")])
      report = described_class.new(recordings: [reference, twin]).report
      expect(report).to include("2: cache-identical to reference")
    end
  end

  # A run recorded under a Context subclass loads as base Context (Session's
  # stated limit), so its self-replay legitimately diverges -- the determinism
  # section must say so, named to the model call and field, and must blame the
  # custom-pipeline reload rather than overclaiming a harness leak.
  describe "a recording whose self-replay diverges" do
    let(:context) do
      stub_const("PruningContext", Class.new(Lain::Context) do
        def self.pipeline(_workspace) = Lain::Context::Prune.new(keep_last: 1)
      end)
      PruningContext.new(model: "claude-sonnet-4-6", max_tokens: 1024, system: "be terse")
    end

    it "is marked DIVERGED, naming the model call, the fields, and the custom-pipeline recording" do
      pruned = record([tool_response("tu_1", "hi"), text_response("done")])
      report = described_class.new(recordings: [pruned, pruned]).report
      expect(report).to match(/1: DIVERGED \(model call \d+: .*messages.*\)/)
      expect(report).to include("recorded under PruningContext; reload renders the default pipeline")
    end
  end

  # A recording that cannot replay must refuse when the experiment is
  # constructed, not raise halfway through building the report String.
  describe "a degenerate recording (an orphan request_sent with no turn)" do
    it "raises at construction, before any report text exists" do
      bytes = session_bytes([tool_response("tu_1", "hi"), text_response("done")])
      orphan = bytes.each_line.find { |line| line.include?("request_sent") }
      broken = Lain::Bench::Session.load((bytes + orphan).each_line)
      expect { described_class.new(recordings: [reference, broken]) }
        .to raise_error(ArgumentError, /baseline/)
    end
  end

  describe "recordings reloaded from the same bytes" do
    it "yields a byte-identical report from a fresh Variance each time" do
      bytes = [session_bytes([tool_response("tu_1", "hi"), text_response("done")]),
               session_bytes([tool_response("tu_1", "hi there, longer"), text_response("done")])]
      reports = Array.new(2) do
        recordings = bytes.map { |ndjson| Lain::Bench::Session.load(ndjson.each_line) }
        described_class.new(recordings: recordings).report
      end
      expect(reports.first).to eq(reports.last)
    end
  end

  describe "refusing apples-to-oranges" do
    it "raises Capability::Guard::Mismatch when the recordings' degraded sets differ" do
      degraded = record([tool_response("tu_1", "hi"), text_response("done")], degrade: :prompt_caching)
      expect { described_class.new(recordings: [reference, degraded]) }
        .to raise_error(Lain::Capability::Guard::Mismatch)
    end
  end

  describe "n >= 2" do
    it "raises ArgumentError on a single recording" do
      expect { described_class.new(recordings: [reference]) }
        .to raise_error(ArgumentError, /at least two/)
    end
  end
end
