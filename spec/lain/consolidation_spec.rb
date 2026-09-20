# frozen_string_literal: true

require "tmpdir"

# The court-clerk consolidation pass. Offline, it takes a session's COMPLETED
# SUBAGENT lineages as {Lain::Bench::Session::Lineages} reads them, renders each
# lineage's child transcript into the court-clerk scaffold, and spawns the
# shipped `court_clerk` role once per lineage -- FRESH-ROOT (the clerk reads the
# record, it never inherits the parent's prompt). The clerk's tools are guarded
# by a dispatch chain THIS class builds over {CLI::ToolGuard.detached}, because
# the spawn seam supplies none.
RSpec.describe Lain::Consolidation do
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:context) { Lain::Context.new(model: "clerk-model", max_tokens: 256) }
  let(:journal) { [] }
  # A chat that spawned two one-shot subagents, both completed, recorded by a
  # real Scribe.
  let(:session) do
    RecordedSpawnSession.new(
      parent_responses: [tool_response(["tu_a", "subagent", { "prompt" => "investigate the login bug" }]),
                         tool_response(["tu_b", "subagent", { "prompt" => "audit the payment path" }]),
                         text_response("orchestrated")],
      child_responses: [text_response("the token TTL was zero"), text_response("the retry was unbounded")]
    ).run
  end
  let(:lineages) { Lain::Bench::Session::Lineages.of(Lain::Bench::Session.load(session.lines)).to_a }
  let(:spawn_a) { lineages.first.spawn.digest }
  let(:spawn_b) { lineages.last.spawn.digest }

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
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

  # Every tool_result the clerk was handed back, as one String -- what the tool
  # phase's guards left of each tool's own output.
  def tool_results_seen(provider)
    blocks = provider.requests.flat_map do |request|
      request.messages.flat_map { |message| Array(message["content"]).grep(Hash) }
    end
    blocks.select { |block| block["type"] == "tool_result" }.map { |block| block["content"].to_s }.join("\n")
  end

  describe "each completed lineage gets one clerk pass" do
    it "spawns one clerk per lineage, lands one memory each, and each names its lineage spawn" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", "spawn #{spawn_a}: login bug")),
                                            text_response("clerked A"),
                                            tool_response(memory_write("lineage-b", "spawn #{spawn_b}: payment path")),
                                            text_response("clerked B")
                                          ])

      outcomes = consolidation(provider).call(lineages)

      # Two lineages -> two spawns (each child ran its own two-step loop, so four
      # provider round trips), two memories in the shared index.
      expect(outcomes.map(&:spawn)).to eq([spawn_a, spawn_b])
      expect(recorder.index.count).to eq(2)
      expect(recorder.index.fetch("lineage-a").body).to include(spawn_a)
      expect(recorder.index.fetch("lineage-b").body).to include(spawn_b)

      # The scaffold that reached each clerk named its lineage spawn as evidence.
      seen = prompts_seen(provider)
      expect(seen.any? { |text| text.include?(spawn_a) }).to be(true)
      expect(seen.any? { |text| text.include?(spawn_b) }).to be(true)
    end

    it "hands each clerk its child's transcript, never the parent's conversation" do
      scaffold = described_class::Scaffold.new(lineages.first)

      expect(scaffold.transcript).to eq("[user] investigate the login bug\n[assistant] the token TTL was zero")
      expect(scaffold.render).to include(lineages.first.spawned_from)
      expect(scaffold.render).not_to include("orchestrated")
    end

    it "clerks nothing for a session that spawned nothing" do
      quiet = RecordedSpawnSession.new(parent_responses: [text_response("no spawn")], child_responses: []).run

      expect(consolidation(Lain::Provider::Mock.new)
               .call(Lain::Bench::Session::Lineages.of(Lain::Bench::Session.load(quiet.lines)))).to eq([])
    end
  end

  # A release put real bytes on the record for THAT session's model. This pass
  # is a second reader, out of chat, and nobody is at a surface to release
  # anything to it -- so every detected region is withheld, the fail-closed
  # posture {CLI::ToolGuard::Unreleased} takes for the clerk's own tool phase.
  describe "the transcript withholds what nobody is here to release" do
    let(:secret) { "AKIAIOSFODNN7EXAMPLE" }
    let(:session) do
      RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_a", "subagent", { "prompt" => "read the deploy notes" }]),
                           text_response("orchestrated")],
        child_responses: [text_response("the deploy key is #{secret}, then ghp_abcdefghij0123456789klmnopqrstuvwx")]
      ).run
    end

    it "masks each region a child echoed into its text, numbering them across the whole transcript" do
      transcript = described_class::Scaffold.new(lineages.first).transcript

      expect(transcript).to include("<redacted:1>", "<redacted:2>")
      expect(transcript).not_to include(secret)
    end

    # Only the RECORD's bytes are masked. A turn digest is a high-entropy token
    # the detector would withhold, and a scaffold that asked the clerk to cite
    # evidence it had just masked would be useless.
    it "leaves the lineage address the clerk is told to cite intact" do
      scaffold = described_class::Scaffold.new(lineages.first)

      expect(scaffold.render).to include(scaffold.spawn, lineages.first.spawned_from)
    end
  end

  describe "the secret guard still gates the clerk" do
    let(:pem) { "-----BEGIN PRIVATE KEY-----\nMIIB...\n-----END PRIVATE KEY-----" }

    it "refuses a credential-shaped write with the standard telemetry and continues the pass" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", pem)), text_response("A done"),
                                            tool_response(memory_write("lineage-b", "clean note")), text_response("B")
                                          ])

      consolidation(provider).call(lineages)

      # A's PEM write was withheld before the recorder; B's clean write landed --
      # the refusal contained itself and the pass moved on.
      expect(recorder.index.key?("lineage-a")).to be(false)
      expect(recorder.index.key?("lineage-b")).to be(true)

      refusals = journal_records(journal, "write_refused")
      expect(refusals.size).to eq(1)
      expect(refusals.first.to_journal["pattern"]).to eq("pem private key block")
    end
  end

  # The pass is DETACHED -- no chat lends it a board -- so it runs the stack such
  # a run builds for itself ({CLI::ToolGuard.detached}), which is also what
  # {CLI::Improve} runs. Four guards, not one: the write refusal, the read mask,
  # the listing filter and the test-layout guard.
  describe "the detached stack's other three guards" do
    # A real base64 body, not the sibling example's elided one: the read side
    # detects the key bytes as their own regions, and those are what must not
    # come back.
    let(:pem) do
      "-----BEGIN PRIVATE KEY-----\nMIIBVgIBADANBgkqhkiG9w0BAQEFAASCAUAwggE8AgEAAkEAqwertyuiop\n" \
        "asdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM1234567890abcdef\n-----END PRIVATE KEY-----"
    end
    # One lineage, so one scripted pair of responses answers one clerk spawn.
    let(:lineages) { super().first(1) }

    def improve
      Lain::CLI::Improve.new(path: "unread.ndjson", profile: Lain::CLI::RunProfile::UNRECORDED,
                             project_dir: Lain::ProjectDir.new(root: @root),
                             backend: -> { raise "the guard stack needs no backend" })
    end

    # `"-----"` is the body that changed answer: {Tool::Input} admits it and the
    # old NullOracle let it into the index, where the floor {CLI::ToolGuard}
    # wires declines it. A blank body was already refused, by validation.
    it "declines a body with no content, the floor the detached stack's oracle adds" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", "-----")), text_response("A done")
                                          ])

      consolidation(provider).call(lineages)

      expect(recorder.index.key?("lineage-a")).to be(false)
      expect(journal_records(journal, "write_refused").first.to_journal["pattern"])
        .to eq(Lain::Middleware::RefuseSecretWrites::ORACLE_DECLINE)
    end

    it "masks a credential region out of a file the clerk reads, with nobody there to release it" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "key.pem")
        File.write(path, "#{pem}\n")
        provider = Lain::Provider::Mock.new(responses: [
                                              tool_response(["tu_read", "read_file", { "path" => path }]),
                                              text_response("clerked A")
                                            ])

        consolidation(provider).call(lineages)

        expect(tool_results_seen(provider)).to include("<redacted:1>")
        expect(tool_results_seen(provider)).not_to include("MIIBVgIBADAN")
        masks = journal_records(journal, "read_redacted")
        expect(masks.size).to eq(1)
        expect(masks.first.to_journal["released"]).to eq(0)
      end
    end

    # The listing guard is mounted over the NULL filter on purpose: this pass's
    # gate consults no path policy either, so a filtered listing would hide a
    # path the clerk can still read by name. Pinned by identity, because giving
    # it a real policy while the gate stays Null is the mistake.
    it "mounts the listing guard over the Null filter, the posture a detached run chose" do
      guard = consolidation(Lain::Provider::Mock.new)
              .send(:guard_stack).to_a.grep(Lain::Middleware::WithholdSecretPaths).first

      expect(guard.filter).to equal(Lain::Sensitivity::Filter::Null.instance)
    end

    # {CLI::ToolGuard.detached} builds a board, and a pass over N lineages is ONE
    # run: the clerks share its region ledger and its layout run.
    it "builds one board for the whole pass, however many lineages it clerks" do
      pass = consolidation(Lain::Provider::Mock.new)
      runs = Array.new(2) { pass.send(:guard_stack).to_a.grep(Lain::Middleware::GuardTestLayout).first.run }

      expect(runs.first).to equal(runs.last)
    end

    it "holds the same guard classes in the same order as the improve pass" do
      expect(consolidation(Lain::Provider::Mock.new).send(:guard_stack).to_a.map(&:class))
        .to eq(improve.send(:guard_stack, Lain::Channel::Null.instance).to_a.map(&:class))
    end
  end

  describe ".dry_run" do
    it "names the lineages that would be clerked, asked of the class so nothing is built" do
      report = described_class.dry_run(lineages)

      expect(report).to include(spawn_a, spawn_b)
      expect(report).to include("2 lineage")
    end

    # The dry surface is where a human reads WHAT WOULD BE SENT, so it renders
    # the scaffolds rather than a list naming them. Same objects the live pass
    # asks, so the two cannot disagree -- masking included.
    it "renders each scaffold the clerk would see, not a plan naming it" do
      report = described_class.dry_run(lineages)

      expect(report).to include(*lineages.map { |lineage| described_class::Scaffold.new(lineage).render })
    end

    it "says so when a session holds no completed subagent lineages" do
      expect(described_class.dry_run([])).to include("no completed subagent lineages")
    end
  end

  # The four-nils smell, removed: a dry run builds no pass at all, so every
  # collaborator can be required and a mis-wire is a loud ArgumentError where
  # the wiring happened -- not a NoMethodError, or a MissingCollaborator, one
  # spawn later.
  describe "the collaborators are required at construction" do
    it "raises ArgumentError naming the keyword the wiring forgot" do
      expect { described_class.new(recorder:, context:, slots:) }.to raise_error(ArgumentError, /provider/)
    end

    it "raises for a forgotten recorder too, before any lineage is walked" do
      expect { described_class.new(provider: Lain::Provider::Mock.new, context:, slots:) }
        .to raise_error(ArgumentError, /recorder/)
    end

    it "leaves no dry-run provider behind, since a dry pass builds none" do
      expect(Lain::Provider.const_defined?(:Unreachable, false)).to be(false)
    end

    it "keeps no MissingCollaborator: there is no nil left to check at use" do
      expect(described_class.const_defined?(:MissingCollaborator, false)).to be(false)
    end
  end
end
