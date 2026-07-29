# frozen_string_literal: true

require "tmpdir"

# M5: the court-clerk consolidation pass. Offline, it walks a session Journal's
# COMPLETED SUBAGENT lineages (turns whose chain root carries `spawned_from`
# meta, grouped by that root), renders each lineage's transcript into the
# court-clerk scaffold, and spawns the shipped `court_clerk` role once per
# lineage -- FRESH-ROOT (the clerk reads the record, it never inherits the
# parent's prompt). The clerk's memory_write is guarded by a dispatch chain
# THIS class builds with {Middleware::RefuseSecretWrites} mounted, because that
# guard does not come free from the spawn seam.
RSpec.describe Lain::Consolidation do
  let(:store) { Lain::Store.new }
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:context) { Lain::Context.new(model: "clerk-model", max_tokens: 256) }
  let(:journal) { [] }
  let(:main) { Lain::Timeline.empty(store:).commit(role: :user, content: text("orchestrate the work")) }
  # Two completed subagent lineages hanging off the main chain's head.
  let(:lineage_a) { lineage("investigate the login bug", "the token TTL was zero", spawned_from: main.head_digest) }
  let(:lineage_b) { lineage("audit the payment path", "the retry was unbounded", spawned_from: main.head_digest) }
  let(:root_a) { lineage_a.first }
  let(:root_b) { lineage_b.first }
  # Journal order: main, then A's turns, then B's -- the order the pass folds in.
  let(:records) { turn_records(main) + turn_records(lineage_a.last) + turn_records(lineage_b.last) }

  def text(body) = [{ "type" => "text", "text" => body }]

  def turn_records(timeline) = timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) }

  # A main (non-subagent) chain plus a fresh-root subagent lineage whose root
  # commit carries `spawned_from` -- exactly the shape {Tools::Subagent} leaves
  # on the Journal.
  def lineage(task, finding, spawned_from:)
    root = Lain::Timeline.empty(store:)
                         .commit(role: :user, content: text(task), meta: { "spawned_from" => spawned_from })
    [root.head_digest, root.commit(role: :assistant, content: text(finding))]
  end

  around do |example|
    Dir.mktmpdir do |root|
      @slots = Lain::Prompt::Slots.load(root:)
      example.run
    end
  end

  attr_reader :slots

  def memory_write(id, body) = ["tu_#{id}", "memory_write", { "id" => id, "description" => "finding", "body" => body }]

  def journal_records(entries, type)
    entries.select { |record| record.respond_to?(:to_journal) && record.to_journal["type"] == type }
  end

  def consolidation(provider)
    Lain::Consolidation.new(provider:, recorder:, context:, slots:, journal:)
  end

  # Every text block across every request the provider was handed -- the scaffold
  # the clerk actually saw.
  def prompts_seen(provider)
    provider.requests.flat_map do |request|
      request.messages.flat_map { |message| Array(message["content"]).grep(Hash).map { |block| block["text"] } }
    end.compact
  end

  describe "each completed lineage gets one clerk pass" do
    it "spawns one clerk per lineage, lands one memory each, and each names its lineage root" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", "root #{root_a}: login bug")),
                                            text_response("clerked A"),
                                            tool_response(memory_write("lineage-b", "root #{root_b}: payment path")),
                                            text_response("clerked B")
                                          ])

      outcomes = consolidation(provider).call(records)

      # Two lineages -> two spawns (each child ran its own two-step loop, so four
      # provider round trips), two memories in the shared index.
      expect(outcomes.map(&:root)).to contain_exactly(root_a, root_b)
      expect(recorder.index.count).to eq(2)
      expect(recorder.index.fetch("lineage-a").body).to include(root_a)
      expect(recorder.index.fetch("lineage-b").body).to include(root_b)

      # The scaffold that reached each clerk named its lineage root as evidence.
      seen = prompts_seen(provider)
      expect(seen.any? { |text| text.include?(root_a) }).to be(true)
      expect(seen.any? { |text| text.include?(root_b) }).to be(true)
    end

    it "excludes non-subagent (main) chains -- only lineages with spawned_from roots are clerked" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", "a")), text_response,
                                            tool_response(memory_write("lineage-b", "b")), text_response
                                          ])

      expect(consolidation(provider).call(records).size).to eq(2)
    end
  end

  describe "the secret guard still gates the clerk" do
    let(:pem) { "-----BEGIN PRIVATE KEY-----\nMIIB...\n-----END PRIVATE KEY-----" }

    it "refuses a credential-shaped write with the standard telemetry and continues the pass" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", pem)), text_response("A done"),
                                            tool_response(memory_write("lineage-b", "clean note")), text_response("B")
                                          ])

      consolidation(provider).call(records)

      # A's PEM write was withheld before the recorder; B's clean write landed --
      # the refusal contained itself and the pass moved on.
      expect(recorder.index.key?("lineage-a")).to be(false)
      expect(recorder.index.key?("lineage-b")).to be(true)

      refusals = journal_records(journal, "write_refused")
      expect(refusals.size).to eq(1)
      expect(refusals.first.to_journal["pattern"]).to eq("pem private key block")
    end
  end

  # T18: grouping is one walk per turn. chain_root climbs the render-parent edge
  # to the top for EVERY turn, so without a digest=>root memo shared across the
  # one from_records call an N-turn lineage re-reads the root's parent edge N
  # times -- quadratic over an array already in memory. The memo lives for the
  # call and no longer.
  describe "grouping walks each parent edge once per from_records call" do
    let(:deep) do
      root = Lain::Timeline.empty(store:).commit(role: :user, content: text("deep task"),
                                                 meta: { "spawned_from" => main.head_digest })
      (1..11).inject(root) { |chain, step| chain.commit(role: :assistant, content: text("step #{step}")) }
    end

    it "reads each turn's parent edge once, not once per descendant" do
      records = turn_records(deep)
      records.each { |record| allow(record).to receive(:[]).and_call_original }

      grouped = Lain::Consolidation::Lineage.from_records(records)

      expect(grouped.map(&:turn_count)).to eq([12])
      expect(records).to all(have_received(:[]).with("parent").at_most(:twice))
    end

    it "still groups a lineage under its chain root, and drops a headless tail" do
      headless = turn_records(deep).drop(1)

      expect(Lain::Consolidation::Lineage.from_records(turn_records(deep)).map(&:root)).to eq([deep.to_a.first.digest])
      expect(Lain::Consolidation::Lineage.from_records(headless)).to eq([])
    end
  end

  describe "#dry_run" do
    it "names the lineages that would be clerked, through a provider that cannot be reached" do
      report = consolidation(Lain::Provider::Unreachable.new).dry_run(records)

      expect(report).to include(root_a, root_b)
      expect(report).to include("2 lineage")
    end

    it "says so when a journal holds no completed subagent lineages" do
      main_only = turn_records(main)

      expect(consolidation(Lain::Provider::Unreachable.new).dry_run(main_only))
        .to include("no completed subagent lineages")
    end
  end

  # The on-demand CLI surface: it resolves a session file and hands the records
  # to the pass, returning a String (only the frontend prints).
  describe Lain::CLI::Consolidate do
    let(:paths) { instance_double(Lain::Paths, sessions_dir: @session_dir) }

    around do |example|
      Dir.mktmpdir do |session_dir|
        @session_dir = session_dir
        File.write(File.join(session_dir, "s1.ndjson"), records.map { |record| JSON.generate(record) }.join("\n"))
        example.run
      end
    end

    def cli(provider) = described_class.new(consolidation: consolidation(provider), paths:)

    it "resolves a bare session name and renders the clerk outcomes" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", "a")), text_response("A done"),
                                            tool_response(memory_write("lineage-b", "b")), text_response("B done")
                                          ])

      report = cli(provider).report("s1")

      expect(report).to include("2 lineage", root_a, root_b, "A done", "B done")
    end

    # A separate METHOD, not `report(dry_run: true)`: the dry surface reports on
    # a different half of the pass, and a provider that CANNOT be reached proves
    # "no spawn" by construction rather than by counting calls afterwards.
    it "renders the dry-run plan through a provider that cannot be reached" do
      expect(cli(Lain::Provider::Unreachable.new).dry_report("s1"))
        .to include("would each get one court_clerk pass")
    end

    it "raises the shared SessionFile refusal, listing what it looked at" do
      expect { cli(Lain::Provider::Mock.new).report("nope") }
        .to raise_error(Lain::CLI::SessionFile::SessionNotFound, /nope/)
    end

    it "keeps no per-class SessionNotFound of its own" do
      expect(described_class.const_defined?(:SessionNotFound, false)).to be(false)
    end

    describe ".from_options" do
      it "assembles Provider::Unreachable for --dry-run, so a dry pass needs no API key" do
        pass = described_class.from_options({ dry_run: true, provider: "anthropic", max_tokens: 64 })

        # Through the pass it holds: the assembly's choice of provider is the
        # thing under test, and the object refuses every message that would
        # otherwise reveal it.
        inner = pass.instance_variable_get(:@consolidation)
        expect(inner.instance_variable_get(:@provider)).to be_a(Lain::Provider::Unreachable)
      end
    end
  end

  # The four-nils smell, removed: a dry run wires a REAL Null provider
  # ({Provider::Unreachable}), so every collaborator can be required and a
  # mis-wire is a loud ArgumentError where the wiring happened -- not a
  # NoMethodError, or a MissingCollaborator, one spawn later.
  describe "the collaborators are required at construction" do
    it "raises ArgumentError naming the keyword the wiring forgot" do
      expect { described_class.new(recorder:, context:, slots:) }.to raise_error(ArgumentError, /provider/)
    end

    it "raises for a forgotten recorder too, before any lineage is walked" do
      expect { described_class.new(provider: Lain::Provider::Mock.new, context:, slots:) }
        .to raise_error(ArgumentError, /recorder/)
    end

    it "keeps no MissingCollaborator: there is no nil left to check at use" do
      expect(described_class.const_defined?(:MissingCollaborator, false)).to be(false)
    end
  end
end
