# frozen_string_literal: true

# A project's test layout as data: a preset names the framework's shape, and a
# `[tests]` table may override where sources live, where each level's tests
# live, and which paths are exempt. The table RESTRICTS writes, so a typo in it
# is refused rather than silently leaving no layout in force.
RSpec.describe Lain::TestLayout do
  let(:config) { "/project/.lain/config.toml" }

  def refusal(table)
    described_class.from(table, path: config)
  rescue Lain::Error => e
    e
  end

  describe "the rspec preset, mirrored relative to a declared source root" do
    it "mirrors app/models/order.rb to spec/unit/models/order_spec.rb" do
      layout = described_class.from({ "preset" => "rspec", "source_roots" => ["app"] }, path: config)

      expect(layout.mapping.test_path("app/models/order.rb", level: "unit")).to eq("spec/unit/models/order_spec.rb")
    end

    it "refuses a misspelt key, naming the key and the file" do
      expect { described_class.from({ "prest" => "rspec" }, path: config) }
        .to raise_error(described_class::UnknownKeys, /#{Regexp.escape(config)}.*"prest"/)
    end

    # Exemption is always the project's own declaration: support and fixture
    # files are not test-named, so they need none, and a test-named file there
    # is collected by the runner like any other.
    it "keeps the preset's defaults for every key the table does not override, exempting nothing" do
      layout = described_class.from({ "preset" => "rspec", "source_roots" => ["app"] }, path: config)

      expect([layout.level_roots, layout.exempt])
        .to eq([{ "unit" => "spec/unit", "seam" => "spec/seam", "integration" => "spec/integration" }, []])
    end

    it "takes the level roots and the exemptions the table names" do
      layout = described_class.from({ "preset" => "rspec", "level_roots" => { "unit" => "spec/fast" },
                                      "exempt" => ["spec/spikes/**"] }, path: config)

      expect([layout.source_roots, layout.level_roots, layout.exempt])
        .to eq([["lib"], { "unit" => "spec/fast" }, ["spec/spikes/**"]])
    end
  end

  describe "with no table" do
    it "is TestLayout::None when no framework was detected either" do
      expect(described_class.from(nil, path: config)).to be(described_class::None)
    end

    it "takes a detected framework's preset" do
      layout = described_class.from(nil, path: config, framework: "rspec")

      expect([layout.preset.name, layout.source_roots]).to eq(["rspec", ["lib"]])
    end

    it "is TestLayout::None for a detected framework it has no preset for" do
      expect(described_class.from(nil, path: config, framework: "jest")).to be(described_class::None)
    end

    it "lets a table's preset win over the detected framework" do
      layout = described_class.from({ "preset" => "minitest" }, path: config, framework: "rspec")

      expect(layout.preset.name).to eq("minitest")
    end
  end

  describe "TestLayout::None" do
    it "is not in force, and a declared layout is" do
      declared = described_class.from({ "preset" => "rspec" }, path: config)

      expect([described_class::None.in_force?, declared.in_force?]).to eq([false, true])
    end

    it "guards no level, so nothing under it is a mirrored test path" do
      expect(described_class::None.mapping.levels).to be_empty
    end
  end

  describe "the presets" do
    it "ships rspec, minitest, pytest and cargo" do
      expect(described_class::PRESETS.keys).to match_array(%w[rspec minitest pytest cargo])
    end

    it "keeps cargo's unit tests inline and its integration tests under tests/" do
      layout = described_class.preset("cargo")

      expect(layout.level_roots).to eq({ "unit" => "inline", "integration" => "tests" })
    end
  end

  describe "a malformed table is refused by name" do
    it "refuses a scalar where the table belongs" do
      expect(refusal("rspec")).to be_a(described_class::NotATable).and(have_attributes(message: /#{config}.*\[tests\]/))
    end

    it "refuses a table that names no preset" do
      expect(refusal({ "source_roots" => ["app"] })).to be_a(described_class::MissingPreset)
    end

    it "refuses a preset it does not ship, naming the ones it does" do
      expect(refusal({ "preset" => "jest" }).message)
        .to include('preset = "jest" is not one of cargo, minitest, pytest, rspec')
    end

    it "refuses a source root that is not a list of relative paths" do
      rspec = { "preset" => "rspec" }
      bad = [{ "source_roots" => "app" }, { "source_roots" => ["/abs"] }, { "source_roots" => ["../up"] },
             { "source_roots" => [] }]

      expect(bad.map { |extra| refusal(rspec.merge(extra)) })
        .to all(be_a(described_class::InvalidValue).and(have_attributes(key: "source_roots")))
    end

    it "refuses level roots that are not a table of level names to relative paths" do
      rspec = { "preset" => "rspec" }
      bad = [{ "level_roots" => ["spec/unit"] }, { "level_roots" => { "Unit" => "spec/unit" } },
             { "level_roots" => { "unit" => "/spec" } }, { "level_roots" => {} }]

      expect(bad.map { |extra| refusal(rspec.merge(extra)) })
        .to all(be_a(described_class::InvalidValue).and(have_attributes(key: "level_roots")))
    end

    it "refuses exemptions that are not a list of relative paths" do
      expect(refusal({ "preset" => "rspec", "exempt" => "spec/support" }))
        .to be_a(described_class::InvalidValue).and(have_attributes(key: "exempt"))
    end

    it "is one family, so a caller can rescue every refusal at once" do
      refusals = [refusal("rspec"), refusal({ "prest" => 1 }), refusal({}), refusal({ "preset" => "jest" })]

      expect(refusals).to all(be_a(described_class::Refusal))
    end
  end

  # A path spelled two ways is two paths to a prefix match, so a
  # non-canonical root would mirror some files and silently miss others.
  describe "non-canonical and overlapping paths are refused" do
    it "refuses a source root spelled with a dot, a doubled slash or a trailing slash" do
      bad = [["."], ["./app"], ["app//models"], ["app/"]]

      expect(bad.map { |roots| refusal({ "preset" => "rspec", "source_roots" => roots }) })
        .to all(be_a(described_class::InvalidValue).and(have_attributes(key: "source_roots")))
    end

    it "refuses two levels sharing a root, or one level's root inside another's" do
      bad = [{ "unit" => "spec", "seam" => "spec" }, { "unit" => "spec", "seam" => "spec/seam" }]

      expect(bad.map { |levels| refusal({ "preset" => "rspec", "level_roots" => levels }) })
        .to all(be_a(described_class::InvalidValue).and(have_attributes(key: "level_roots")))
    end

    it "refuses one source root inside another, which would mirror one source to two test paths" do
      expect(refusal({ "preset" => "rspec", "source_roots" => %w[app app/models] }))
        .to be_a(described_class::InvalidValue).and(have_attributes(key: "source_roots"))
    end

    it "names the overlapping pair" do
      expect([refusal({ "preset" => "rspec", "source_roots" => %w[lib app app/models] }).message,
              refusal({ "preset" => "rspec", "level_roots" => { "unit" => "spec", "seam" => "spec/seam" } }).message])
        .to match([/app and app.models overlap/, /spec and spec.seam overlap/])
    end

    it "refuses a non-canonical exemption" do
      expect(refusal({ "preset" => "rspec", "exempt" => ["./spec/support/**"] }))
        .to be_a(described_class::InvalidValue).and(have_attributes(key: "exempt"))
    end
  end

  describe "an inline level" do
    it "is refused for a preset whose levels mirror, since its tests would have nowhere to go" do
      table = { "preset" => "rspec", "level_roots" => { "unit" => "spec/unit", "integration" => "inline" } }

      expect(refusal(table)).to be_a(described_class::InvalidValue).and(have_attributes(message: /inline/))
    end

    it "is accepted for cargo" do
      layout = described_class.from({ "preset" => "cargo", "level_roots" => { "unit" => "inline" } }, path: config)

      expect(layout.level_roots).to eq({ "unit" => "inline" })
    end
  end

  it "exposes the presets and the refusals, and keeps the reader's rules to itself" do
    hidden = %i[RULES KEYS PRESET Paths Levels OneOf]

    expect([described_class.constants & hidden, %i[relative? located levels_under].select do |name|
      described_class.respond_to?(name)
    end]).to eq([[], []])
  end

  describe "as a value" do
    it "is deeply frozen, whether loaded or the Null" do
      layout = described_class.from({ "preset" => "pytest", "source_roots" => [+"src"] }, path: config)

      expect([layout, described_class::None]).to all(be_deeply_frozen)
    end

    it "does not share a string the caller still holds" do
      root = +"app"
      layout = described_class.from({ "preset" => "rspec", "source_roots" => [root] }, path: config)
      root << "s"

      expect(layout.source_roots).to eq(["app"])
    end
  end
end
