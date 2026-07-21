# frozen_string_literal: true

# M1: the friction-observer's deterministic core, for the lain USER. Folds
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
RSpec.describe Lain::Friction::Report do
  def fixture(name)
    File.foreach(File.join(__dir__, "..", "fixtures", "friction", "#{name}.ndjson"))
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

      expect(rendered).not_to match(/tool_steering: bash/)
      expect(rendered).not_to match(/tool_steering: read_file/)
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
end

RSpec.describe Lain::CLI::Friction do
  let(:tmpdir) { Dir.mktmpdir }
  let(:sessions_dir) { File.join(tmpdir, "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:paths) { instance_double(Lain::Paths, sessions_dir:) }

  before do
    fixture_path = File.join(__dir__, "..", "fixtures", "friction", "clean.ndjson")
    FileUtils.cp(fixture_path, File.join(sessions_dir, "20260721T000000-1.ndjson"))
  end

  after { FileUtils.remove_entry(tmpdir) }

  subject(:cli) { described_class.new(paths:) }

  it "resolves a bare filename under this project's session dir and renders the report" do
    expect(cli.report_for("20260721T000000-1.ndjson")).to include("no friction found")
  end

  it "resolves a filename missing its .ndjson suffix" do
    expect(cli.report_for("20260721T000000-1")).to include("no friction found")
  end

  it "resolves an explicit path directly" do
    explicit = File.join(sessions_dir, "20260721T000000-1.ndjson")

    expect(cli.report_for(explicit)).to include("no friction found")
  end

  it "raises SessionNotFound, naming what it looked at, for an unresolvable selector" do
    expect { cli.report_for("does-not-exist") }.to raise_error(described_class::SessionNotFound, /does-not-exist/)
  end
end
