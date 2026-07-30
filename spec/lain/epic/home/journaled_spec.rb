# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# A reviews duck that says yes to whatever it was told to hold, and nothing
# else. Deliberately NOT {Lain::Epic::Review} (T15): what the decorator depends
# on is the `#open?(path)` message, not that class.
class FakeReviews
  def initialize(*open_paths)
    @open_paths = open_paths
  end

  def open?(path) = @open_paths.include?(path)
end

# The record this decorator writes. Covered here rather than in
# `records_spec.rb` because it exists for exactly one writer, and its `type`
# string -- derived from the class name, never hand-written -- is a DURABLE
# journal discriminator, so it is pinned like its two siblings are.
RSpec.describe Lain::Epic::DocWritten do
  def written(**overrides)
    described_class.new(epic_slug: "alpha", kind: "epic", path: "epic.md",
                        byte_digest: "blake3:beef", graph_digest: "blake3:cafe", **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(written.journal_type).to eq("doc_written")
    expect(described_class::JOURNAL_TYPE).to eq("doc_written")
  end

  it "refuses a kind outside the four artifacts a home holds" do
    expect { written(kind: "notes") }.to raise_error(ArgumentError, /kind/)
  end

  it "refuses an unnamed epic, an unnamed path, and undigested bytes" do
    expect { written(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
    expect { written(path: "  ") }.to raise_error(ArgumentError, /path/)
    expect { written(byte_digest: nil) }.to raise_error(ArgumentError, /byte_digest/)
  end

  it "leaves the graph digest optional, since only an epic write has one" do
    expect(written(graph_digest: nil).graph_digest).to be_nil
    expect(described_class.new(epic_slug: "alpha", kind: "research", path: "research.md",
                               byte_digest: "blake3:beef").graph_digest).to be_nil
  end

  it "is a deeply frozen, shareable value" do
    expect(written).to be_deeply_frozen
    expect(Ractor.shareable?(written)).to be(true)
  end
end

RSpec.describe Lain::Epic::Home::Journaled do
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }

  def paths_for(state_home)
    Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })
  end

  def home_in(tmp, slug: "alpha")
    Lain::Epic::Home.resolve(config: Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo)),
                             paths: paths_for(tmp), root: tmp, slug:)
  end

  def issue(id:, **overrides)
    Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)
  end

  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  def two_issue_graph = graph_of(issue(id: "a", blocks: ["b"]), issue(id: "b", status: "done"))

  # Legal to construct and impossible to emit: a trailing space is stripped by
  # the parse, so Document refuses to write the issue back rather than change it
  # silently (home_spec's own fixture).
  def unemittable_graph = graph_of(issue(id: "a", description: "trailing space "))

  def records = Lain::Journal.records(io.string.lines, type: "doc_written").to_a

  # The one expression a reader recomputes `byte_digest` with. Spelled out here
  # rather than reused from the implementation, so deleting the Blob and going
  # back to a Canonical digest of the JSON encoding fails these examples instead
  # of passing tautologically.
  def blob_digest(bytes) = Lain::Workspace::Snapshot::Blob.new(bytes:).digest

  describe "write_epic journals bytes and graph digests" do
    it "carries kind epic, the byte digest, and the graph digest" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        graph = two_issue_graph

        described_class.new(home, journal:).write_epic(graph)

        expect(records.size).to eq(1)
        expect(records.first).to include(
          "type" => "doc_written", "epic_slug" => "alpha", "kind" => "epic", "path" => "epic.md",
          "byte_digest" => blob_digest(Lain::Epic::Document.to_markdown(graph)),
          "graph_digest" => graph.digest
        )
      end
    end

    # The claim the record's own comment makes, asserted as a JOIN rather than
    # as a repeat of the expression that produced it: read the file back off
    # disk, address those bytes, and get the journaled digest.
    it "journals a byte digest that recomputes from the file on disk" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)

        described_class.new(home, journal:).write_epic(two_issue_graph)

        expect(records.first["byte_digest"]).to eq(blob_digest(File.binread(home.epic.path)))
      end
    end

    it "lands the same bytes the undecorated home would have" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        graph = two_issue_graph

        described_class.new(home, journal:).write_epic(graph)

        expect(home.read_epic.digest).to eq(graph.digest)
      end
    end

    # `Journaled#write_epic` renders the markdown itself, which is the one line
    # it shares with {Home#write_epic}. A graph round-trip would survive a drift
    # in that render; byte equality against the undecorated home does not.
    it "lands byte-for-byte what the undecorated home writes" do
      Dir.mktmpdir do |tmp|
        graph = two_issue_graph
        decorated = home_in(tmp, slug: "decorated")
        plain = home_in(tmp, slug: "plain")

        described_class.new(decorated, journal:).write_epic(graph)
        plain.write_epic(graph)

        expect(File.binread(decorated.epic.path)).to eq(File.binread(plain.epic.path))
      end
    end

    it "hands back a decorator, so a chained write is journaled too" do
      Dir.mktmpdir do |tmp|
        decorator = described_class.new(home_in(tmp), journal:)

        decorator.write_epic(two_issue_graph).write_epic(graph_of(issue(id: "a")))

        expect(records.size).to eq(2)
      end
    end
  end

  describe "a refused write journals nothing" do
    it "raises MalformedDocument for a graph the Writer refuses to emit" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)

        expect { described_class.new(home, journal:).write_epic(unemittable_graph) }
          .to raise_error(Lain::Epic::MalformedDocument)

        expect(records).to be_empty
        expect(File).not_to exist(home.path)
      end
    end

    it "journals nothing when the write itself is refused" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        FileUtils.mkdir_p(home.path)
        File.symlink(File.join(tmp, "elsewhere"), File.join(home.path, "issues"))

        expect { described_class.new(home, journal:).issue("a1").write("body") }
          .to raise_error(Lain::Epic::Home::EscapesHome)

        expect(records).to be_empty
      end
    end
  end

  describe "an open review blocks regeneration" do
    it "raises ReviewPending and leaves the file untouched" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        described_class.new(home, journal:).write_epic(graph_of(issue(id: "a")))
        before = File.read(File.join(home.path, "epic.md"))
        reviews = FakeReviews.new(home.epic.path)

        decorator = described_class.new(home, journal:, reviews:)

        expect { decorator.write_epic(two_issue_graph) }
          .to raise_error(Lain::Epic::Home::Journaled::ReviewPending, /#{Regexp.escape(home.epic.path)}/)
        expect(File.read(File.join(home.path, "epic.md"))).to eq(before)
      end
    end

    it "journals no doc_written for the refused regeneration" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        decorator = described_class.new(home, journal:, reviews: FakeReviews.new(home.epic.path))

        expect { decorator.write_epic(two_issue_graph) }
          .to raise_error(Lain::Epic::Home::Journaled::ReviewPending)
        expect(records).to be_empty
      end
    end

    it "refuses only the reviewed path, so a sibling artifact still writes" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        decorator = described_class.new(home, journal:, reviews: FakeReviews.new(home.epic.path))

        decorator.research.write("what we learned")

        expect(home.research.read).to eq("what we learned")
        expect(records.first).to include("kind" => "research", "path" => "research.md")
      end
    end

    it "lets a read through, because reading is not regeneration" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        home.write_epic(graph_of(issue(id: "a")))
        decorator = described_class.new(home, journal:, reviews: FakeReviews.new(home.epic.path))

        expect(decorator.read_epic.digest).to eq(graph_of(issue(id: "a")).digest)
        expect(decorator.epic.exist?).to be(true)
      end
    end
  end

  describe "Reviews::Null" do
    it "never refuses, so an unwired decorator writes exactly as the home does" do
      Dir.mktmpdir do |tmp|
        expect(described_class::Reviews::Null.open?("anything at all")).to be(false)
        expect(described_class::Reviews::Null.open?(home_in(tmp).epic.path)).to be(false)
      end
    end
  end

  describe "the Home duck, answered whole" do
    it "journals research, issue and plan writes under their own kinds and relative paths" do
      Dir.mktmpdir do |tmp|
        decorator = described_class.new(home_in(tmp), journal:)

        decorator.research.write("what we learned")
        decorator.issue("a1").write("the story")
        decorator.plan("a1").write("the plan")

        expect(records.map { |record| record.values_at("kind", "path") })
          .to eq([%w[research research.md], ["issue", File.join("issues", "a1.md")],
                  ["plan", File.join("plans", "a1.md")]])
      end
    end

    it "journals no graph digest for a write that is not an epic" do
      Dir.mktmpdir do |tmp|
        described_class.new(home_in(tmp), journal:).research.write("what we learned")

        expect(records.first).to include("graph_digest" => nil)
      end
    end

    # Not merely "does not pass one" -- CANNOT. A graph digest is a property of
    # the artifact the decorator resolved, so prose has no way to acquire one,
    # and the wrapper's write takes exactly the arity {Home::Artifact#write}
    # does. A kwarg here would have been both a lie in the record and a duck the
    # thing it decorates does not answer.
    it "gives a prose artifact no way to carry a graph digest" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        artifact = described_class.new(home, journal:).research

        expect { artifact.write("prose", graph_digest: "blake3:not-a-graph") }.to raise_error(ArgumentError)
        expect(artifact.method(:write).parameters).to eq(home.research.method(:write).parameters)
      end
    end

    it "digests the bytes that landed, so a second write of the same bytes repeats the digest" do
      Dir.mktmpdir do |tmp|
        decorator = described_class.new(home_in(tmp), journal:)

        decorator.research.write("same bytes")
        decorator.research.write("same bytes")

        expect(records.map { |record| record["byte_digest"] }).to eq([blob_digest("same bytes")] * 2)
      end
    end

    it "forwards slug, path, and an artifact's own path untouched" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        decorator = described_class.new(home, journal:)

        expect(decorator.slug).to eq(home.slug)
        expect(decorator.path).to eq(home.path)
        expect(decorator.epic.path).to eq(home.epic.path)
      end
    end

    it "forwards read and exist? to the artifact the home resolved" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)
        decorator = described_class.new(home, journal:)

        expect(decorator.research.exist?).to be(false)
        home.research.write("what we learned")
        expect(decorator.research.read).to eq("what we learned")
        expect(decorator.research.exist?).to be(true)
      end
    end

    it "refuses a malformed issue id exactly as the home does" do
      Dir.mktmpdir do |tmp|
        decorator = described_class.new(home_in(tmp), journal:)

        expect { decorator.issue("../escape") }.to raise_error(Lain::Epic::Home::MalformedName)
        expect(records).to be_empty
      end
    end

    # The escalation trigger the card names: the decorator must add nothing to
    # HOW a file lands, so the tempfile-and-rename is still observable through it.
    it "leaves no temporary file beside the artifact it replaced" do
      Dir.mktmpdir do |tmp|
        home = home_in(tmp)

        described_class.new(home, journal:).write_epic(two_issue_graph)

        expect(Dir.children(home.path)).to eq(["epic.md"])
      end
    end
  end
end
