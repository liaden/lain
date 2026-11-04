# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The role spawn a document critique asks for its children, recorded: the
# environment each was lent and the (role, mode, prompt) it was spawned with.
class DocumentCritiqueSpecSpawn
  Seam = Struct.new(:context_factory, :provider)

  def initialize
    @calls = []
  end

  attr_reader :calls

  def seam = Seam.new(-> { Lain::Context.new(model: "critic-model", max_tokens: 512) }, Lain::Provider::Mock.new)

  def within(worker_env) = Lent.new(self, worker_env)

  # The copy an unattended child spawns through. Recording needs no other.
  def never_parking = self

  def spawned(worker_env, role, mode, prompt)
    @calls << { worker_env:, role:, mode:, prompt: }
    Lain::Tool::Result.ok("findings from child #{@calls.size}")
  end

  # One lent spawn, so a call records the environment it was made inside.
  class Lent
    def initialize(spawn, worker_env)
      @spawn = spawn
      @worker_env = worker_env
    end

    def call(role, mode, prompt, model: Lain::Tools::Subagent::ModelChoice::Null)
      raise ArgumentError, "unexpected model #{model.inspect}" unless model.model.empty?

      @spawn.spawned(@worker_env, role, mode, prompt)
    end
  end
end

RSpec.describe Lain::Review::Critique::Documents, :seam do
  def write(relative, text, under: @home)
    path = File.join(under, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def view(number) = format("issues/%<n>02d/view.md", n: number)

  def corpus(named_from: nil)
    sensitivity = Lain::Sensitivity.new(home: "/home/surveyor", cwd: @home)
    projection = Lain::Survey::Projection.new(ledger: Lain::Sensitivity::Ledger.new)
    Lain::Review::Source::Corpus.new(walk: Lain::Survey::Walk.new(root: @home, sensitivity:), projection:,
                                     named_from:)
  end

  def cluster(label, numbers) = described_class::Cluster.new(label:, paths: numbers.map { view(_1) })

  def clusters = [cluster("storage", 1..3), cluster("wire", 4..6), cluster("cockpit", 7..9)]

  def documents(clusters: self.clusters, shared: ["epic.md"], corpus: self.corpus, **)
    described_class.new(corpus:, clusters:, shared:, brief: "the issue views of the nyotes epic", **)
  end

  def window
    Lain::CLI::Backend::WindowBook::Served.new(model: "critic-model", window_tokens: 32_768,
                                               provenance: Lain::ContextWindow::PROBED)
  end

  def critique(subject, spawn: self.spawn, journal: self.journal)
    Lain::Review::Critique.new(subject:, spawn:, window:, checkouts:, journal:, slots: @slots,
                               instructions: "# critique\nReview the issues.")
  end

  def refusal(message = nil, &) = raise_error(Lain::Review::Critique::Refused, *message, &)

  let(:worker_env) { Lain::WorkerEnv.new(cwd: @project, env: { "LANG" => "C" }) }
  let(:checkouts) { described_class::ReadRoots.new(root: @home, worker_env:) }
  let(:spawn) { DocumentCritiqueSpecSpawn.new }
  let(:journal) { [] }

  around do |example|
    Dir.mktmpdir("lain-document-critique") do |made|
      @made = File.realpath(made)
      @project = File.join(@made, "project")
      @home = File.join(@made, "epics", "nyotes")
      FileUtils.mkdir_p([@project, @home])
      @slots = Lain::Prompt::Slots.load(root: @project)
      example.run
    end
  end

  before do
    write("epic.md", "# nyotes\nEPIC-SHARED-CONTEXT\n")
    (1..9).each { |number| write(view(number), "# issue #{number}\nISSUE-BODY-#{number}\n") }
  end

  describe "3 clusters of issue files are reviewed by 3 fresh children" do
    let!(:findings) { critique(documents).call }

    it "spawns 3 fresh read-only reviewers" do
      expect(spawn.calls.map { [_1[:role], _1[:mode]] }).to eq([%i[reviewer_code fresh]] * 3)
    end

    it "shows each child only its cluster and the shared files" do
      shown = spawn.calls.map { |call| (1..9).select { call[:prompt].include?("ISSUE-BODY-#{_1}\n") } }

      expect(shown).to eq([[1, 2, 3], [4, 5, 6], [7, 8, 9]])
      expect(spawn.calls).to all(include(prompt: include("EPIC-SHARED-CONTEXT", "the issue views of the nyotes epic")))
    end

    it "merges the findings in cluster order" do
      order = %w[storage wire cockpit].map { findings.index(_1) }

      expect(order).to eq(order.sort)
      expect(findings.index("findings from child 1")).to be < findings.index("findings from child 3")
    end

    it "runs every child in the document root, keeping the rest of the environment it was lent" do
      expect(spawn.calls.map { _1[:worker_env] }).to eq([worker_env.with(cwd: @home)] * 3)
    end

    it "tells each child the root its paths are named from, and that other clusters have reviewers" do
      expect(spawn.calls).to all(include(prompt: include("named from #{@home}", described_class::Brief::OTHERS)))
    end

    it "journals a chunk record per cluster under the documents' content address" do
      expect(journal.map { [_1.ordinal, _1.label, _1.paths, _1.role] })
        .to eq([[1, "storage", [view(1), view(2), view(3)], "reviewer_code"],
                [2, "wire", [view(4), view(5), view(6)], "reviewer_code"],
                [3, "cockpit", [view(7), view(8), view(9)], "reviewer_code"]])
      expect(journal.map(&:head_ref).uniq).to eq([corpus.head_ref])
    end
  end

  describe "one cluster" do
    it "mentions no other reviewers" do
      critique(documents(clusters: [cluster("storage", 1..3)])).call

      expect(spawn.calls.first[:prompt]).not_to include(described_class::Brief::OTHERS)
    end
  end

  # The whole stack a reviewer child gets, real from the spawn to the read
  # tool, over a guard that approves every call: the critique, not its
  # caller, is what keeps a child from reading outside the document root.
  describe "what a child can read" do
    def text(words) = Lain::Response.new(content: [{ "type" => "text", "text" => words }], stop_reason: :end_turn)

    def reads(path)
      Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_#{path.hash.abs}", "name" => "read_file",
                                     "input" => { "path" => path } }], stop_reason: :tool_use)
    end

    def tool_results(provider)
      provider.requests.flat_map(&:messages).flat_map { Array(_1["content"]) }
              .select { _1.is_a?(Hash) && _1["type"] == "tool_result" }
    end

    let(:provider) do
      Lain::Provider::Mock.new(responses: [reads(File.join(@made, "outside", "notes.txt")), text("child 1 done"),
                                           reads(view(8)), text("child 2 done")])
    end

    let(:real_spawn) do
      union = Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                                 Lain::Tools::Grep.new])
      guard = Lain::CLI::ToolGuard.detached(journal: Lain::Channel::Null.instance, roots: [@project])
      Lain::Skill::RoleSpawn.new(provider:, toolset: union, slots: @slots, tool_middleware: guard,
                                 context_factory: -> { Lain::Context.new(model: "critic-model", max_tokens: 256) },
                                 parent: Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store))
    end

    before do
      write("notes.txt", "OUTSIDE-BYTES\n", under: File.join(@made, "outside"))
      critique(documents(clusters: [cluster("storage", 1..3), cluster("wire", 4..6)]), spawn: real_spawn).call
    end

    it "refuses a read outside the document root" do
      outside, = tool_results(provider)

      expect(outside).to include("is_error" => true)
      expect(outside.to_s).not_to include("OUTSIDE-BYTES")
    end

    it "resolves a relative read against the document root" do
      _, inside = tool_results(provider)

      expect(inside.to_s).to include("ISSUE-BODY-8")
    end
  end

  def digest(text) = Lain::Workspace::Snapshot::Blob.new(bytes: text).digest

  def short(text) = Lain::Canonical.abbreviate(digest(text), scheme: false)

  describe "a document already reviewed and unchanged since" do
    before { critique(documents(known: { view(2) => digest("# issue 2\nISSUE-BODY-2\n") })).call }

    it "is named by its digest in place of its text" do
      prompt = spawn.calls.first[:prompt]

      expect(prompt).to include("## #{view(2)}", short("# issue 2\nISSUE-BODY-2\n"), "ISSUE-BODY-1", "ISSUE-BODY-3")
      expect(prompt).not_to include("ISSUE-BODY-2")
    end
  end

  describe "a shared document already read and unchanged since" do
    it "is named by its digest in place of its text" do
      critique(documents(known: { "epic.md" => digest("# nyotes\nEPIC-SHARED-CONTEXT\n") })).call

      expect(spawn.calls).to all(include(prompt: include("## epic.md", short("# nyotes\nEPIC-SHARED-CONTEXT\n"))))
      expect(spawn.calls.map { _1[:prompt] }.grep(/EPIC-SHARED-CONTEXT/)).to be_empty
    end
  end

  describe "a document read at another digest" do
    it "is shown whole, since what the earlier round read is not what stands" do
      critique(documents(known: { view(2) => digest("# issue 2\nan older body\n") })).call

      expect(spawn.calls.first[:prompt]).to include("ISSUE-BODY-2")
    end
  end

  describe "#shown" do
    it "digests the very text each document was shown as, shared and clustered alike" do
      shown = documents(clusters: [cluster("storage", 1..2)]).shown

      expect(shown).to eq("epic.md" => digest("# nyotes\nEPIC-SHARED-CONTEXT\n"),
                          view(1) => digest("# issue 1\nISSUE-BODY-1\n"),
                          view(2) => digest("# issue 2\nISSUE-BODY-2\n"))
    end

    it "digests a masked document as the child saw it, not as the file holds it" do
      key = "-----BEGIN PRIVATE KEY-----\n#{"QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZn\n" * 4}" \
            "-----END PRIVATE KEY-----\n"
      write(view(2), "# issue 2\n#{key}")

      shown = documents(clusters: [cluster("storage", 2..2)]).shown.fetch(view(2))

      expect(shown).not_to eq(digest(File.binread(File.join(@home, view(2)))))
    end
  end

  describe "notes beside the documents" do
    it "are shown to every child" do
      critique(documents(notes: "# Where this review sits\nWAVE-LAYOUT-NOTE")).call

      expect(spawn.calls).to all(include(prompt: include("WAVE-LAYOUT-NOTE")))
    end
  end

  describe "documents a critique cannot take" do
    def clustered(*paths) = [described_class::Cluster.new(label: "ghost", paths:)]

    it "refuses no cluster at all" do
      expect { documents(clusters: []).refuse_unreadable! }.to refusal(/nothing/)
    end

    it "refuses a cluster that names no document" do
      expect { documents(clusters: clustered) }.to refusal(/ghost names no document/)
    end

    it "refuses a path the root does not hold, by name" do
      expect { documents(clusters: clustered("issues/99/view.md")) }.to refusal(%r{issues/99/view\.md})
    end

    it "refuses a path outside the root, even one that exists" do
      write("sibling.md", "S\n", under: File.dirname(@home))

      expect { documents(clusters: clustered("../sibling.md")) }.to refusal(%r{\.\./sibling\.md})
    end

    it "refuses a credential-class file, which a reviewer child has no human to ask about" do
      write(".env", "DB_PASSWORD=hunter2correcthorse\n")

      expect { documents(clusters: clustered(".env")) }.to refusal(/\.env.*credential.*no human/)
    end

    it "refuses a file the secret boundary withholds, saying it was withheld" do
      write(".ssh/id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n")

      expect do
        documents(clusters: clustered(".ssh/id_ed25519"))
      end.to refusal(%r{\.ssh/id_ed25519 was withheld.*protected})
    end

    it "refuses a document in 2 clusters" do
      twice = [cluster("storage", 1..3), cluster("wire", 3..6)]

      expect { documents(clusters: twice) }.to refusal(/#{view(3)}.*twice/)
    end

    it "refuses a shared document that also sits in a cluster" do
      expect { documents(shared: [view(2)]) }.to refusal(/#{view(2)}.*twice/)
    end

    it "refuses a corpus that names its paths from anywhere but the root they are read under" do
      expect { documents(corpus: corpus(named_from: File.dirname(@home))) }.to refusal(/named from/)
    end
  end

  describe "a cluster over the child's window" do
    it "refuses naming the cluster and its paths, since one critic reads a cluster whole" do
      write(view(1), "#{"wide line of prose ".ljust(400, "x")}\n" * 400)

      expect { critique(documents).call }.to(refusal do |error|
        expect(error.message).to include("storage", view(1), view(3), "cluster", "32768-token window")
      end)
      expect(spawn.calls).to be_empty
    end
  end

  describe "shared context too large for any cluster" do
    it "refuses naming the reserve before any cluster is blamed" do
      write("epic.md", "#{"shared context line ".ljust(400, "x")}\n" * 400)

      expect { critique(documents).call }.to refusal(/no room for a chunk/)
      expect(spawn.calls).to be_empty
    end
  end

  describe "a secret in a document" do
    it "is masked before a child sees it" do
      key = "-----BEGIN PRIVATE KEY-----\n#{"QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZn\n" * 4}" \
            "-----END PRIVATE KEY-----\n"
      write(view(2), "# issue 2\n#{key}")
      critique(documents).call

      expect(spawn.calls.first[:prompt]).not_to include("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZn")
    end
  end
end
