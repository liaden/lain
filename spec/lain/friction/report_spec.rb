# frozen_string_literal: true

# The friction-observer's deterministic core, for the lain USER. Folds
# Grader::FrustrationRepair, Grader::ToolSteering, and Bench::Rewrites over
# one session Journal and renders each detected signal beside the knob that
# addresses it -- no model call, so the render is byte-identical across runs.
#
# The fixtures below are committed NDJSON, the same on-disk shape a real
# session writes (spec/fixtures/grader/*'s convention) -- built by hand from
# ToolCallIndex/FrustrationRepair/ToolSteering's own specs (their "digest"/
# "parent"/"meta" fields are read directly, never re-verified as a Merkle
# chain, so hand-picked digest strings are exactly as valid as real
# content-addressed ones for these graders).
#
# The "session whose payments name an ollama model" section below
# characterizes what this class already does over a session priced on an arm
# {Lain::PriceBook::DEFAULT} has no row for -- Ollama Cloud is metered by
# subscription quota, not per-token dollars, and the report must neither
# fabricate a figure nor crash trying to produce one. Both halves turned out
# to already be true: {Friction::CacheWaste} rescues {PriceBook::UnknownModel}
# per model (`cache_waste.rb:502`) and
# {Friction::Report::CacheWasteSection#figure_phrase} withholds a figure with
# nothing priceable behind it (`report.rb:317-335`) rather than printing a
# confident `$0.000000`.
RSpec.describe Lain::Friction::Report do
  def fixture(name)
    File.foreach(File.join(__dir__, "..", "..", "fixtures", "friction", "#{name}.ndjson"))
  end

  describe "a frustrating session (rephrase loop on bash, steering flag on grep)" do
    subject(:report) { described_class.new(fixture("frustrating")) }

    it "names the rephrase-loop signal with its turn digest and the tier-3 knob line" do
      rendered = report.render

      expect(rendered).to include("rephrase_loop")
      expect(rendered).to include("d-t8") # the turn that issued the retried bash call
      expect(rendered).to include("d-t4") # caused_by: the turn that issued the errored call
      expect(rendered).to include("bash")
      expect(rendered).to include("approval queue timeout")
    end

    it "names the tool-steering signal on grep with its knob line" do
      rendered = report.render

      expect(rendered).to include("tool_steering")
      expect(rendered).to include("grep")
      expect(rendered).to include("2.1") # observed/declared ratio, ~2.1x
      expect(rendered).to include("rewrite this tool's description")
    end

    it "does not flag bash or read_file for steering (proportionate selection)" do
      rendered = report.render

      expect(rendered).not_to include("tool_steering: bash")
      expect(rendered).not_to include("tool_steering: read_file")
    end

    it "counts exactly two signals" do
      expect(report.render).to start_with("2 friction signal(s):")
    end

    it "renders byte-identical output across repeated calls" do
      expect(described_class.new(fixture("frustrating")).render)
        .to eq(described_class.new(fixture("frustrating")).render)
    end

    # NullOracle::INSTANCE is frozen (deeply-frozen value object doctrine), so
    # it cannot be a message-expectation double -- reading the ivar directly
    # pins "never anything but Null by default" without needing a live
    # provider or a mock that a frozen singleton would reject.
    it "never touches a provider -- the injected oracle stays Null by default" do
      expect(report.instance_variable_get(:@oracle)).to be(Lain::Grader::FrustrationRepair::NullOracle.instance)
    end
  end

  describe "a clean session" do
    subject(:report) { described_class.new(fixture("clean")) }

    it "states no friction was found" do
      expect(report.render).to include("no friction found")
    end

    it "lists the analyzers that ran" do
      rendered = report.render

      expect(rendered).to include("Grader::FrustrationRepair")
      expect(rendered).to include("Grader::ToolSteering")
      expect(rendered).to include("Bench::Rewrites")
    end

    it "renders byte-identical output across repeated calls" do
      expect(described_class.new(fixture("clean")).render)
        .to eq(described_class.new(fixture("clean")).render)
    end
  end

  # One report, one projection. FrustrationRepair and ToolSteering read the
  # SAME ToolCallIndex over the same records, so the Report builds it once and
  # injects it -- three parses of one in-memory array was the defect.
  describe "one render builds one ToolCallIndex" do
    it "builds exactly one index across a render that finds both grader signals" do
      allow(Lain::Grader::ToolCallIndex).to receive(:new).and_call_original

      described_class.new(fixture("frustrating")).render

      expect(Lain::Grader::ToolCallIndex).to have_received(:new).once
    end

    it "renders the same report as it did when each grader parsed the records itself" do
      report = described_class.new(fixture("frustrating")).render

      expect(report).to start_with("2 friction signal(s):")
      expect(report).to include("rephrase_loop", "bash", "tool_steering: grep")
    end
  end

  describe "entries given as an already-materialized Array (the Journal.records duck)" do
    it "works the same as a lazy File.foreach enumerator" do
      entries = Lain::Journal.records(fixture("frustrating")).to_a

      expect(described_class.new(entries).render).to eq(described_class.new(fixture("frustrating")).render)
    end
  end

  # CACHE_REWRITE_THRESHOLD is a strictly-greater-than bound, the same
  # convention Grader::ToolSteering::DEFAULT_THRESHOLD documents ("selected
  # more than double" -- exactly double does not flag). N request_sent
  # records with a shared position but a fresh digest each time produce
  # exactly N-1 rewrites (one per consecutive pair); no turn/session records
  # are needed, so FrustrationRepair/ToolSteering both find nothing and this
  # isolates the boundary to Bench::Rewrites alone.
  describe "the cache-rewrite count is a strictly-greater-than threshold (boundary)" do
    def request_sent_chain(digests)
      digests.map do |digest|
        { "type" => "request_sent", "prefix_chain_version" => 1,
          "prefix_digests" => [[0, digest]] }
      end
    end

    it "renders no cache_rewrites line at exactly the threshold (3 rewrites)" do
      entries = request_sent_chain(%w[a b c d]) # 4 records -> 3 consecutive rewrites

      expect(described_class.new(entries).render).not_to include("cache_rewrites")
    end

    it "renders the cache_rewrites line one past the threshold (4 rewrites)" do
      entries = request_sent_chain(%w[a b c d e]) # 5 records -> 4 consecutive rewrites

      rendered = described_class.new(entries).render

      expect(rendered).to include("cache_rewrites: 4 prefix rewrites detected")
      expect(rendered).to include("compaction scheduling knobs")
    end
  end

  # The round-8 ollama report printed `4 prefix rewrites detected` and,
  # two lines later, `none -- no prefix break was re-billed`. Both true: the
  # rewrite line reads `request_sent` prefix chains and nothing else, while the
  # waste line multiplies those same breaks by the cache-creation tokens the next
  # call was BILLED. Neither said which question it had answered, so the pair read
  # as a contradiction. Reconciled by saying what each measured -- NOT by making
  # the counts agree: the rewrite line is unsegmented and the waste line is per
  # model, so across a `/model` switch they legitimately differ.
  describe "the two cache lines, when one fires and the other reports nothing" do
    def request_sent(digest)
      { "type" => "request_sent", "digest" => "blake3:req", "payload" => { "model" => "claude-opus-4-8" },
        "prefix_chain_version" => 1, "prefix_digests" => [[0, digest]] }
    end

    def turn_usage(read:)
      { "type" => "turn_usage", "digest" => "blake3:turn", "model" => "claude-opus-4-8",
        "usage" => { "input_tokens" => 10, "output_tokens" => 10,
                     "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => read } }
    end

    # 5 chains -> 4 rewrites, one past CACHE_REWRITE_THRESHOLD, and every call
    # billed zero cache creation, so nothing is attributable as waste.
    subject(:rendered) { described_class.new(entries).render }

    let(:entries) do
      %w[a b c d e].flat_map { |digest| [request_sent(digest), turn_usage(read: 50_000)] }
    end

    it "still reports the rewrite count and still reports nothing re-billed" do
      expect(rendered).to include("cache_rewrites: 4 prefix rewrites detected")
      expect(rendered).to include("cache_waste: none -- no prefix break was re-billed")
    end

    it "says what the rewrite line measured" do
      expect(rendered).to include("prefix chains that diverged")
    end

    it "says what the waste line measured" do
      expect(rendered).to include("cache-creation tokens billed")
    end
  end

  def request_sent(digest, model)
    { "type" => "request_sent", "digest" => "blake3:req", "payload" => { "model" => model },
      "prefix_chain_version" => 1, "prefix_digests" => [[0, digest]] }
  end

  def turn_usage(model, read: 0, create: 0)
    { "type" => "turn_usage", "digest" => "blake3:turn", "model" => model,
      "usage" => { "input_tokens" => 10, "output_tokens" => 10,
                   "cache_creation_input_tokens" => create, "cache_read_input_tokens" => read } }
  end

  # A prefix break followed by a re-billed cache-creation write and a
  # served cache-read, both against a model PriceBook::DEFAULT has no row for
  # -- the shape that would otherwise raise UnknownModel mid-render.
  describe "a session whose payments name an ollama model" do
    subject(:rendered) { described_class.new(entries).render }

    let(:model) { "qwen3:4b" }
    let(:entries) do
      [request_sent("a", model), turn_usage(model),
       request_sent("b", model), turn_usage(model, read: 5_000, create: 2_000)]
    end

    it "does not raise" do
      expect { rendered }.not_to raise_error
    end

    it "states token figures" do
      expect(rendered).to include("2000 tokens re-billed")
      expect(rendered).to include("5000 tokens served from cache")
    end

    it "states no dollar figure" do
      expect(rendered).not_to include("$")
    end

    it "says which model the withheld figures exclude" do
      expect(rendered).to include("dollar figures exclude qwen3:4b -- no price recorded")
    end
  end
end
