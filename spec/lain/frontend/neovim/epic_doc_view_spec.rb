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
      .to eq(["lain://epic/frugirl/research.md", ["# Research", "findings"]])
  end

  it "names an issue plan by its home path" do
    homes.for("frugirl").plan("a1").write("# plan\n")

    expect(view.update(written("plans/a1.md", "plan"))).to eq(["lain://epic/frugirl/plans/a1.md", ["# plan"]])
  end

  it "names epic.md by its home path" do
    homes.for("frugirl").epic.write("# Epic\n")

    expect(view.update(written("epic.md", "epic"))).to eq(["lain://epic/frugirl/epic.md", ["# Epic"]])
  end

  it "names an issue document by its home path" do
    homes.for("frugirl").issue("a1").write("# issue\n")

    expect(view.update(written("issues/a1.md", "issue"))).to eq(["lain://epic/frugirl/issues/a1.md", ["# issue"]])
  end

  it "answers nothing when resolving the home fails at the filesystem" do
    unreadable = Class.new { def self.for(_slug) = raise(Errno::EACCES, "state home") }

    expect(described_class.new(homes: unreadable).update(written("research.md", "research"))).to be_nil
  end

  it "answers nothing for an event that is not a document write" do
    expect(view.update(Lain::Telemetry::ToolOutput.new(tool_use_id: "t", stream: :stdout, bytes: "x"))).to be_nil
  end

  it "answers nothing rather than raising when the document is gone" do
    expect(view.update(written("research.md", "research"))).to be_nil
  end

  it "answers nothing when no docs reader is wired" do
    expect(described_class.new.update(written("research.md", "research"))).to be_nil
  end
end
