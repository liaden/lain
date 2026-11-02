# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Frontend::Neovim::EpicDocView do
  subject(:view) { described_class.new(homes:) }

  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      example.run
    end
  end

  def paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"), "HOME" => @tmp })
  def config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))

  def homes
    Lain::CLI::EpicMount::Homes.new(journal: [], root: File.join(@tmp, "project"), paths:, config:)
  end

  def written(path, kind) = Lain::Epic::DocWritten.new(epic_slug: "frugirl", kind:, path:, byte_digest: "blake3:x")

  it "answers the lain://epic name and the file's lines for research.md" do
    homes.for("frugirl").research.write("# Research\nfindings\n")

    expect(view.update(written("research.md", "research")))
      .to eq([["lain://epic/frugirl/research.md", ["# Research", "findings"]]])
  end

  it "names epic.md by its home path" do
    homes.for("frugirl").epic.write("# Epic\n")

    expect(view.update(written("epic.md", "epic"))).to eq([["lain://epic/frugirl/epic.md", ["# Epic"]]])
  end

  it "shows an issue document as its view, under its home path" do
    homes.for("frugirl").epic.write("### [ ] `a1` First\n\nBlocks: `b2`\n\n### [ ] `b2` Second\n")
    homes.for("frugirl").issue("a1").write("prose\n")

    expect(view.update(written("issues/a1.md", "issue")))
      .to eq([["lain://epic/frugirl/issues/a1.md", ["# a1 -- First", "", "prose", "", "## Links", "", "Blocks: `b2`"]]])
  end

  it "re-renders every issue it has shown for that epic when epic.md is written" do
    home = homes.for("frugirl")
    home.epic.write("### [ ] `a1` First\n\n### [ ] `b2` Second\n")
    home.issue("a1").write("prose\n")
    view.update(written("issues/a1.md", "issue"))
    home.epic.write("### [ ] `a1` First\n\nBlocks: `b2`\n\n### [ ] `b2` Second\n")

    expect(view.update(written("epic.md", "epic")).to_h)
      .to include("lain://epic/frugirl/issues/a1.md" => include("Blocks: `b2`"))
  end

  it "re-renders no issue of another epic when epic.md is written" do
    homes.for("other").epic.write("### [ ] `a1` First\n")
    homes.for("other").issue("a1").write("prose\n")
    view.update(Lain::Epic::DocWritten.new(epic_slug: "other", kind: "issue", path: "issues/a1.md",
                                           byte_digest: "blake3:x"))
    homes.for("frugirl").epic.write("### [ ] `a1` First\n")
    homes.for("frugirl").issue("a1").write("prose\n")

    expect(view.update(written("epic.md", "epic")).map(&:first)).to eq(["lain://epic/frugirl/epic.md"])
  end

  it "answers nothing when resolving the home fails at the filesystem" do
    unreadable = Class.new { def self.for(_slug) = raise(Errno::EACCES, "state home") }

    expect(described_class.new(homes: unreadable).update(written("research.md", "research"))).to eq([])
  end

  it "answers nothing for an event that is not a document write" do
    expect(view.update(Lain::Telemetry::ToolOutput.new(tool_use_id: "t", stream: :stdout, bytes: "x"))).to eq([])
  end

  it "answers nothing rather than raising when the document is gone" do
    expect(view.update(written("research.md", "research"))).to eq([])
  end

  it "answers nothing when no docs reader is wired" do
    expect(described_class.new.update(written("research.md", "research"))).to eq([])
  end
end
