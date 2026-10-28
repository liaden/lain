# frozen_string_literal: true

require "bigdecimal"
require "fileutils"
require "json"
require "tmpdir"

# The live sweep spends real money, so nothing here reaches a provider: the counter and the
# messages endpoint are a Mock, or a real Provider::Anthropic behind WebMock stubs. The model's
# replies are the recorded ones, so a live arm walks the recorded turns and its requests can be
# held against the ones the preflight counted.
RSpec.describe Lain::Bench::CompactionSweep::Live do
  committed = File.expand_path("../../../fixtures/compaction/planted", __dir__)
  let(:model) { "claude-haiku-5-5" }
  let(:fixtures) { Lain::Bench::PlantedClaims.in(committed) }
  let(:two) { fixtures.first(2).map(&:path) }
  let(:arms) { %w[elide elide-tools truncate-cumulative] }
  let(:sweep) { Lain::Bench::CompactionSweep.new(journals: two, arms:, price_as: model, budget: 1_000) }
  let(:book) { Lain::PriceBook.default }

  # A Mock that counts as count_tokens would: the canonical bytes over 4, unless a spec names a
  # figure for one call by its index.
  let(:counting) do
    Class.new(Lain::Provider::Mock) do
      attr_reader :counted

      def initialize(figures: {}, **)
        super(**)
        @figures = figures
        @counted = []
      end

      def count_tokens(request)
        @counted << request
        @figures.fetch(@counted.size - 1) { Lain::Canonical.dump(request.cache_payload).bytesize / 4 }
      end
    end
  end

  def recorded_replies(path, usage: Lain::Usage.new(input_tokens: 10, output_tokens: 5))
    Lain::Bench::Session.load(path).timeline.to_a.select { _1.role == "assistant" }.map do |turn|
      stop = turn.content.any? { _1["type"] == "tool_use" } ? :tool_use : :end_turn
      Lain::Response.new(content: turn.content, stop_reason: stop, model:, usage:)
    end
  end

  def replies_for(arm_count, paths = two, **)
    Array.new(arm_count) { paths.flat_map { recorded_replies(_1, **) } }.flatten
  end

  def calls_in(path) = File.foreach(path).count { _1.include?('"type":"request_sent"') }

  def live(provider:, confirm: ->(_preflight) { true }, hold: Lain::Provider::HTTP::PriceTierGuard::Hold.new, **)
    described_class.new(sweep:, provider:, confirm:, model:, hold:, **)
  end

  # The recorded replies with a text block put before the first, so every later request differs
  # from the one the preflight counted.
  def diverged(replies)
    first, *rest = replies
    [first.with(content: [{ "type" => "text", "text" => "let me look" }, *first.content]), *rest]
  end

  def results_in(request)
    request.messages.flat_map { Array(_1["content"]) }.select { _1["type"] == "tool_result" }
  end

  describe "#preflight" do
    let(:provider) { counting.new(figures: { 2 => 150_001 }) }
    let(:checked) { live(provider:).preflight }

    it "counts every request each arm would send through count_tokens, and sends none" do
      checked

      expect(provider.counted.size).to eq(arms.size * two.sum { calls_in(_1) })
      expect(provider.counted.map(&:model).uniq).to eq([model])
      expect(provider.requests).to be_empty
    end

    it "projects each arm's cost at most, every prompt priced as a cache write with a full reply" do
      checked
      costs = provider.counted.each_with_index.map do |request, index|
        tokens = index == 2 ? 150_001 : Lain::Canonical.dump(request.cache_payload).bytesize / 4
        book.cost(model, Lain::Usage.new(cache_creation_input_tokens: tokens, output_tokens: request.max_tokens))
      end
      expected = costs.each_slice(two.sum { calls_in(_1) }).map(&:sum)

      expect(checked.projected.keys).to eq(arms)
      expect(checked.projected.values).to eq(expected)
      expect(checked.report).to include("at most", "total", format("$%.4f", expected.sum))
    end

    it "lists each request over the price tier with its arm, journal and turn" do
      expect(checked.over_tier.map { [_1.arm, _1.journal, _1.turn, _1.tokens] })
        .to eq([["elide", two.first, 3, 150_001]])
      expect(checked.report).to include("elide", File.basename(two.first), "turn 3", "150001")
    end

    it "states how many crossings each lane may make" do
      expect(checked.report).to include("elide, #{File.basename(two.first)}: up to 1 request over the tier allowed")
      expect(checked.report).not_to include("over the tier, at most")
    end

    it "refuses a model arm with no recorded summary for a span it would cut, before counting it" do
      summarizing = Lain::Bench::CompactionSweep.new(journals: two, arms: %w[summarizing], price_as: model,
                                                     budget: 1_000)

      expect do
        described_class.new(sweep: summarizing, provider:, confirm: ->(_) { true }, model:,
                            hold: Lain::Provider::HTTP::PriceTierGuard::Hold.new).preflight
      end
        .to raise_error(Lain::Bench::CompactionSweep::Unanswered, /summarizing has no recorded answers/)
      expect(provider.counted).to be_empty
    end

    it "asks to spend about the projected total, naming the hard cap" do
      total = checked.projected.values.sum

      expect(checked.question)
        .to eq("spend about #{format("$%.4f", total)}, capped at #{format("$%.4f", total * BigDecimal("1.5"))}? [y/N]")
    end
  end

  describe "#run" do
    it "asks for confirmation with the preflight before any messages call" do
      provider = counting.new(responses: replies_for(arms.size))
      asked = []

      live(provider:, confirm: lambda { |preflight|
        asked << [preflight.requests.size, provider.requests.size]
        true
      }).run

      expect(asked).to eq([[provider.counted.size, 0]])
      expect(provider.requests).not_to be_empty
    end

    it "sends nothing and says so when the human declines" do
      provider = counting.new(responses: replies_for(arms.size))

      expect { live(provider:, confirm: ->(_preflight) { false }).run }
        .to raise_error(described_class::Declined, /no paid request was sent/)
      expect(provider.requests).to be_empty
    end

    it "stops at a lane's dollar ceiling of 1.5 times its projection, runs no later lane, and still reports" do
      dear = Lain::Usage.new(input_tokens: 2_000_000, output_tokens: 0)
      provider = counting.new(responses: replies_for(arms.size, usage: dear))
      checked = live(provider: counting.new).preflight
      first_lane = checked.requests.select { _1.arm == "elide" && _1.journal == two.first }
      ceiling = first_lane.sum(BigDecimal(0), &:cost) * BigDecimal("1.5")

      report = live(provider:).run

      expect(provider.requests.size).to eq(1)
      expect(report).to include("ceiling is #{ceiling.to_s("F")}", described_class.dollars(book.cost(model, dear)))
      expect(report.scan("not run: an earlier lane passed its dollar ceiling").size).to eq((arms.size * 2) - 1)
    end

    it "fails a run whose lane raised, carrying the whole table, and runs no later lane" do
      failing = Class.new(counting) do
        def complete(...) = raise(ArgumentError, "a defect in the provider")
      end

      expect { live(provider: failing.new).run }.to raise_error(described_class::Failed) { |error|
        expect(error.message).to include("stopped: ArgumentError: a defect in the provider", "spent")
        expect(error.message.scan("not run: an earlier lane failed").size).to eq((arms.size * 2) - 1)
        expect(error.message.lines.last).to match(/elide, .*: ArgumentError: a defect in the provider/)
      }
    end

    it "reports what each arm spent beside its projection and ceiling" do
      provider = counting.new(responses: replies_for(arms.size))

      report = live(provider:).run

      expect(report).to include("projected", "spent", "ceiling", *arms)
    end
  end

  describe "a compaction arm run live" do
    let(:arms) { %w[truncate-cumulative] }

    it "sends the derived chains the preflight counted, cuts included" do
      provider = counting.new(responses: replies_for(1))

      live(provider:).run

      expect(provider.requests.map(&:digest)).to eq(provider.counted.map(&:digest))
      recorded = two.sum { calls_in(_1) }
      expect(provider.requests.size).to eq(recorded)
      uncut = two.flat_map { |path| Lain::Bench::Session.load(path).dry_replay.each_step.map { _1.timeline.to_a.size } }
      expect(provider.requests.map { _1.messages.size }).not_to eq(uncut)
    end

    it "answers each tool call from the recording" do
      provider = counting.new(responses: replies_for(1))
      live(provider:).run
      results = results_in(provider.requests.last)

      expect(results).not_to be_empty
      expect(results.none? { _1["is_error"] }).to be(true)
    end
  end

  # A recording whose one lookup was called twice with the same input and answered differently.
  describe "tool calls the recording repeats or never made" do
    let(:tmp) { Dir.mktmpdir("live-sweep-tools") }
    let(:arms) { %w[truncate-cumulative] }
    let(:session) { LiveSweepSession.record(File.join(tmp, "repeats.ndjson"), topics: %w[a a]) }
    let(:sweep) do
      Lain::Bench::CompactionSweep.new(journals: [session], arms:, price_as: model, budget: 100_000_000)
    end

    after { FileUtils.rm_rf(tmp) }

    def lookup(id, topic)
      Lain::Response.new(content: [{ "type" => "tool_use", "id" => id, "name" => "ledger_lookup",
                                     "input" => { "topic" => topic } }],
                         stop_reason: :tool_use, model:, usage: Lain::Usage.new(input_tokens: 10, output_tokens: 5))
    end

    def answers(provider) = provider.requests.drop(1).map { results_in(_1).last.slice("content", "is_error") }

    it "answers the nth identical call with the nth recorded result, and one past the last as unrecorded" do
      *lookups, done = recorded_replies(session)
      provider = counting.new(responses: [*lookups, lookup("tu_9", "a"), done])

      live(provider:).run

      expect(answers(provider)).to match([{ "content" => "a: answer 1", "is_error" => false },
                                          { "content" => "a: answer 2", "is_error" => false },
                                          { "content" => a_string_starting_with("no recorded result"),
                                            "is_error" => true }])
    end

    it "answers a call with input the recording lacks with an error the next request carries" do
      provider = counting.new(responses: [lookup("tu_9", "never asked"), recorded_replies(session).last])

      live(provider:).run

      expect(results_in(provider.requests[1]).last)
        .to include("is_error" => true, "content" => a_string_starting_with("no recorded result for this call"))
    end
  end

  describe "a model arm whose recorded answers run out once the live chain diverges" do
    let(:tmp) { Dir.mktmpdir("live-sweep-answers") }
    let(:journal_path) { two.first }
    let(:answers) { File.join(tmp, "answers.ndjson") }

    after { FileUtils.rm_rf(tmp) }

    def stub_tier(definition)
      Object.new.tap do |tier|
        tier.define_singleton_method(:ask) { |_inputs = {}| definition.answer({ "summary" => "a short recap" }) }
        tier.define_singleton_method(:model) { "stub-summarizer" }
        tier.define_singleton_method(:usage) { {} }
      end
    end

    def local_summarizer
      Lain::Bench::CompactionSweep::Summarizer::Local.new(->(definition) { stub_tier(definition) })
    end

    def record_answers
      sink = Lain::Journal.open(answers)
      Lain::Bench::CompactionSweep.new(journals: [journal_path], arms: %w[summarizing], price_as: model,
                                       budget: 1_000, summarizer: local_summarizer,
                                       journal: sink).rows
    ensure
      sink&.close
    end

    it "marks the lane with how many cuts it skipped" do
      record_answers
      sweep = Lain::Bench::CompactionSweep.new(journals: [journal_path], arms: %w[summarizing], price_as: model,
                                               budget: 1_000, recorded: [answers])
      provider = counting.new(responses: diverged(recorded_replies(journal_path)))

      report = described_class.new(sweep:, provider:, confirm: ->(_) { true }, model:,
                                   hold: Lain::Provider::HTTP::PriceTierGuard::Hold.new).run

      expect(report).to match(/summarizing .* \d+ cuts skipped: no recorded answer/)
    end
  end

  describe "the confirmation prompt" do
    let(:said) { [] }
    let(:asked) { [] }
    let(:preflight) { live(provider: counting.new).preflight }

    def prompt(yes:, terminal:, answer: true)
      described_class::Prompt.new(yes:, terminal:, say: ->(text) { said << text },
                                  ask: ->(question) { (asked << question) && answer })
    end

    it "prints the preflight and asks at a terminal" do
      expect(prompt(yes: false, terminal: true, answer: false).call(preflight)).to be(false)
      expect(said).to eq([preflight.report])
      expect(asked).to eq([preflight.question])
    end

    it "refuses headless without --yes, after printing the preflight" do
      expect(prompt(yes: false, terminal: false).call(preflight)).to be(false)
      expect(said).to eq([preflight.report])
      expect(asked).to be_empty
    end

    it "accepts the preflight without asking under --yes" do
      expect(prompt(yes: true, terminal: false).call(preflight)).to be(true)
      expect(said).to eq([preflight.report])
      expect(asked).to be_empty
    end
  end

  # The real provider and its real price-tier guard, behind WebMock: a session whose fourth
  # request passes the 100000-token tier, counted at the stubbed endpoint.
  describe "the price-tier backstop", :seam do
    let(:tmp) { Dir.mktmpdir("live-sweep") }
    let(:arms) { %w[truncate-cumulative] }
    let(:session) { LiveSweepSession.record(File.join(tmp, "large.ndjson"), topics: %w[t0 t1 t2], bytes: 150_000) }
    let(:sweep) do
      Lain::Bench::CompactionSweep.new(journals: [session], arms:, price_as: model, budget: 100_000_000)
    end
    let(:hold) { Lain::Provider::HTTP::PriceTierGuard::Hold.new }
    let(:count_url) { "https://api.anthropic.com/v1/messages/count_tokens" }
    let(:messages_url) { "https://api.anthropic.com/v1/messages" }
    let(:counter) { Lain::Provider::HTTP::PriceTierGuard::LateCounter.new }
    let(:provider) do
      guard = [Lain::Provider::HTTP::PriceTierGuard,
               { prices: book, counter:, hold:, journal: Lain::Channel::Null.instance, mode: :ask }]
      counter.bind(Lain::Provider::Anthropic.new(api_key: "test", http_middleware: [guard]))
    end

    after { FileUtils.rm_rf(tmp) }

    def counts(figures)
      queue = figures.dup
      stub_request(:post, count_url).to_return do |request|
        tokens = queue.empty? ? JSON.parse(request.body).to_json.bytesize / 4 : queue.shift
        { status: 200, headers: { "Content-Type" => "application/json" },
          body: JSON.generate("input_tokens" => tokens) }
      end
    end

    # Answers by the request's place in its lane, read off how many replies it already carries.
    def replies(queue = recorded_replies(session))
      stub_request(:post, messages_url).to_return do |request|
        place = JSON.parse(request.body)["messages"].count { _1["role"] == "assistant" }
        { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: AnthropicSSE.body(queue[place]) }
      end
    end

    it "sends a crossing the preflight listed" do
      counts([])
      sent = replies

      checked = nil
      Sync { live(provider:, hold:, confirm: ->(preflight) { (checked = preflight) && true }).run }

      expect(checked.over_tier.map(&:turn)).to eq([4])
      expect(sent).to have_been_requested.times(4)
    end

    it "approves the lane's listed crossing though the live chain has diverged from the counted one" do
      counts([])
      sent = replies(diverged(recorded_replies(session)))

      report = Sync { live(provider:, hold:).run }

      expect(sent).to have_been_requested.times(4)
      expect(report).not_to include("stopped")
    end

    describe "over a session whose fourth and fifth requests cross" do
      let(:session) do
        LiveSweepSession.record(File.join(tmp, "larger.ndjson"), topics: %w[t0 t1 t2 t3], bytes: 150_000)
      end

      it "refuses a crossing past the lane's allowance, though one was approved on the same model" do
        counts([1, 1, 1, 200_000, 1])
        sent = replies(diverged(recorded_replies(session)))
        checked = nil

        report = Sync { live(provider:, hold:, confirm: ->(preflight) { (checked = preflight) && true }).run }

        expect(checked.over_tier.map(&:turn)).to eq([4])
        expect(sent).to have_been_requested.times(4)
        expect(report).to include("stopped: ", "price tier")
      end
    end

    describe "over two arms" do
      let(:arms) { %w[truncate-cumulative elide] }

      it "refuses an unlisted crossing in each lane, ending only that lane" do
        counts([1, 1, 1, 1, 1, 1, 1, 1])
        sent = replies

        report = Sync { live(provider:, hold:).run }

        expect(sent).to have_been_requested.times(6)
        expect(report.scan("price tier").size).to eq(2)
      end
    end
  end
end

# One ask that looks up each topic in turn. Each answer is `bytes` long, or names its call's place
# among the calls on its topic. Recorded the way the planted corpus is.
module LiveSweepSession
  module_function

  def record(path, topics:, bytes: nil)
    journal = Lain::Journal.open(path, clock: Lain::Bench::PlantedClaims::CLOCK)
    toolset = Lain::Toolset.new([tool(bytes)])
    context = Lain::Context.new(model: "claude-haiku-5-5", max_tokens: 1024, system: "be terse")
    scribe = Lain::SessionRecord::Scribe.new(journal:, context:, toolset:, writer: Lain::Bench::PlantedClaims::WRITER)
    stack = Lain::Middleware::Stack.new([Lain::Middleware::JournalRequests.new(journal:)])
    agent = Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: responses(topics)), toolset:, context:,
                            journal:, model_middleware: stack)
    agent.ask("read the ledgers")
    scribe.catch_up(agent.timeline).close(reason: :exit)
    path
  ensure
    journal&.close
  end

  def tool(bytes)
    calls = Hash.new(0)
    Class.new(Lain::Tool) do
      define_method(:name) { "ledger_lookup" }
      define_method(:description) { "Looks up a ledger (synthetic bench data)." }
      define_method(:input_schema) { { type: :object, properties: { topic: { type: :string } }, required: [:topic] } }
      define_method(:perform) do |input, _|
        topic = input.fetch("topic")
        calls[topic] += 1
        Lain::Tool::Result.ok(bytes ? "#{topic}: #{"x" * bytes}" : "#{topic}: answer #{calls[topic]}")
      end
    end.new
  end

  def responses(topics)
    usage = Lain::Usage.new(input_tokens: 10, output_tokens: 5)
    lookups = topics.each_with_index.map do |topic, index|
      Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_#{index}", "name" => "ledger_lookup",
                                     "input" => { "topic" => topic } }],
                         stop_reason: :tool_use, model: "claude-haiku-5-5", usage:)
    end
    lookups + [Lain::Response.new(content: [{ "type" => "text", "text" => "done" }], stop_reason: :end_turn,
                                  model: "claude-haiku-5-5", usage:)]
  end
end
