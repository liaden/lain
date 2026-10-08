# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Lain::Tools::EpicWrite do
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
  let(:reviews) { Lain::Epic::Home::Journaled::Reviews::Null }
  let(:homes) do
    journaled = ->(slug) { Lain::Epic::Home::Journaled.new(home(slug), journal:, reviews:) }
    Class.new { define_method(:for) { |slug| journaled.call(slug) } }.new
  end
  let(:tool) { described_class.new(homes:) }
  let(:epic_md) { "# Frugirl\n\n### [ ] `a1` the first issue\n\nbody\n\n### [ ] `b2` the second issue\n" }

  def home(slug = "frugirl-mvp") = Lain::Epic::Home.resolve(config:, paths:, root: @dir, slug:)

  def write(**input) = tool.call(input.transform_keys(&:to_s), invocation)

  it "writes each artifact kind to its place in the epic home" do
    write(slug: "frugirl-mvp", artifact: "research", content: "r\n")
    write(slug: "frugirl-mvp", artifact: "epic", content: epic_md)
    write(slug: "frugirl-mvp", artifact: "issue", issue: "a1", content: "i\n")
    write(slug: "frugirl-mvp", artifact: "plan", issue: "a1", content: "p\n")

    expect([home.research, home.epic, home.issue("a1"), home.plan("a1")].map(&:read))
      .to eq(["r\n", epic_md, "i\n", "p\n"])
  end

  describe "an epic.md, parsed before it is written" do
    it "says how many issues the epic tier will read from it" do
      result = write(slug: "frugirl-mvp", artifact: "epic", content: epic_md)

      expect(result).not_to be_error
      expect(result.content).to include("2 issues")
    end

    it "refuses an issue id no issue file could be named after, and writes nothing" do
      result = write(slug: "frugirl-mvp", artifact: "epic", content: "### [ ] `A_1` hostile\n")

      expect(result).to be_error
      expect(result.content).to include('"A_1"', Lain::Epic::Home::NAME_RULE)
      expect(home.epic.exist?).to be(false)
    end

    it "refuses markdown the epic grammar rejects, naming the line" do
      result = write(slug: "frugirl-mvp", artifact: "epic", content: "### a1: not a heading\n")

      expect(result).to be_error
      expect(result.content).to include("line 1")
      expect(home.epic.exist?).to be(false)
    end

    it "refuses an epic with no issue heading, showing the heading form" do
      result = write(slug: "frugirl-mvp", artifact: "epic", content: "# Frugirl\n\n## Issue a1: first\n")

      expect(result).to be_error
      expect(result.content).to include("no issue", "### [ ] `a1` title")
      expect(home.epic.exist?).to be(false)
    end
  end

  # The bytes are already renamed into place when the journal append fails,
  # so the refusal must not read as though nothing happened.
  context "when the journal cannot take the record" do
    let(:journal) { Class.new { def <<(_record) = raise(Errno::ENOSPC) }.new }

    it "says the file was written but the write was not journaled" do
      result = write(slug: "frugirl-mvp", artifact: "research", content: "r\n")

      expect(result).to be_error
      expect(result.content).to include(home.research.path, "was written", "not journaled", "No space left")
      expect(home.research.read).to eq("r\n")
    end
  end

  it "answers with the path it wrote and journals the write" do
    result = write(slug: "frugirl-mvp", artifact: "research", content: "# findings\n")

    expect(result).not_to be_error
    expect(result.content).to include(home.research.path)
    expect(io.string).to include('"type":"doc_written"', '"kind":"research"', '"path":"research.md"')
  end

  it "asks no approval, since it names an artifact kind and never a path" do
    expect(tool).not_to be_requires_approval
  end

  it "refuses an issue plan with no issue id, naming the missing field" do
    expect { write(slug: "frugirl-mvp", artifact: "plan", content: "p\n") }
      .to raise_error(Lain::Tool::InvalidInput, /Issue can't be blank/)
  end

  it "refuses an artifact kind it does not know, naming the four it does" do
    expect { write(slug: "frugirl-mvp", artifact: "notes", content: "n\n") }
      .to raise_error(Lain::Tool::InvalidInput, /research, epic, issue, plan/)
  end

  it "refuses a malformed slug, quoting the slug rule, and writes nothing" do
    result = write(slug: "Frugirl MVP", artifact: "research", content: "r\n")

    expect(result).to be_error
    expect(result.content).to include('"Frugirl MVP"', Lain::Epic::Home::NAME_RULE)
    expect(Dir.children(@dir)).to eq(["state"]).or eq([])
  end

  context "when a review holds the artifact" do
    let(:reviews) { Class.new { def open?(_path) = true }.new }

    it "refuses and names the open review" do
      result = write(slug: "frugirl-mvp", artifact: "research", content: "r\n")

      expect(result).to be_error
      expect(result.content).to include(home.research.path, "under review")
      expect(File.exist?(home.research.path)).to be(false)
    end
  end
end
