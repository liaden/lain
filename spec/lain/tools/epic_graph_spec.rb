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

  it "links a blocks edge, writing it to epic.md and journaling a link" do
    result = run(verb: "link", slug: "frugirl-mvp", kind: "blocks", from: "scaffold", to: "docs")

    expect(result).not_to be_error
    expect(result.content).to include("linked `scaffold` blocks `docs`")
    expect(home.read_epic.blocked_by("docs")).to eq(["scaffold"])
    expect(io.string).to include('"operation":"link"')
  end

  it "unlinks it again" do
    run(verb: "link", slug: "frugirl-mvp", kind: "blocks", from: "scaffold", to: "docs")
    result = run(verb: "unlink", slug: "frugirl-mvp", kind: "blocks", from: "scaffold", to: "docs")

    expect(result.content).to include("unlinked `scaffold` blocks `docs`")
    expect(home.read_epic.blocked_by("docs")).to be_empty
  end

  it "returns a cycle as an error result naming the path" do
    run(verb: "link", slug: "frugirl-mvp", kind: "blocks", from: "scaffold", to: "docs")
    result = run(verb: "link", slug: "frugirl-mvp", kind: "blocks", from: "docs", to: "scaffold")

    expect(result).to be_error
    expect(result.content).to match(/scaffold.*docs/m)
  end

  it "retitles, describes and sets the subject of an issue" do
    run(verb: "retitle", slug: "frugirl-mvp", id: "docs", title: "write the docs")
    run(verb: "describe", slug: "frugirl-mvp", id: "docs", description: "all of them")
    result = run(verb: "subject", slug: "frugirl-mvp", id: "docs", subject: "lib/docs.rb")

    expect(result).not_to be_error
    expect(home.read_epic.fetch("docs")).to have_attributes(title: "write the docs", description: "all of them",
                                                            subject: "lib/docs.rb")
  end

  it "refuses an edge kind other than blocks or related as a shape error, and lists both in the schema" do
    expect { run(verb: "link", slug: "frugirl-mvp", kind: "depends", from: "scaffold", to: "docs") }
      .to raise_error(Lain::Tool::InvalidInput, /blocks or related/)
    expect(tool.input_schema.dig("properties", "kind", "enum")).to eq(%w[blocks related])
  end

  it "says in its description that retitle, describe and subject cannot blank a field" do
    expect(tool.description).to include("cannot blank")
  end

  it "refuses an edge verb missing its kind, naming the field" do
    expect { run(verb: "link", slug: "frugirl-mvp", from: "scaffold", to: "docs") }
      .to raise_error(Lain::Tool::InvalidInput, /Kind is required/)
  end

  it "refuses a merge with no as field, naming it" do
    expect { run(verb: "merge", slug: "frugirl-mvp", left: "scaffold", right: "docs") }
      .to raise_error(Lain::Tool::InvalidInput, /As is required/)
    expect(home.read_epic.ids).to contain_exactly("scaffold", "docs")
  end

  it "refuses an unknown verb, listing the verbs it takes" do
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
