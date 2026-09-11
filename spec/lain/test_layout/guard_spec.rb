# frozen_string_literal: true

require "tmpdir"

# The mirror guard, over the layout_mini fixture: a test file under a mirrored
# level root describes a constant, that constant is defined in the source file
# the test mirrors, that file exists, and any level tag agrees with the root.
# A refusal names the path the file should occupy, found by looking up where
# the constant is defined and mirroring THAT file.
RSpec.describe Lain::TestLayout::Guard do
  let(:layout_mini) { File.expand_path("../../fixtures/projects/layout_mini", __dir__) }
  let(:guard) { guard_over(layout_mini) }

  def guard_over(root) = described_class.new(layout: Lain::Config.test_layout(root:), root:)

  # Callers set policy per rule, and a record names the rule it refused under,
  # so the guard publishes the list rather than leave each reader a copy.
  describe "the rules it refuses under" do
    it "publishes them, frozen" do
      expect(described_class::REFUSING).to be_frozen
      expect(described_class::REFUSING).to include(:stray, :no_source, :elsewhere, :ambiguous, :missing)
    end

    it "names none that a passing or unguarded verdict carries" do
      expect(described_class::REFUSING & %i[mirrors exempt no_layout not_a_test unmirrored outside]).to be_empty
    end

    it "refuses only under a rule it publishes" do
      with_copy do |root|
        verdicts = [guard_over(root).check("spec/unit/models/order_extra_spec.rb", spec_for("Order")),
                    guard_over(root).check("spec/order_extra_spec.rb", spec_for("Order")),
                    guard_over(root).check_file("spec/unit/models/nothing_spec.rb")]

        expect(verdicts.map(&:rule)).to all(satisfy { |rule| described_class::REFUSING.include?(rule) })
      end
    end
  end

  def spec_for(constant, *tags)
    metadata = tags.map { |tag| ", #{tag}" }.join
    "RSpec.describe #{constant}#{metadata} do\n  it(\"works\") { expect(1).to eq(1) }\nend\n"
  end

  def with_copy
    Dir.mktmpdir do |root|
      FileUtils.cp_r(File.join(layout_mini, "."), root)
      yield root
    end
  end

  it "passes a unit test at the mirror path" do
    verdict = guard.check("spec/unit/models/order_spec.rb", spec_for("Order"))

    expect(verdict).to have_attributes(outcome: :passed, rule: :mirrors, refused?: false)
  end

  describe "a split sibling" do
    it "is refused, naming the right path" do
      verdict = guard.check("spec/unit/models/order_extra_spec.rb", spec_for("Order"))

      expect([verdict.rule, verdict.expected]).to eq([:elsewhere, "spec/unit/models/order_spec.rb"])
    end

    it "says the source it would mirror does not exist" do
      reason = guard.check("spec/unit/models/order_extra_spec.rb", spec_for("Order")).reason

      expect(reason).to include("app/models/order_extra.rb", "spec/unit/models/order_spec.rb")
    end
  end

  # rspec and parallel_rspec collect `spec/**/*_spec.rb`, so moving a refused
  # sibling out from under the level roots would otherwise escape the guard
  # while still running in the suite.
  describe "a stray test file, in the test tree but under no level root" do
    it "is refused, naming the right path at the default level, however far up it moved" do
      verdicts = ["spec/order_extra_spec.rb", "spec/models/order_extra_spec.rb", "spec/support/order_extra_spec.rb"]
                 .map { |path| guard.check(path, spec_for("Order")) }

      expect(verdicts.map { |verdict| [verdict.rule, verdict.expected] })
        .to all(eq([:stray, "spec/unit/models/order_spec.rb"]))
    end

    it "takes its level from a tag when it has one" do
      expect(guard.check("spec/order_extra_spec.rb", spec_for("Order", ":seam")).expected)
        .to eq("spec/seam/models/order_spec.rb")
    end

    it "is refused by the path rules alone, naming no path" do
      expect(guard.check_path("spec/models/order_extra_spec.rb")).to have_attributes(rule: :stray, expected: nil)
    end

    it "stays exempt where the project declared the exemption itself" do
      layout = Lain::TestLayout.from({ "preset" => "rspec", "source_roots" => ["app"],
                                       "exempt" => ["spec/*_discipline_spec.rb"] }, path: nil)
      exempting = described_class.new(layout:, root: layout_mini)

      expect(exempting.check("spec/output_discipline_spec.rb", "RSpec.describe \"x\" do\nend\n").rule).to eq(:exempt)
    end
  end

  describe "differently-named files and acronym namespaces" do
    it "passes a spec describing a constant its mirrored file defines under another name" do
      expect(guard.check("spec/unit/models/records_spec.rb", spec_for("OrderTransition")).outcome).to eq(:passed)
    end

    it "passes CLI::Backend at spec/unit/cli/backend_spec.rb" do
      expect(guard.check("spec/unit/cli/backend_spec.rb", spec_for("CLI::Backend")).outcome).to eq(:passed)
    end

    it "passes two subjects that both live in the file it mirrors" do
      two = "RSpec.describe OrderTransition do\nend\nRSpec.describe OrderRecord do\nend\n"

      expect(guard.check("spec/unit/models/records_spec.rb", two).outcome).to eq(:passed)
    end
  end

  describe "a level tag" do
    it "refuses a seam tag under the unit root, naming the seam path" do
      verdict = guard.check("spec/unit/models/order_spec.rb", spec_for("Order", ":seam"))

      expect([verdict.rule, verdict.expected]).to eq([:level, "spec/seam/models/order_spec.rb"])
    end

    it "reads a keyword tag and one on a nested example, not just the describe's own symbols" do
      nested = "RSpec.describe Order do\n  it \"is slow\", seam: true do\n  end\nend\n"

      expect([guard.check("spec/unit/models/order_spec.rb", spec_for("Order", "seam: true")).expected,
              guard.check("spec/unit/models/order_spec.rb", nested).expected])
        .to eq(%w[spec/seam/models/order_spec.rb spec/seam/models/order_spec.rb])
    end

    it "passes a tag that agrees with the root, and metadata that names no level" do
      expect([guard.check("spec/seam/models/order_spec.rb", spec_for("Order", ":seam")).outcome,
              guard.check("spec/unit/models/order_spec.rb", spec_for("Order", "type: :model")).outcome])
        .to eq(%i[passed passed])
    end
  end

  # One test file cannot mirror two sources, nor sit under two roots, so no
  # path it could move to would pass. Naming one would send the model in a
  # circle between two refusals.
  describe "an ambiguous file" do
    it "refuses subjects defined in different files, naming no path" do
      two = "RSpec.describe Order do\nend\nRSpec.describe OrderRecord do\nend\n"
      verdicts = %w[spec/unit/models/order_spec.rb spec/unit/models/records_spec.rb]
                 .map { |path| guard.check(path, two) }

      expect(verdicts.map { |verdict| [verdict.rule, verdict.expected] }).to all(eq([:ambiguous, nil]))
      expect(verdicts.first.reason).to include("app/models/order.rb", "app/models/records.rb")
    end

    it "refuses tags naming two levels other than its root, naming no path" do
      tags = "RSpec.describe Order, :seam do\n  it(\"x\", :integration) { }\nend\n"

      expect(guard.check("spec/unit/models/order_spec.rb", tags))
        .to have_attributes(rule: :ambiguous, expected: nil, reason: /seam.*integration/)
    end
  end

  it "reports a mirrored source that could not be parsed" do
    with_copy do |root|
      File.write(File.join(root, "app/models/broken.rb"), "class Broken\n  def oops(\n")

      verdict = guard_over(root).check("spec/unit/models/broken_spec.rb", spec_for("Broken"))

      expect([verdict.rule, verdict.reason])
        .to match([:source_unparseable, %r{app/models/broken\.rb could not be parsed}])
    end
  end

  describe "the describe itself" do
    it "refuses a top-level describe that names a string, not a constant" do
      verdict = guard.check("spec/unit/models/order_spec.rb", spec_for('"Order"'))

      expect([verdict.rule, verdict.reason]).to match([:not_a_constant, /constant/])
    end

    it "refuses a file with no top-level describe" do
      expect(guard.check("spec/unit/models/order_spec.rb", "# frozen_string_literal: true\n"))
        .to have_attributes(rule: :no_describe, reason: /no top-level describe/)
    end

    it "reads ::RSpec.describe as a describe" do
      expect(guard.check("spec/unit/models/order_spec.rb", "::RSpec.describe Order do\nend\n").outcome).to eq(:passed)
    end

    it "refuses test content that does not parse" do
      expect(guard.check("spec/unit/models/order_spec.rb", "RSpec.describe Order do\n"))
        .to have_attributes(rule: :unparseable, reason: /spec.unit.models.order_spec\.rb could not be parsed/)
    end

    # The machine-readable rule is what lets a write-time caller let a test
    # written before its class through, while a land-time caller refuses it.
    it "refuses a constant no source defines as :no_source, naming the missing mirror and no path" do
      verdict = guard.check("spec/unit/models/refund_spec.rb", spec_for("Refund"))

      expect([verdict.rule, verdict.expected]).to eq([:no_source, nil])
      expect(verdict.reason).to include("no Ruby file under app defines Refund", "app/models/refund.rb")
    end
  end

  describe "what it does not guard" do
    it "leaves alone a file that is not a test, whether in the test tree or under a root" do
      rules = ["spec/spec_helper.rb", "spec/support/matchers.rb", "spec/unit/models/helpers.rb"]
              .map { |path| guard.check(path, "puts 1\n").rule }

      expect(rules).to eq(%i[not_a_test not_a_test not_a_test])
    end

    it "guards nothing when no layout is in force" do
      unguarded = described_class.new(layout: Lain::TestLayout::None, root: layout_mini)

      expect(unguarded.check("spec/unit/models/order_extra_spec.rb", spec_for("Order")))
        .to have_attributes(outcome: :unguarded, rule: :no_layout)
    end

    it "reads an absolute path inside the root as its relative form, and ignores one outside it" do
      inside = guard.check(File.join(layout_mini, "spec/unit/models/order_extra_spec.rb"), spec_for("Order"))
      outside = guard.check("/elsewhere/spec/unit/models/order_extra_spec.rb", spec_for("Order"))

      expect([inside.path, inside.refused?, outside.outcome, outside.rule])
        .to eq(["spec/unit/models/order_extra_spec.rb", true, :unguarded, :outside])
    end

    it "resolves a symlinked root, so both the link and the real path reach the guard" do
      Dir.mktmpdir do |dir|
        link = File.join(dir, "link")
        File.symlink(layout_mini, link)
        linked = guard_over(link)
        paths = [File.join(File.realpath(layout_mini), "spec/unit/models/order_extra_spec.rb"),
                 File.join(link, "spec/unit/models/order_extra_spec.rb")]

        expect(paths.map { |path| linked.check(path, spec_for("Order")).rule }).to eq(%i[elsewhere elsewhere])
      end
    end
  end

  describe "#check_path, for a write whose content is not known" do
    it "holds the path to an existing mirror, and calls a missing one :no_source" do
      expect([guard.check_path("spec/unit/models/order_spec.rb").outcome,
              guard.check_path("spec/unit/models/order_extra_spec.rb").rule]).to eq(%i[passed no_source])
    end
  end

  describe "#check_file, for a test already on disk" do
    it "reads the file from the root, and refuses one that is not there" do
      with_copy do |root|
        path = File.join(root, "spec/unit/models/order_spec.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, spec_for("Order"))
        on_disk = guard_over(root)

        expect([on_disk.check_file("spec/unit/models/order_spec.rb").rule,
                on_disk.check_file("spec/unit/models/records_spec.rb").rule]).to eq(%i[mirrors missing])
      end
    end
  end

  it "checks only that the mirror exists under a preset that describes no constant" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "src/shop"))
      File.write(File.join(root, "src/shop/order.py"), "class Order: pass\n")
      pytest = described_class.new(layout: Lain::TestLayout.preset("pytest"), root:)

      expect([pytest.check("tests/unit/shop/test_order.py", "def test_x(): pass\n").outcome,
              pytest.check("tests/unit/shop/test_refund.py", "def test_x(): pass\n").reason])
        .to match([:passed, %r{src/shop/refund\.py}])
    end
  end

  it "hands back a deeply frozen verdict" do
    expect(guard.check("spec/unit/models/order_extra_spec.rb", spec_for("Order"))).to be_deeply_frozen
  end

  # The property the model relies on: following a refusal's advice ends the
  # refusals. A path named by `expected` must pass the same content.
  describe "a refusal never names a path the guard would itself refuse" do
    def unsound(guard, cases)
      cases.map { |path, content| [guard.check(path, content), content] }
           .select { |verdict, _content| verdict.expected }
           .select { |verdict, content| guard.check(verdict.expected, content).refused? }
           .map { |verdict, _content| "#{verdict.path} -> #{verdict.expected}: #{verdict.reason}" }
    end

    def advised(guard, cases) = cases.count { |path, content| guard.check(path, content).expected }

    it "holds over every path and content shape the fixture can be written with" do
      paths = %w[spec/unit/models/order_spec.rb spec/unit/models/order_extra_spec.rb spec/seam/models/order_spec.rb
                 spec/order_extra_spec.rb spec/models/order_extra_spec.rb spec/support/order_extra_spec.rb
                 spec/unit/models/records_spec.rb spec/unit/cli/backend_spec.rb spec/unit/c_l_i/backend_spec.rb]
      contents = [spec_for("Order"), spec_for("Order", ":seam"), spec_for("Order", ":seam", ":integration"),
                  "RSpec.describe Order, :seam do\n  it(\"x\", :integration) { }\nend\n",
                  "RSpec.describe Order do\nend\nRSpec.describe OrderRecord do\nend\n",
                  "RSpec.describe OrderTransition do\nend\nRSpec.describe OrderRecord do\nend\n",
                  spec_for("CLI::Backend"), spec_for("Refund")]
      cases = paths.product(contents)

      expect([unsound(guard, cases), advised(guard, cases).positive?]).to eq([[], true])
    end

    # Lain's own spec tree is the realistic corpus: hundreds of files written
    # by people who never heard of this guard. Read inside one example, so the
    # suite's count does not move with the tree.
    it "holds over lain's own spec tree, read as an rspec layout over lib" do
      root = File.expand_path("../../..", __dir__)
      layout = Lain::TestLayout.from({ "preset" => "rspec", "source_roots" => ["lib"],
                                       "level_roots" => { "unit" => "spec" } }, path: nil)
      own = described_class.new(layout:, root:)
      cases = Dir.glob("spec/lain/**/*_spec.rb", base: root).map { |path| [path, File.read(File.join(root, path))] }

      expect([unsound(own, cases), advised(own, cases).positive?]).to eq([[], true])
    end
  end
end
