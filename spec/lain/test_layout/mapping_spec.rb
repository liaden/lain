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

    context "with a flat level, whose tests mirror no source file" do
      let(:workspace) { mapping({ "preset" => "cargo", "source_roots" => %w[src crates/store/src] }) }

      it "names the test file for the caller, under the flat root of the subject's own package" do
        expect(workspace.test_path("crates/store/src/lib.rs", level: "integration", name: "store-crate"))
          .to eq("crates/store/tests/store-crate.rs")
      end

      it "puts a subject under a top-level source root in the flat root at the project top" do
        expect(workspace.test_path("src/order.rs", level: "integration", name: "orders"))
          .to eq("tests/orders.rs")
      end

      it "refuses a placement given no name, saying why one is needed" do
        expect { workspace.test_path("src/order.rs", level: "integration") }
          .to raise_error(Lain::TestLayout::Unplaceable, /integration.*tests.*name/)
      end
    end

    it "lists the flat root in each source root's package among the test trees" do
      workspace = mapping({ "preset" => "cargo", "source_roots" => %w[src crates/store/src] })

      expect([workspace.test_trees, rspec.test_trees]).to eq([%w[tests crates/store/tests], %w[spec]])
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

  describe "#package_dir" do
    let(:workspace) { mapping({ "preset" => "cargo", "source_roots" => %w[crates/store/src crates/asr/src] }) }

    it "names the directory above the source root holding the path, deepest first" do
      expect(workspace.package_dir("crates/store/tests/x.rs")).to eq("crates/store")
    end

    it "is nil for a path in no source root's package" do
      expect(workspace.package_dir("crates/other/tests/x.rs")).to be_nil
    end

    it "is nil for a workspace path when only a top-level source root is declared" do
      expect(mapping({ "preset" => "cargo" }).package_dir("crates/store/tests/x.rs")).to be_nil
    end

    it "is nil for a path under a package but outside its source and level roots" do
      expect(workspace.package_dir("crates/store/benches/x.rs")).to be_nil
    end

    it "gives a package under a top-level one its own directory, and the top its own" do
      nested = mapping({ "preset" => "cargo", "source_roots" => %w[src crates/a/src] })

      expect(%w[crates/a/tests/x.rs crates/a/src/y.rs tests/x.rs src/z.rs].map { |path| nested.package_dir(path) })
        .to eq(%w[crates/a crates/a . .])
    end

    it "prefers the deepest place when a shallower package's test root also holds the path" do
      overlapping = mapping({ "preset" => "cargo", "source_roots" => %w[a/src a/tests/z/src] })

      expect(overlapping.package_dir("a/tests/z/src/x.rs")).to eq("a/tests/z")
    end

    it "is the project top for a source root at the top" do
      expect(mapping({ "preset" => "cargo" }).package_dir("tests/x.rs")).to eq(".")
    end
  end

  describe "#level_of" do
    it "names the level whose root holds the path" do
      expect(rspec.level_of("spec/seam/models/order_spec.rb").name).to eq("seam")
    end

    context "with a flat level in a workspace of packages" do
      let(:workspace) { mapping({ "preset" => "cargo", "source_roots" => %w[crates/store/src crates/asr/src] }) }

      it "answers the level test_path placed a package's test at" do
        placed = workspace.test_path("crates/store/src/lib.rs", level: "integration", name: "store-crate")

        expect([placed, workspace.level_of(placed)&.name]).to eq(["crates/store/tests/store-crate.rs", "integration"])
      end

      it "answers the level for every package's own flat root, and nil for another package's lookalike" do
        expect([workspace.level_of("crates/asr/tests/x.rs")&.name, workspace.level_of("crates/other/tests/x.rs")])
          .to eq(["integration", nil])
      end
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

  it "answers the unit level for a preset that mirrors, and the inline unit level for cargo" do
    expect([rspec.default_level.name, mapping({ "preset" => "cargo" }).default_level])
      .to eq(["unit", Lain::TestLayout::Mapping::Level.new(name: "unit", root: "inline", shape: :inline)])
  end

  it "places a cargo subject's tests in the subject itself through the default level" do
    cargo = mapping({ "preset" => "cargo" })

    expect(cargo.test_path("src/meeting.rs", level: cargo.default_level.name)).to eq("src/meeting.rs")
  end

  it "answers the inline level for a cargo layout that declares default_level unit" do
    declared = mapping({ "preset" => "cargo", "default_level" => "unit" })

    expect(declared.default_level.shape).to eq(:inline)
  end

  # The order the author typed the keys in must not decide this: see
  # {Lain::TestLayout.settled!} for what rides the answer.
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
