# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Lain::Tools::EpicGraph do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:config) { Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo)) }
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state"), "HOME" => @dir }) }
  let(:epics) { Lain::CLI::Epic.new(root: @dir, paths:, config:, journal:) }
  let(:tool) { described_class.new(epics:) }
  let(:epic_md) { "# Frugirl\n\n### [ ] `scaffold` scaffold it\n\nbody\n\n### [ ] `docs` write docs\n" }

  def home(slug = "frugirl-mvp") = Lain::Epic::Home.resolve(config:, paths:, root: @dir, slug:)

  def run(**input) = tool.call(input.transform_keys(&:to_s), invocation)

  before { home.epic.write(epic_md) }

  it "splits an issue into 2, rewriting epic.md and journaling the revision in this session" do
    result = run(verb: "split", slug: "frugirl-mvp", id: "scaffold", into: "cargo-init,ci")

    expect(result).not_to be_error
    expect(home.read_epic.ids).to contain_exactly("cargo-init", "ci", "docs")
    expect(io.string).to include('"type":"graph_revision"', '"operation":"split"')
  end

  it "merges 2 issues into the id named by as" do
    result = run(verb: "merge", slug: "frugirl-mvp", left: "scaffold", right: "docs", as: "setup")

    expect(result).not_to be_error
    expect(home.read_epic.ids).to eq(["setup"])
    expect(io.string).to include('"operation":"merge"')
  end

  it "adds an issue, recording where it was discovered" do
    result = run(verb: "add", slug: "frugirl-mvp", id: "lint", title: "add a linter", discovered_from: "scaffold")

    expect(result).not_to be_error
    expect(home.read_epic.ids).to include("lint")
    expect(io.string).to include('"operation":"add"')
  end

  it "refuses a merge with no as field, naming it" do
    expect { run(verb: "merge", slug: "frugirl-mvp", left: "scaffold", right: "docs") }
      .to raise_error(Lain::Tool::InvalidInput, /As is required/)
    expect(home.read_epic.ids).to contain_exactly("scaffold", "docs")
  end

  it "refuses an unknown verb, listing the 3 it takes" do
    expect { run(verb: "rename", slug: "frugirl-mvp", id: "scaffold") }
      .to raise_error(Lain::Tool::InvalidInput, /add, split, merge/)
  end

  it "refuses a verb missing a field it needs, naming the field" do
    expect { run(verb: "split", slug: "frugirl-mvp", id: "scaffold") }
      .to raise_error(Lain::Tool::InvalidInput, /Into is required/)
  end

  it "returns an edit's refusal as an error result and leaves epic.md as it was" do
    result = run(verb: "split", slug: "frugirl-mvp", id: "nope", into: "a,b")

    expect(result).to be_error
    expect(result.content).to include("nope")
    expect(home.epic.read).to eq(epic_md)
  end

  it "refuses an epic that does not exist, naming the slug" do
    result = run(verb: "split", slug: "ghost-epic", id: "scaffold", into: "a,b")

    expect(result).to be_error
    expect(result.content).to include("ghost-epic")
  end

  it "requires the slug, so a chat with several epics never relies on the sole one" do
    expect { run(verb: "split", id: "scaffold", into: "a,b") }
      .to raise_error(Lain::Tool::InvalidInput, /Slug/)
  end

  it "says in its description that a review holding epic.md refuses the edit" do
    expect(tool.description).to include("review")
  end

  it "asks no approval" do
    expect(tool.requires_approval?).to be(false)
  end
end
