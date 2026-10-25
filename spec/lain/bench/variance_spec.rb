# frozen_string_literal: true

require "stringio"
require "tmpdir"

# Variance is the experiment engine: n mock- or live-recorded runs of ONE
# task, reported along three axes. Determinism -- each recording must
# dry-replay to byte identity under its own Context, the harness-determinism
# claim. Divergence -- where the recordings' actually-sent bytes first part
# ways from the reference, named to the model call and the cache_payload
# field. Distribution -- Compare's token/cost table, because a single pair of
# runs is noise. The report is a returned String, never stdout.
RSpec.describe Lain::Bench::Variance do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  # The mock responses carry a priceable model ("sonnet" family) so the
  # default PriceBook prices the ledger without needing a fallback.
  let(:context) { Lain::Context.new(model: "claude-sonnet-4-6", max_tokens: 1024, system: "be terse") }
  let(:workspace) { Lain::Workspace.empty }
  let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }
  let(:reference) { record([tool_response("tu_1", "hi"), text_response("done")]) }
  # Same first model call, so the first divergence lands at model call 2: the
  # differing tool_use input (and its echoed result) changes its messages.
  let(:diverging) do
    record([tool_response("tu_1", "hi there, at considerably greater length"), text_response("done, and then some")])
  end
  # One extra tool round trip: three model calls whose first two render the
  # same bytes as the reference's two.
  let(:extended) { record([tool_response("tu_1", "hi"), tool_response("tu_2", "hi"), text_response("done")]) }

  # Narrowed over the shared builders: every response here is an echo call
  # carrying the priceable model and usage, so the call sites stay terse.
  def tool_response(id, text, model: "claude-sonnet-4-6")
    super([id, "echo", { "text" => text }], usage:, model:)
  end

  def text_response(text, model: "claude-sonnet-4-6")
    super(text, usage:, model:)
  end

  # One mock-recorded run of the task, round-tripped through Session so the
  # Recording under test is exactly what the driver will hold.
  def record(responses, degrade: nil, flips: [], under: context, compact_strategy: nil, schedule: nil, arms: nil,
             compact: nil, run_arms: nil)
    bytes = session_bytes(responses, degrade:, flips:, under:, compact_strategy:)
    extra = { "compact_schedule" => schedule, "arms" => arms, "compact" => compact }.compact
    bytes += "#{JSON.generate("type" => "run_arms", "arms" => run_arms)}\n" unless run_arms.nil?
    Lain::Bench::Session.load(with_header(bytes, extra).each_line)
  end

  def with_header(bytes, extra)
    return bytes if extra.empty?

    bytes.each_line.map do |line|
      record = JSON.parse(line)
      record.key?("context_class") ? "#{JSON.generate(record.merge(extra))}\n" : line
    end.join
  end

  def session_bytes(responses, degrade: nil, flips: [], under: context, compact_strategy: nil)
    io = StringIO.new
    journal = Lain::Journal.new(io:)
    flip!(journal, flips)
    run_and_write(journal, responses, under, compact_strategy:)
    degrade!(journal, degrade)
    io.string
  end

  # `/mode` flips land on the run's own journal as they happen, which is the
  # only evidence a recording carries of the mode it ran in. Each flip names
  # the approval on either side; the scope is the checkout throughout.
  def flip!(journal, flips)
    flips.each do |from, to|
      journal << Lain::Telemetry::ModeSwitch.new(from_scope: :checkout, to_scope: :checkout, from_approval: from,
                                                 to_approval: to, from_layers: [], to_layers: [], surface: "tty")
    end
  end

  def run_and_write(journal, responses, context, compact_strategy: nil)
    agent, = record_journaled_run(responses, journal:, toolset:,
                                             context:, workspace:)
    compaction = compact_strategy.nil? ? {} : { "compact_strategy" => compact_strategy, "compact_schedule" => "turn" }
    Lain::SessionRecord::Scribe.new(journal:, context:, toolset:, workspace:, compaction:, writer: CoreGraph::NO_WRITER)
                               .catch_up(agent.timeline).close(reason: :exit)
  end

  def named(pipeline)
    Lain::CLI::ContextPipeline.named(pipeline).context(model: "claude-sonnet-4-6", max_tokens: 1024, system: "be terse")
  end

  def degrade!(journal, capability)
    return if capability.nil?

    journal << Lain::Telemetry::CapabilityDegraded.new(capability:, requirer: "Spec",
                                                       provider: "Provider::Mock")
  end

  describe "the headline report" do
    let(:variance) { described_class.new(recordings: [reference, diverging, extended]) }
    let(:report) { variance.report }

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

  describe "recordings carrying compaction records" do
    def with_records(bytes, *records)
      Lain::Bench::Session.load((bytes.each_line.to_a + records.map { |r| "#{JSON.generate(r)}\n" }).each)
    end

    it "reports the recordings' summary misses and unapplied cuts in Compare's table" do
      bytes = session_bytes([text_response("done")])
      busy = with_records(bytes, { "type" => "compaction_decision", "summary_misses" => 7 },
                          { "type" => "compaction_prepared" })
      report = described_class.new(recordings: [busy, with_records(bytes)]).report
      expect(report.lines.find { |l| l.start_with?("summary misses") }).to match(/summary misses\s+2\s+3\.5\s+/)
      expect(report.lines.find { |l| l.start_with?("prepared unapplied") }).to match(/\s0\.5\s/)
    end
  end

  # A local model has usage and no price. The price book refuses to guess, and
  # that refusal must not take the whole experiment down with it -- determinism
  # and divergence included, neither of which ever needs a dollar figure.
  describe "recordings of a model the price book cannot price" do
    let(:local) do
      Array.new(2) do
        record([tool_response("tu_1", "hi", model: "qwen3:4b"), text_response("done", model: "qwen3:4b")])
      end
    end
    let(:report) { described_class.new(recordings: local).report }

    it "reports every section, total tokens included" do
      expect(report).to include("1: byte-identical", "2: cache-identical to reference", "total tokens")
    end

    it "reads the cost row as not priced, with the ledger's reason, never 0.000000" do
      expect(report).to include(%(cost (USD): not priced — no price for model "qwen3:4b"))
      # The compaction cost delta is the last column and legitimately reads 0.000000 here.
      other_columns = report.lines.reject { |line| line.start_with?("compaction cost delta") }
                            .map { |line| line.sub(/\s+0\.000000\s*\z/, "") }
      expect(other_columns.join).not_to include("0.000000")
    end

    it "is reported by `lain bench variance` rather than refused" do
      Dir.mktmpdir do |dir|
        2.times do |index|
          File.write(File.join(dir, "#{index}.ndjson"),
                     session_bytes([tool_response("tu_1", "hi", model: "qwen3:4b"),
                                    text_response("done", model: "qwen3:4b")]))
        end
        expect(Lain::Bench::CLI.new.variance_report([dir])).to include("cost (USD): not priced —")
      end
    end
  end

  describe "recordings from a provider that journals prompt_caching degraded" do
    it "shows no cache hit ratio and says why" do
      cacheless = Array.new(2) do
        record([tool_response("tu_1", "hi"), text_response("done")], degrade: :prompt_caching)
      end
      report = described_class.new(recordings: cacheless).report
      expect(report.lines.grep(/\Acache hit ratio\s{2,}/)).to be_empty
      expect(report).to include("cache hit ratio: not measured — every run records prompt_caching degraded")
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
        described_class.new(recordings:).report
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

    # The mode is the same kind of fact the degraded set is: a `bypass` run
    # never stopped for a human, so a distribution drawn across it and an `ask`
    # run measures the approval level rather than the variable. Until the
    # Recording carried a mode this guard was unreachable from every caller in
    # the tree.
    it "raises when the recordings' journals record different modes" do
      automatic = record([tool_response("tu_1", "hi"), text_response("done")], flips: [%w[ask bypass]])
      returned = record([tool_response("tu_1", "hi"), text_response("done")], flips: [%w[ask bypass], %w[bypass ask]])
      expect { described_class.new(recordings: [automatic, returned]) }
        .to raise_error(Lain::Error,
                        %r{checkout/ask → checkout/bypass vs checkout/ask → checkout/bypass → checkout/ask})
    end

    it "compares recordings that walked the same mode trajectory, and names it" do
      pair = Array.new(2) do
        record([tool_response("tu_1", "hi"), text_response("done")], flips: [%w[ask bypass]])
      end
      expect(described_class.new(recordings: pair).report).to include("mode: checkout/ask → checkout/bypass")
    end

    # A pipeline decides the bytes each model call sends, so a pruned run held
    # against an unpruned one would report the pipeline as the model's variance.
    # Judged on the stages that rendered, not the words: an unset flag and
    # `default` send identical bytes, which is the only thing variance reads.
    it "raises when the recordings rendered through different context pipelines" do
      pruned = record([tool_response("tu_1", "hi"), text_response("done")], under: named("prune"))
      expect { described_class.new(recordings: [reference, pruned]) }
        .to raise_error(Lain::Error, /cannot compare runs that differ in context pipeline: .*prune/)
    end

    it "compares a recording named default with an unset one, which rendered the same stages" do
      defaulted = record([tool_response("tu_1", "hi"), text_response("done")], under: named("default"))
      expect(described_class.new(recordings: [reference, defaulted]).report).to include("2: byte-identical")
    end

    # Every fixture in the repo predates modes, so absence has to stay sayable:
    # the report names it rather than implying the axis was controlled for.
    it "reports an unrecorded mode for recordings whose journals hold no mode switch" do
      expect(described_class.new(recordings: [reference, diverging]).report).to include("mode: not recorded")
    end

    # Two recordings under different compaction arms would report the arm
    # difference as the model's variance, exactly the reasoning the pipeline
    # guard above states for pipelines -- but this is a DIFFERENT axis and not
    # judged by that guard's stages-not-names rule: an unset strategy and
    # `summarizing` are not the same policy.
    it "raises when the recordings declared different compaction arms" do
      elided = record([tool_response("tu_1", "hi"), text_response("done")], compact_strategy: "elide")
      expect { described_class.new(recordings: [reference, elided]) }
        .to raise_error(Lain::Error, /cannot compare runs that differ in compaction arm: eager \(1\) vs elide \(2\)/)
    end

    # An unset flag is the run's own eager control arm, not "no arm" -- so a
    # recording naming it EXPLICITLY compares equal to one that named nothing
    # at all, both being the same arm under two spellings.
    it "compares an unset arm and an explicit eager arm, because both ran the same arm" do
      eager = record([tool_response("tu_1", "hi"), text_response("done")], compact_strategy: "eager")
      expect(described_class.new(recordings: [reference, eager]).report).to include("2: byte-identical")
    end
  end

  describe "compaction schedule" do
    def scheduled(schedule) = record([tool_response("tu_1", "hi"), text_response("done")], schedule:)

    it "raises when the recordings ran under different schedules" do
      expect { described_class.new(recordings: [scheduled("idle"), reference]) }
        .to raise_error(Lain::Error, /cannot compare runs that differ in compaction schedule: idle \(1\) vs turn \(2\)/)
    end

    it "pools recordings that ran under the same schedule" do
      expect(described_class.new(recordings: [scheduled("idle"), scheduled("idle")]).report)
        .to include("2: byte-identical")
    end

    it "pools a recording that named the turn schedule with one that configured no compaction" do
      expect(described_class.new(recordings: [scheduled("turn"), reference]).report).to include("2: byte-identical")
    end
  end

  describe "compaction on or off" do
    def compacting(compact) = record([tool_response("tu_1", "hi"), text_response("done")], compact:)

    it "raises when one recording ran without compaction and one recorded nothing" do
      expect { described_class.new(recordings: [compacting(false), reference]) }
        .to raise_error(Lain::Error, /differ in compaction: off \(1\) vs on \(2\)/)
    end

    it "pools recordings that both ran without compaction" do
      expect(described_class.new(recordings: [compacting(false), compacting(false)]).report)
        .to include("2: byte-identical")
    end

    it "refuses a recording that named the turn schedule against one with compaction off" do
      turn = record([tool_response("tu_1", "hi"), text_response("done")], schedule: "turn")
      expect { described_class.new(recordings: [turn, compacting(false)]) }
        .to raise_error(Lain::Error, /differ in compaction: on \(1\) vs off \(2\)/)
    end
  end

  describe "opaque policy" do
    def opaque(run_arms) = record([tool_response("tu_1", "hi"), text_response("done")], run_arms:)

    it "raises when only one recording recorded the opaque policy" do
      expect { described_class.new(recordings: [opaque({ "opaque" => "refused" }), reference]) }
        .to raise_error(Lain::Error, /differ in opaque policy: refused \(1\) vs unrecorded \(2\)/)
    end

    it "raises when the recorded policies differ" do
      expect { described_class.new(recordings: [opaque({ "opaque" => "refused" }), opaque({ "opaque" => "open" })]) }
        .to raise_error(Lain::Error, /differ in opaque policy: refused \(1\) vs open \(2\)/)
    end

    it "pools recordings that both refused opaque commands" do
      refused = opaque({ "opaque" => "refused" })
      expect(described_class.new(recordings: [refused, opaque({ "opaque" => "refused" })]).report)
        .to include("2: byte-identical")
    end
  end

  describe "bench arms" do
    def armed(arms) = record([tool_response("tu_1", "hi"), text_response("done")], arms:)

    it "raises when the recordings ran under different bench arms, naming both" do
      expect { described_class.new(recordings: [armed({ "confine" => "reader" }), reference]) }
        .to raise_error(Lain::Error, /differ in bench arms: confine=reader \(1\) vs none \(2\)/)
    end

    it "pools recordings that ran under the same bench arms" do
      expect(described_class.new(recordings: [armed({ "confine" => "reader" }),
                                              armed({ "confine" => "reader" })]).report)
        .to include("2: byte-identical")
    end

    it "raises when the recordings differ only in an arm's value" do
      expect { described_class.new(recordings: [armed({ "confine" => "reader" }), armed({ "confine" => "classes" })]) }
        .to raise_error(Lain::Error, /differ in bench arms: confine=reader \(1\) vs confine=classes \(2\)/)
    end

    it "pools recordings that recorded no arms" do
      expect(described_class.new(recordings: [reference, reference]).report).to include("2: byte-identical")
    end
  end

  # What produced a run is an axis like any other: a harness edit, a different
  # served model or another host would report as the model's variance.
  describe "provenance" do
    def provenanced(header, responses: [tool_response("tu_1", "hi"), text_response("done")], under: context)
      Lain::Bench::Session.load(with_header(session_bytes(responses, under:), header).each_line)
    end

    def block(harness)
      { "provenance" => { "harness" => harness, "tool_surface" => "blake3:t", "effort" => "unrecorded",
                          "policy" => "blake3:p", "cwd" => "/w", "root" => "/w", "home" => "/h" } }
    end

    it "refuses runs whose harness digests differ, naming both" do
      harnesses = [provenanced(block("sha-a+blake3:1")), provenanced(block("sha-b+blake3:2"))]
      expect { described_class.new(recordings: harnesses) }
        .to raise_error(Lain::Error,
                        "cannot compare runs that differ in harness: sha-a+blake3:1 (1) vs sha-b+blake3:2 (2)")
    end

    it "pools runs whose provenance differs only in where they stood" do
      stood = block("sha-a+blake3:1").fetch("provenance").merge("cwd" => "/x/sub", "root" => "/x", "home" => "/g")
      moved = { "provenance" => stood }
      expect(described_class.new(recordings: [provenanced(block("sha-a+blake3:1")), provenanced(moved)]).report)
        .to include("2: byte-identical")
    end

    # Unrecorded is a value here, not a wildcard: an old journal says nothing
    # about its harness, so it cannot vouch for matching a new one.
    it "refuses an old journal held against one naming a harness" do
      expect { described_class.new(recordings: [reference, provenanced(block("sha-a+blake3:1"))]) }
        .to raise_error(Lain::Error, /differ in harness: unrecorded \(1\) vs sha-a\+blake3:1 \(2\)/)
    end

    it "refuses runs of one requested model whose turn_usage records name different served models" do
      opus = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
      served = %w[claude-opus-4-8 claude-opus-4-7].map do |model|
        provenanced({}, under: opus, responses: [tool_response("tu_1", "hi", model:), text_response("done", model:)])
      end
      expect { described_class.new(recordings: served) }
        .to raise_error(Lain::Error, /differ in served model: claude-opus-4-8 \(1\) vs claude-opus-4-7 \(2\)/)
    end

    def hosted(host) = provenanced({ "writer" => { "pid" => 1, "start" => "0", "host" => host } })

    it "refuses runs of different requested models" do
      opus = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
      expect { described_class.new(recordings: [reference, provenanced({}, under: opus)]) }
        .to raise_error(Lain::Error, /differ in model: claude-sonnet-4-6 \(1\) vs claude-opus-4-8 \(2\)/)
    end

    # A header written before the provenance block still names its effort.
    it "refuses old journals whose headers name different efforts" do
      efforts = %w[high low].map { |effort| provenanced({ "effort" => effort }) }
      expect { described_class.new(recordings: efforts) }
        .to raise_error(Lain::Error, /differ in effort: high \(1\) vs low \(2\)/)
    end

    # A header written before the provenance block still names its tools.
    it "refuses old journals whose headers name different tools" do
      toolless = provenanced({ "tools" => [] })
      expect { described_class.new(recordings: [reference, toolless]) }
        .to raise_error(Lain::Error, /differ in tool surface: \S+ \(1\) vs #{Lain::Canonical.digest([])} \(2\)/)
    end

    it "names each value with the ordinals of the runs that carry it" do
      expect { described_class.new(recordings: %w[bench-a bench-a bench-b].map { |host| hosted(host) }) }
        .to raise_error(Lain::Error, /differ in host: bench-a \(1-2\) vs bench-b \(3\)\z/)
      expect { described_class.new(recordings: %w[bench-a bench-b bench-a].map { |host| hosted(host) }) }
        .to raise_error(Lain::Error, /differ in host: bench-a \(1, 3\) vs bench-b \(2\)\z/)
    end

    it "refuses runs recorded on different hosts" do
      hosts = %w[bench-a bench-b].map do |host|
        provenanced({ "writer" => { "pid" => 1, "start" => "0", "host" => host } })
      end
      expect { described_class.new(recordings: hosts) }
        .to raise_error(Lain::Error, /differ in host: bench-a \(1\) vs bench-b \(2\)/)
    end
  end

  describe "n >= 2" do
    it "raises ArgumentError on a single recording" do
      expect { described_class.new(recordings: [reference]) }
        .to raise_error(ArgumentError, /at least two/)
    end

    it "counts only the recordings, never the runs set aside, toward the two" do
      expect { described_class.new(recordings: [reference], set_aside: ["2.failed.ndjson: failed recording"]) }
        .to raise_error(ArgumentError, /at least two/)
    end
  end

  # Runs that could not be measured are named rather than averaged in or
  # silently dropped: a reader of the table has to know what it is over.
  describe "runs set aside" do
    let(:set_aside) { ["3.failed.ndjson: failed recording", "4.ndjson: no usage recorded beside a truncated stream"] }

    it "lists each one, with why, in a section of its own" do
      report = described_class.new(recordings: [reference, diverging], set_aside:).report

      expect(report).to end_with("== Set aside ==\n#{set_aside.join("\n")}")
      expect(report).to start_with("Variance — 2 recordings")
    end

    it "adds no section when every run was measured" do
      expect(described_class.new(recordings: [reference, diverging]).report).not_to include("Set aside")
    end
  end
end
