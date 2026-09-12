# frozen_string_literal: true

# Pure path arithmetic between a source file and the test file a layout says
# holds its tests, at a level. Nothing here touches the filesystem: whether the
# mirrored source exists is the guard's question, not the mapping's.
RSpec.describe Lain::TestLayout::Mapping do
  def mapping(table) = described_class.new(Lain::TestLayout.from(table, path: nil))

  let(:rspec) { mapping({ "preset" => "rspec", "source_roots" => ["app"] }) }

  describe "#test_path" do
    it "mirrors a source relative to its source root, under the level's root" do
      expect(rspec.test_path("app/cli/backend.rb", level: "seam")).to eq("spec/seam/cli/backend_spec.rb")
    end

    it "mirrors against whichever of several source roots holds the source" do
      two = mapping({ "preset" => "rspec", "source_roots" => %w[app lib] })

      expect(two.test_path("lib/tasks/import.rb", level: "unit")).to eq("spec/unit/tasks/import_spec.rb")
    end

    it "names pytest's test file by prefix" do
      pytest = mapping({ "preset" => "pytest" })

      expect(pytest.test_path("src/shop/order.py", level: "unit")).to eq("tests/unit/shop/test_order.py")
    end

    it "names minitest's test file by suffix under test/" do
      expect(mapping({ "preset" => "minitest" }).test_path("lib/order.rb", level: "integration"))
        .to eq("test/integration/order_test.rb")
    end

    it "answers the source itself for a level whose tests are inline" do
      expect(mapping({ "preset" => "cargo" }).test_path("src/order.rs", level: "unit")).to eq("src/order.rs")
    end

    it "refuses to place a test at a level that mirrors no source" do
      expect { mapping({ "preset" => "cargo" }).test_path("src/order.rs", level: "integration") }
        .to raise_error(Lain::TestLayout::Unplaceable, /integration.*tests/)
    end

    it "refuses a source outside every source root, naming the roots" do
      expect { rspec.test_path("lib/order.rb", level: "unit") }
        .to raise_error(Lain::TestLayout::Unplaceable, %r{lib/order\.rb.*app})
    end

    it "refuses a level the layout does not declare, naming the ones it does" do
      expect { rspec.test_path("app/order.rb", level: "e2e") }
        .to raise_error(Lain::TestLayout::Unplaceable, /e2e.*unit, seam, integration/)
    end

    it "refuses every placement when no layout is in force" do
      expect { described_class.new(Lain::TestLayout::None).test_path("app/order.rb", level: "unit") }
        .to raise_error(Lain::TestLayout::Unplaceable, /no test layout/)
    end
  end

  describe "#sources_for" do
    it "reverses the mirror into one candidate per source root" do
      two = mapping({ "preset" => "rspec", "source_roots" => %w[app lib] })

      expect(two.sources_for("spec/unit/models/order_spec.rb")).to eq(%w[app/models/order.rb lib/models/order.rb])
    end

    it "has no candidates for a file outside every mirrored level root" do
      expect([rspec.sources_for("spec/support/helpers.rb"), rspec.sources_for("app/models/order.rb")])
        .to eq([[], []])
    end
  end

  describe "#level_of" do
    it "names the level whose root holds the path" do
      expect(rspec.level_of("spec/seam/models/order_spec.rb").name).to eq("seam")
    end

    it "is nil for a path under no level root, including one that merely shares a prefix" do
      expect([rspec.level_of("app/order.rb"), rspec.level_of("spec/unitary/order_spec.rb")]).to eq([nil, nil])
    end
  end

  # rspec collects `spec/**/*_spec.rb`, not just what sits under a level root,
  # so a test file anywhere in the test tree runs whether or not the layout
  # holds it.
  describe "#stray?" do
    it "is true for a test file in the test tree but under no level root" do
      expect([rspec.stray?("spec/order_extra_spec.rb"), rspec.stray?("spec/models/order_extra_spec.rb"),
              rspec.stray?("spec/support/order_extra_spec.rb")]).to eq([true, true, true])
    end

    it "is false under a level root, outside the test tree, or for a file that is not a test" do
      expect([rspec.stray?("spec/unit/models/order_spec.rb"), rspec.stray?("app/order_spec.rb"),
              rspec.stray?("spec/spec_helper.rb")]).to eq([false, false, false])
    end

    it "is false for cargo's integration tests, which sit in a level root of their own" do
      expect(mapping({ "preset" => "cargo" }).stray?("tests/order.rs")).to be(false)
    end
  end

  it "answers unit for a preset that mirrors, and nothing for cargo, which mirrors no level at all" do
    expect([rspec.default_level.name, mapping({ "preset" => "cargo" }).default_level]).to eq(["unit", nil])
  end

  # The order the author typed the keys in must not decide this: see
  # {Lain::TestLayout::AmbiguousDefaultLevel} for what rides the answer.
  it "answers unit wherever the table declares it, whichever key was typed first" do
    seam_first = mapping({ "preset" => "rspec", "level_roots" => { "seam" => "spec/seam", "unit" => "spec/unit" } })

    expect(seam_first.default_level.name).to eq("unit")
  end

  it "takes the table's declared default_level over the unit convention" do
    declared = mapping({ "preset" => "rspec", "default_level" => "seam" })

    expect(declared.default_level.name).to eq("seam")
  end

  it "takes the only mirrored level when the table declares exactly one" do
    lonely = mapping({ "preset" => "rspec", "level_roots" => { "e2e" => "spec/e2e" } })

    expect(lonely.default_level.name).to eq("e2e")
  end

  describe "#exempt? and #test_file?" do
    it "exempts by the declared path globs, never by content, across directories" do
      declared = mapping({ "preset" => "rspec", "exempt" => ["spec/support/**"] })

      expect([declared.exempt?("spec/support/deep/helper.rb"), declared.exempt?("spec/unit/order_spec.rb"),
              rspec.exempt?("spec/support/deep/helper.rb")]).to eq([true, false, false])
    end

    it "recognises a test file by the preset's naming rule" do
      pytest = mapping({ "preset" => "pytest" })

      expect([rspec.test_file?("spec/unit/order_spec.rb"), rspec.test_file?("spec/unit/_spec.rb"),
              pytest.test_file?("tests/unit/test_order.py"), pytest.test_file?("tests/unit/order.py")])
        .to eq([true, false, true, false])
    end
  end
end
