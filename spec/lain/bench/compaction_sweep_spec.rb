# frozen_string_literal: true

require "bigdecimal"
require "fileutils"
require "json"
require "tmpdir"

# Every arm replays the same recorded sessions offline: a cut fires when the droppable head passes
# a byte budget, each request is re-rendered through the arm's derived chain, and the cache cost is
# simulated from those re-rendered prefixes. Model arms answer from the journal's recorded answers,
# or from a summarizer the caller hands in; these specs stub that summarizer and never reach a model.
#
# Two corpora: the committed planted-claim sessions, whose tool results are small, and a session
# this file records into a temporary directory, whose results are large enough for the eager tier
# to summarize. Every summary in it is written here by hand; none came from a model.
# A spec-only session: one ask of `rounds` lookups, each answered with about 5 KB of synthetic
# text, or exactly `size` bytes when given, the first carrying `claim`. Recorded through the wiring
# the planted corpus uses.
module CompactionSweepLargeResults
  module_function

  CLAIM = "the copper sluice opens at the ninth bell"

  def record(path, rounds: 12, size: nil)
    journal = Lain::Journal.open(path, clock: Lain::Bench::PlantedClaims::CLOCK)
    toolset = Lain::Toolset.new([tool(size)])
    context = Lain::Context.new(model: "claude-sonnet-4-6", max_tokens: 1024, system: "be terse")
    scribe = Lain::SessionRecord::Scribe.new(journal:, context:, toolset:,
                                             writer: Lain::Bench::PlantedClaims::WRITER)
    stack = Lain::Middleware::Stack.new([Lain::Middleware::JournalRequests.new(journal:)])
    agent = Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: responses(rounds)), toolset:, context:,
                            journal:, model_middleware: stack)
    agent.ask("review the records")
    scribe.catch_up(agent.timeline).close(reason: :exit)
    path
  ensure
    journal&.close
  end

  def fixture(path) = Lain::Bench::PlantedClaims::Fixture.new(path:, claim: CLAIM, carrier_digest: "unused")

  def tool(size)
    Class.new(Lain::Tool) do
      define_method(:name) { "ledger_lookup" }
      define_method(:description) { "Looks up a topic (synthetic bench data)." }
      define_method(:input_schema) { { type: :object, properties: { topic: { type: :string } }, required: [:topic] } }
      define_method(:perform) do |input, _context|
        topic = input.fetch("topic")
        finding = topic == "t0" ? CLAIM : "nothing notable"
        text = "#{topic}: #{finding}. #{"a routine line about #{topic}. " * 200}"
        Lain::Tool::Result.ok(size ? text.ljust(size, ".")[0, size] : text)
      end
    end.new
  end

  def responses(rounds)
    lookups = (0...rounds).map do |index|
      Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_#{index}", "name" => "ledger_lookup",
                                     "input" => { "topic" => "t#{index}" } }],
                         stop_reason: :tool_use, model: "claude-sonnet-4-6",
                         usage: Lain::Usage.new(input_tokens: 10, output_tokens: 5))
    end
    lookups + [Lain::Response.new(content: [{ "type" => "text", "text" => "done" }], stop_reason: :end_turn,
                                  model: "claude-sonnet-4-6", usage: Lain::Usage.new(input_tokens: 10,
                                                                                     output_tokens: 5))]
  end
end

RSpec.describe Lain::Bench::CompactionSweep do
  committed = File.expand_path("../../fixtures/compaction/planted", __dir__)
  let(:small_budget) { 1_000 }
  let(:huge_budget) { 10_000_000 }
  let(:keep_last) { 20 }

  let(:fixtures) { Lain::Bench::PlantedClaims.in(committed) }
  let(:two) { fixtures.first(2).map(&:path) }
  let(:tmp) { Dir.mktmpdir("compaction-sweep") }

  after { FileUtils.rm_rf(tmp) }

  def sweep(journals: two, budget: small_budget, **options)
    described_class.new(journals:, price_as: "claude-haiku-5-5", budget:, **options)
  end

  def row(rows, arm, placement = "framed") = rows.find { |each| each.arm == arm && each.placement == placement }

  # The summarizer the caller would hand in for --summarizer local. It keeps each question it was
  # asked so a spec can journal an answer to it.
  def stub_tier(definition, asked, summary: "a short recap")
    Object.new.tap do |tier|
      tier.define_singleton_method(:ask) do |inputs = {}|
        asked << [definition, definition.render(inputs)]
        definition.answer({ "summary" => summary })
      end
      tier.define_singleton_method(:model) { "stub-summarizer" }
      tier.define_singleton_method(:usage) { {} }
    end
  end

  def oracle_answer(definition, question, summary)
    JSON.generate("ts" => "1970-01-01T00:00:00Z", "type" => "oracle_answer", "oracle_digest" => definition.digest,
                  "question" => question, "answer" => { "summary" => summary })
  end

  def append(path, lines) = File.open(path, "a") { |file| lines.each { |line| file.puts(line) } }

  # The prefix in cache order as one byte string, and where two of them first differ: the rule
  # the simulated rebill follows, restated here so the spec does not read it off the subject.
  def prefix_bytes(request)
    [Lain::Canonical.dump(request.tools), Lain::Canonical.dump(request.system),
     *Lain::Request.strip_cache_markers(request.messages).map { |each| Lain::Canonical.dump(each) }].join
  end

  def first_difference(before, after)
    before.bytes.zip(after.bytes).index { |a, b| a != b } || before.bytesize
  end

  def large_session(name = "large.ndjson", **) = CompactionSweepLargeResults.record(File.join(tmp, name), **)

  describe "an offline sweep" do
    let(:arms) { %w[elide truncate-cumulative summarizing] }

    it "prints one row per arm with every column and a legend" do
      report = sweep(arms:).report

      expect(report).to include("n", "request bytes", "cuts", "mid-task rate", "rebilled tokens (est.)",
                                "rebilled cost (est.)", "kept verbatim", "kept in recap")
      expect(report.lines.map(&:split).filter_map(&:first)).to include(*arms)
      expect(report).to include("Cache cost is simulated from re-rendered prefixes at 4 bytes a token")
      expect(report).to include("request bytes", "every re-rendered request", "after the first byte")
      expect(report).to include("2 journals, budget #{small_budget} bytes", "claude-haiku-5-5")
    end

    it "says journal in the singular for one" do
      expect(sweep(journals: two.first(1), arms: %w[elide]).report).to include("1 journal,")
    end

    it "measures each deterministic arm over every journal" do
      rows = sweep(arms:).rows

      expect(rows.map(&:arm)).to eq(arms)
      expect(row(rows, "truncate-cumulative")).to have_attributes(n: 2, cuts: 2, note: nil)
      expect(row(rows, "truncate-cumulative").request_bytes).to be_positive
    end

    # Elide's attestation outweighs these small messages, so a cut would send more, not less.
    it "keeps no cut that would not shrink what the turn sends" do
      expect(row(sweep(arms: %w[elide]).rows, "elide")).to have_attributes(n: 2, cuts: 0)
    end

    it "calls no provider and builds no model tier" do
      expect(Lain::Oracle::Model).not_to receive(:new)
      expect(Lain::Provider::Anthropic).not_to receive(:new)
      expect(Lain::Provider::Ollama).not_to receive(:new)

      sweep(arms:).rows
    end

    it "is byte-identical when run twice" do
      expect(sweep(arms:).report).to eq(sweep(arms:).report)
    end

    it "sweeps a journal named twice, or by two spellings of one path, once" do
      relative = Pathname(two.first).relative_path_from(Pathname(Dir.pwd)).to_s

      expect(sweep(journals: [two.first, relative, two.first], arms: %w[elide]).rows.first.n).to eq(1)
    end
  end

  describe "a model arm without a recorded answer" do
    it "is skipped, never invented" do
      rows = sweep(arms: %w[summarizing summarizing-flat]).rows

      expect(rows.map(&:note)).to all(eq("no recorded answers"))
      expect(rows.flat_map { |each| [each.n, each.request_bytes, each.cuts, each.rebilled_tokens] }.compact)
        .to be_empty
    end

    it "carries no figures in the report" do
      line = sweep(arms: %w[summarizing]).report.lines.find { |each| each.start_with?("summarizing") }

      expect(line).to include("no recorded answers")
      expect(line.scan(/\d/)).to be_empty
    end

    # The planted sessions are almost all tool rounds, which summarize-conversation leaves to
    # elide-tools, so it never had a question to answer.
    it "measures a model arm that needed no answer" do
      expect(row(sweep(arms: %w[summarize-conversation]).rows, "summarize-conversation"))
        .to have_attributes(note: nil, n: 2, cuts: 0)
    end
  end

  describe "a model arm with recorded answers" do
    let(:asked) { [] }
    let(:local) { ->(definition) { stub_tier(definition, asked) } }

    # What a stubbed summarizer was asked, answered by hand in copies of the sessions as the
    # oracle_answer records a live run journals.
    def recorded_copies
      two.map do |path|
        copy = File.join(tmp, File.basename(path))
        FileUtils.cp(path, copy)
        sweep(journals: [copy], arms: %w[summarizing], summarizer: local).rows
        append(copy, asked.map { |definition, question| oracle_answer(definition, question, "a short recap") })
        asked.clear
        copy
      end
    end

    it "replays the recorded answers to the same figures the summarizer gave" do
      copies = recorded_copies
      live = row(sweep(journals: copies, arms: %w[summarizing], summarizer: local).rows, "summarizing")
      replayed = row(sweep(journals: copies, arms: %w[summarizing]).rows, "summarizing")

      expect(replayed).to eq(live)
      expect(replayed).to have_attributes(note: nil, n: 2)
      expect(replayed.cuts).to be_positive
    end

    it "journals each answer the summarizer gives" do
      journal = []
      sweep(arms: %w[summarizing], summarizer: local, journal:).rows

      expect(journal.grep(Lain::Telemetry::OracleAnswer).size).to eq(asked.size)
      expect(asked).not_to be_empty
    end

    it "fails loudly with the summarizer's own error rather than reading as unanswered" do
      down = lambda do |_definition|
        Object.new.tap do |tier|
          tier.define_singleton_method(:ask) { |_inputs = {}| raise Lain::Error, "connection refused" }
          tier.define_singleton_method(:model) { "stub" }
          tier.define_singleton_method(:usage) { {} }
        end
      end

      expect { sweep(arms: %w[summarizing], summarizer: down).rows }.to raise_error(Lain::Error, /connection refused/)
    end
  end

  describe "the eager arm" do
    let(:path) { large_session }
    let(:definition) { Lain::Oracle::Summarize.definition }

    # The question a live chat's eager tier journals for a result: the result's text in the slot.
    def tool_results(path)
      recording = Lain::Bench::Session.load(path)
      Lain::EventLog::Messages.project(recording.timeline.to_a).flat_map { |message| Array(message["content"]) }
                              .select { |block| block["type"] == "tool_result" }.map { |block| block["content"] }
    end

    it "is measured from eager summaries journaled in the live chat's shape" do
      append(path, tool_results(path).uniq.map do |text|
        oracle_answer(definition, definition.render(source: text), "a lookup with nothing notable")
      end)

      eager = row(sweep(journals: [path], arms: %w[eager]).rows, "eager")

      expect(eager).to have_attributes(note: nil, n: 1)
      expect(eager.cuts).to be_positive
    end

    it "says no recorded answers when the journal holds none" do
      expect(row(sweep(journals: [path], arms: %w[eager]).rows, "eager").note).to eq("no recorded answers")
    end

    it "asks only about results big enough for a model call" do
      asked = []
      sweep(arms: %w[eager], summarizer: ->(each) { stub_tier(each, asked) }).rows

      expect(asked).to be_empty
    end

    describe "at the model tier's threshold" do
      let(:threshold) { Lain::Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES }

      def asked_over(size)
        path = large_session("sized-#{size}.ndjson", rounds: 3, size:)
        asked = []
        sweep(journals: [path], arms: %w[eager], summarizer: ->(each) { stub_tier(each, asked) }).rows
        [tool_results(path).map(&:bytesize).uniq, asked.size]
      end

      it "does not ask about a result of exactly the threshold" do
        expect(asked_over(threshold)).to eq([[threshold], 0])
      end

      it "asks about a result one byte over it" do
        expect(asked_over(threshold + 1)).to eq([[threshold + 1], 3])
      end
    end
  end

  describe "planted-claim survival" do
    let(:paths) { fixtures.map(&:path) }

    it "counts each fixture whose claim reaches a non-recap user message as kept verbatim" do
      rows = sweep(journals: paths, planted: fixtures, arms: %w[truncate-cumulative], placements: %w[bare]).rows

      expect(row(rows, "truncate-cumulative", "bare")).to have_attributes(kept_verbatim: 5, planted: 6)
    end

    it "counts a claim carried only inside the recap as kept in recap, not verbatim" do
      one = fixtures.select { |fixture| File.basename(fixture.path) == "one.ndjson" }
      rows = sweep(journals: one.map(&:path), planted: one, arms: %w[truncate-cumulative],
                   placements: %w[bare framed]).rows

      expect(rows.map { [_1.kept_verbatim, _1.kept_in_recap] }).to eq([[0, 1], [0, 1]])
    end

    it "counts every claim verbatim when no cut fires" do
      rows = sweep(journals: paths, planted: fixtures, arms: %w[truncate-cumulative], placements: %w[bare],
                   budget: huge_budget).rows

      expect(row(rows, "truncate-cumulative", "bare")).to have_attributes(kept_verbatim: 6, kept_in_recap: 0, cuts: 0)
    end

    it "leaves both columns empty for journals with no planted claim" do
      measured = row(sweep(arms: %w[elide]).rows, "elide")
      cells = sweep(arms: %w[elide]).report.lines.last.strip.split(/\s{2,}/)

      expect(measured.planted).to eq(0)
      expect(cells.last(2)).to eq(%w[- -])
    end

    describe "behind a hand-written summary" do
      let(:path) { large_session }

      # Two copies of one session, the summarizer's answers written by hand: one summary repeats
      # the claim, the other drops it.
      def answered_copy(name, summary)
        copy = File.join(tmp, name)
        FileUtils.cp(path, copy)
        asked = []
        sweep(journals: [copy], arms: %w[summarizing], summarizer: ->(each) { stub_tier(each, asked) }).rows
        append(copy, asked.map { |definition, question| oracle_answer(definition, question, summary) })
        copy
      end

      def measured(copy)
        planted = [CompactionSweepLargeResults.fixture(copy)]
        row(sweep(journals: [copy], planted:, arms: %w[summarizing]).rows, "summarizing")
      end

      it "tells a summary that kept the claim from one that dropped it" do
        kept = measured(answered_copy("kept.ndjson", "the first lookup said #{CompactionSweepLargeResults::CLAIM}"))
        dropped = measured(answered_copy("dropped.ndjson", "routine lookups, nothing notable"))

        expect(kept).to have_attributes(note: nil, kept_verbatim: 0, kept_in_recap: 1, planted: 1)
        expect(dropped).to have_attributes(note: nil, kept_verbatim: 0, kept_in_recap: 0, planted: 1)
      end
    end
  end

  describe "cache cost" do
    let(:truncated) { row(sweep(arms: %w[truncate-cumulative]).rows, "truncate-cumulative") }

    it "charges each cut that rewrites the prefix as earlier messages edited" do
      expect(truncated.rebilled_tokens).to be_positive
      expect(truncated.causes).to eq(history_edited: truncated.cuts)
      expect(sweep(arms: %w[truncate-cumulative]).report).to include("earlier messages edited")
    end

    it "prices the rebilled tokens as cache writes of the named model" do
      expect(truncated.rebilled_cost.amount).to eq(BigDecimal("0.125") / 1_000_000 * truncated.rebilled_tokens)
    end

    it "charges nothing when no cut fires" do
      quiet = row(sweep(arms: %w[truncate-cumulative], budget: huge_budget).rows, "truncate-cumulative")

      expect(quiet).to have_attributes(cuts: 0, rebilled_tokens: 0, mid_task_rate: nil)
    end

    # Truncation keeps the span up to the last tool result before the kept tail, so every cut it
    # takes on a tool-round session ends inside a task.
    it "reports the share of cuts that land mid-task" do
      expect(truncated.mid_task_rate).to eq(1.0)
    end

    describe "for a cut at a known request" do
      let(:path) { large_session(rounds: 11) }
      let(:recording) { Lain::Bench::Session.load(path) }
      let(:timelines) { recording.dry_replay.each_step.map(&:timeline) }

      def rendered(timeline)
        recording.context.render(timeline:, toolset: recording.toolset, workspace: recording.workspace)
      end

      # Request 11, the last, is the first whose droppable head passes the budget, and a truncating
      # cut there rewrites the prefix the requests before it built.
      it "rebills exactly the rewritten prefix after the first difference" do
        cut_at = timelines.index do |timeline|
          head = Lain::Compaction::Head.new(messages: timeline.messages, keep_last:)
          !head.empty? && head.bytesize >= small_budget
        end
        derived = Lain::Compaction::Derivation.new(strategy: Lain::Compaction::Strategy::TruncateOnly.new, keep_last:)
                                              .derive(timelines.fetch(cut_at))
        before = prefix_bytes(rendered(timelines.fetch(cut_at - 1)))
        after = prefix_bytes(rendered(derived))

        swept = row(sweep(journals: [path], arms: %w[truncate-cumulative]).rows, "truncate-cumulative")

        expect(cut_at).to eq(11)
        expect(swept).to have_attributes(cuts: 1, causes: { history_edited: 1 },
                                         rebilled_tokens: (after.bytesize - first_difference(before, after)) / 4)
      end
    end
  end

  it "refuses an arm it does not know, naming the ones it does" do
    expect { sweep(arms: %w[truncate]) }
      .to raise_error(ArgumentError, /truncate.*eager, elide, elide-tools, summarizing/)
  end

  it "refuses an empty arm list" do
    expect { sweep(arms: []) }.to raise_error(ArgumentError, /no arms/)
  end

  it "sweeps an arm named twice once" do
    expect(sweep(arms: %w[elide elide]).rows.size).to eq(1)
  end

  it "refuses a placement it does not know" do
    expect { sweep(arms: %w[elide], placements: %w[system]) }.to raise_error(ArgumentError, /placement/)
  end
end
