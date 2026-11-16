# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Lain::Tools::EpicShow do
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
  let(:epic_md) { "# Frugirl\n\n### [ ] `store-crate` the store crate\n\nbody\n" }

  def home(slug = "frugirl-mvp") = Lain::Epic::Home.resolve(config:, paths:, root: @dir, slug:)

  def run(**input) = tool.call(input.transform_keys(&:to_s), invocation)

  before do
    home.epic.write(epic_md)
    home.issue("store-crate").write("The store crate holds the records.\n")
  end

  it "takes no approval" do
    expect(tool.requires_approval?).to be(false)
  end

  it "answers the rendered issue view for an id" do
    result = run(id: "store-crate", slug: "frugirl-mvp")

    expect(result).not_to be_error
    expect(result.content).to eq(Lain::CLI::Epic.new(root: @dir, paths:, config:, journal:)
                                                  .show("issues/store-crate", "frugirl-mvp"))
    expect(result.content).to include("store-crate")
  end

  it "shows the issue of the epic the slug names, and nothing of the other" do
    home("other").epic.write("# Other\n\n### [ ] `store-crate` the other crate\n")
    home("other").issue("store-crate").write("Other epic body.\n")

    expect(run(id: "store-crate", slug: "other").content).to include("Other epic body.")
      .and(not_include("The store crate holds"))
    expect(run(id: "store-crate", slug: "frugirl-mvp").content).to include("The store crate holds")
      .and(not_include("Other epic body."))
  end

  it "never tells the model to run a lain command when the epic is ambiguous" do
    home("other").epic.write(epic_md)

    expect(run(id: "store-crate").content).not_to include("lain epic")
  end

  it "names the issue file, relative to the project root, in the notice of a cut view" do
    home.issue("store-crate").write("x" * 40_000)

    result = run(id: "store-crate", slug: "frugirl-mvp")

    expect(result.content.bytesize).to be <= described_class::BOUND.limit
    expect(result.content).to include("truncated", ".lain/epics/frugirl-mvp/issues/store-crate.md")
    expect(result.content).not_to include(@dir)
  end

  it "resolves the sole epic when no slug is named" do
    expect(run(id: "store-crate").content).to include("The store crate holds the records.")
  end

  it "answers an unknown issue as an error result" do
    expect(run(id: "nope", slug: "frugirl-mvp")).to be_error
  end

  it "requires an id" do
    expect { run(slug: "frugirl-mvp") }.to raise_error(Lain::Tool::InvalidInput, /Id/)
  end
end
