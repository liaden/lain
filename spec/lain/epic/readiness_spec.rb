# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Epic::Readiness do
  def issue(id, subject: nil, level: nil, criteria: nil)
    Lain::Epic::Issue.new(id:, title: id, subject:, level:, criteria:)
  end

  def graph(*issues) = Lain::Epic::Graph.new(issues:)

  let(:cargo) { Lain::TestLayout.preset("cargo") }
  let(:manual_criteria) do
    "```gherkin\nScenario: ships\n  When the human runs `make check`\n  Then it is green\n```"
  end

  describe "with a layout in force" do
    it "names an issue whose subject no source root holds, with the layout's reason, and counts the rest" do
      report = described_class.of(graph(issue("deps", subject: "Cargo.toml", level: "unit"),
                                        issue("core", subject: "src/lib.rs", level: "integration"),
                                        issue("spike", subject: "scripts/probe.sh", level: "manual",
                                                       criteria: manual_criteria)), cargo)

      expect(report.unplaceable.keys).to eq(["deps"])
      expect(report.unplaceable.fetch("deps")).to include("Cargo.toml", "src")
      expect([report.tested, report.manual]).to eq([2, 1])
      expect(report).not_to be_ready
      expect(report.to_s).to include("deps", "unplaceable")
    end

    it "is ready when every tested issue places" do
      report = described_class.of(graph(issue("core", subject: "src/lib.rs", level: "integration")), cargo)

      expect(report).to be_ready
      expect(report.to_s).to include("ready")
    end

    it "names an issue that declares no subject" do
      report = described_class.of(graph(issue("bare")), cargo)

      expect(report.unplaceable.fetch("bare")).to include("Subject")
    end
  end

  describe "with no layout" do
    def loaded(line)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".lain"))
        File.write(File.join(dir, ".lain", "config.rb"), "#{line}\n")
        trust_project(dir)
        Lain::Config.test_layout(root: dir, paths: Lain::Paths.new)
      end
    end

    let(:issues) do
      graph(issue("deps", subject: "Cargo.toml", level: "unit"),
            issue("core", subject: "crates/app/src/lib.rs", level: "unit"))
    end

    it "reports the missing layout and proposes the tests line from the subjects it can place" do
      report = described_class.of(issues, Lain::TestLayout::None)

      expect(report).to be_missing_layout
      expect(report).not_to be_ready
      expect(report.proposal).to eq('tests preset: :cargo, source_roots: ["crates/app/src"]')
      expect(report.to_s).to include(report.proposal)
    end

    it "names an issue whose subject is a root-level file as needing a subject under a source root" do
      report = described_class.of(issues, Lain::TestLayout::None)

      expect(report.needs_subject).to eq(["deps"])
      expect(report.to_s).to include("deps needs a Subject under a source root")
    end

    it "proposes a line under which every issue it claims to fix is placeable" do
      report = described_class.of(issues, Lain::TestLayout::None)

      after = described_class.of(issues, loaded(report.proposal))

      expect(report.placed_by_proposal).to eq(["core"])
      expect(after.unplaceable.keys & report.placed_by_proposal).to be_empty
      expect(after.unplaceable.keys).to eq(["deps"])
    end

    it "proposes nothing when only root-level files are subjects" do
      report = described_class.of(graph(issue("deps", subject: "Cargo.toml", level: "unit")),
                                  Lain::TestLayout::None)

      expect(report.proposal).to be_nil
      expect(report.needs_subject).to eq(["deps"])
    end

    it "proposes nothing when no subject names a known language" do
      report = described_class.of(graph(issue("odd", subject: "tools/Makefile", level: "unit")),
                                  Lain::TestLayout::None)

      expect(report.proposal).to be_nil
    end
  end
end
