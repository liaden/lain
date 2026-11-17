# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe Lain::Tools::EpicStatus do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:journal) { Lain::Journal.new(io: StringIO.new) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:config) { Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo)) }
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state"), "HOME" => @dir }) }
  let(:homes) { Lain::CLI::EpicMount::Homes.new(journal:, root: @dir, paths:, config:) }
  let(:tool) { described_class.new(homes:) }
  let(:epic_md) do
    "# Frugirl\n\n### [ ] `scaffold` scaffold it\n\nbody\n\nBlocks: `docs`\n\n### [ ] `docs` write docs\n"
  end

  def home(slug = "frugirl-mvp") = Lain::Epic::Home.resolve(config:, paths:, root: @dir, slug:)

  def run(**input) = tool.call(input.transform_keys(&:to_s), invocation)

  it "is named epic_status and takes no approval" do
    expect(tool.name).to eq("epic_status")
    expect(tool.requires_approval?).to be(false)
  end

  it "answers the stage, the waves with their ids and the gate state, in the text the CLI prints", :seam do
    home.epic.write(epic_md)

    result = run(slug: "frugirl-mvp")

    expect(result).not_to be_error
    expect(result.content).to eq(Lain::CLI::Epic.new(root: @dir, paths:, config:, journal:).status("frugirl-mvp"))
    expect(result.content).to include("scaffold", "docs", "wave")
  end

  it "resolves the sole epic when no slug is named", :seam do
    home.epic.write(epic_md)

    expect(run.content).to include("scaffold")
  end

  it "reports the epic the slug names, and nothing of the other", :seam do
    home("one").epic.write("# One\n\n### [ ] `only-in-one` first\n")
    home("two").epic.write("# Two\n\n### [ ] `only-in-two` second\n")

    expect(run(slug: "two").content).to include("only-in-two").and(not_include("only-in-one"))
    expect(run(slug: "one").content).to include("only-in-one").and(not_include("only-in-two"))
  end

  it "never tells the model to run a lain command when the epic is ambiguous" do
    home("one").epic.write(epic_md)
    home("two").epic.write(epic_md)

    expect(run.content).not_to include("lain epic")
  end

  it "answers a refusal as an error result naming the choices, not a raise" do
    home("one").epic.write(epic_md)
    home("two").epic.write(epic_md)

    result = run

    expect(result).to be_error
    expect(result.content).to include("one", "two")
  end

  it "writes nothing to stdout", :seam do
    home.epic.write(epic_md)

    expect { run(slug: "frugirl-mvp") }.not_to output.to_stdout
  end

  it "cuts a report longer than its ceiling by whole lines and says what to do instead" do
    long = Array.new(2_000) { |i| "line #{i} " + ("x" * 40) }.join("\n")
    epics = Struct.new(:text) { def status(*) = text }.new(long)
    homes = Struct.new(:epics).new(epics)
    result = described_class.new(homes:).call({}, invocation)

    expect(result.content.bytesize).to be <= described_class::BOUND.limit
    expect(result.content).to include("truncated to", "epic_show")
    expect(result.content).to start_with("line 0 ")
  end

  describe "readiness", :seam do
    let(:cargo_config) { "tests preset: :cargo, source_roots: [\"src\"]\n" }
    let(:issues_md) do
      "# Frugirl\n\n### [ ] `deps` pin deps\n\nSubject: Cargo.toml\nLevel: unit\n"
    end

    def write_config(text)
      FileUtils.mkdir_p(File.join(@dir, ".lain"))
      File.write(File.join(@dir, ".lain", "config.rb"), text)
      trust_project(@dir, paths:)
    end

    it "appends the readiness report to the status when asked" do
      write_config(cargo_config)
      home.epic.write(issues_md)

      result = run(slug: "frugirl-mvp", readiness: true)

      expect(result).not_to be_error
      expect(result.content).to include("deps", "unplaceable", "Cargo.toml")
    end

    it "names the tests line to add when the project declares no layout" do
      home.epic.write(issues_md.sub("Cargo.toml", "src/lib.rs"))

      expect(run(slug: "frugirl-mvp", readiness: true).content).to include("tests preset: :cargo")
    end

    it "leaves the status alone when readiness is not asked" do
      home.epic.write(issues_md)

      expect(run(slug: "frugirl-mvp").content).not_to include("unplaceable")
    end
  end
end
