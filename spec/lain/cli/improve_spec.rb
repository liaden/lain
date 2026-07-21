# frozen_string_literal: true

require "tmpdir"

# M6: the harness-improver pass. Offline, it renders a session's
# {Lain::Friction::Report} plus a per-turn digest summary into the
# `harness_improver` role scaffold and spawns the role ONCE (a one-shot). The
# improver's notes land in M2's cross-project {Lain::Improvement::Sink}, guarded
# by a dispatch chain THIS class builds with {Middleware::RefuseSecretWrites}
# mounted (the spawn seam supplies no tool middleware). Distinct from M1's
# {CLI::Friction} by AUDIENCE: M1 tells the USER which knob to turn; M6 tells the
# lain DEV what lain should grow.
RSpec.describe Lain::CLI::Improve do
  # The committed friction fixture reused as the session under review: it
  # produces two real friction signals (rephrase_loop on bash, tool_steering on
  # grep), so the scaffold carries genuine signal lines to assert on.
  def fixture_path = File.join(__dir__, "..", "..", "fixtures", "friction", "frustrating.ndjson")

  let(:context) { Lain::Context.new(model: "improver-model", max_tokens: 256) }
  let(:journal) { [] }
  let(:project_hash) { "proj-abc123" }

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @session_dir = File.join(root, "sessions")
      @improvements_path = File.join(root, "improvements.ndjson")
      FileUtils.mkdir_p(@session_dir)
      FileUtils.cp(fixture_path, File.join(@session_dir, "s1.ndjson"))
      @slots = Lain::Prompt::Slots.load(root:)
      example.run
    end
  end

  attr_reader :slots

  let(:paths) do
    instance_double(Lain::Paths, sessions_dir: @session_dir, improvements_path: @improvements_path,
                                 project_hash:)
  end

  def improve(provider) = described_class.new(provider:, context:, slots:, journal:, paths:)

  # An [id, name, input] triple naming an improvement_write for the mock to emit.
  def improvement_write(id, note, kind: "knob", evidence: "")
    ["tu_#{id}", "improvement_write", { "note" => note, "kind" => kind, "evidence_digests" => evidence }]
  end

  def written_improvements
    return [] unless File.exist?(@improvements_path)

    File.foreach(@improvements_path).map { |line| JSON.parse(line) }
  end

  # Every text block across every request the provider was handed -- the scaffold
  # the improver actually saw.
  def prompts_seen(provider)
    provider.requests.flat_map do |request|
      request.messages.flat_map { |message| Array(message["content"]).grep(Hash).map { |block| block["text"] } }
    end.compact
  end

  describe "a dogfood pass records improver notes" do
    it "lands two improvement records carrying the project hash and session id" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(improvement_write("k1", "add an approval-queue timeout knob",
                                                                            evidence: "d-t8")),
                                            tool_response(improvement_write("k2", "grep description over-claims",
                                                                            kind: "doc", evidence: "d-t5")),
                                            text_response("recorded two improvements")
                                          ])

      report = improve(provider).report_for("s1")

      records = written_improvements
      expect(records.size).to eq(2)
      expect(records.map { |record| record["project_hash"] }).to all(eq(project_hash))
      expect(records.map { |record| record["session"] }).to all(eq("s1"))
      expect(records.map { |record| record["note"] })
        .to contain_exactly("add an approval-queue timeout knob", "grep description over-claims")
      expect(report).to include("harness_improver pass over session s1")
    end

    it "the spawned prompt contains the friction report's signal lines" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(improvement_write("k1", "a note")),
                                            text_response("done")
                                          ])

      improve(provider).report_for("s1")

      seen = prompts_seen(provider)
      expect(seen.any? { |text| text.include?("rephrase_loop") }).to be(true)
      expect(seen.any? { |text| text.include?("tool_steering") }).to be(true)
      # The whole {Friction::Report} render is embedded verbatim, so the two
      # surfaces cannot drift.
      expected = Lain::Friction::Report.new(
        Lain::Journal.records(File.foreach(File.join(@session_dir, "s1.ndjson"))).to_a
      ).render
      expect(seen.any? { |text| text.include?(expected) }).to be(true)
    end
  end

  describe "the improver cannot write memories" do
    # A named capability the union can hold, without wiring the recorder-bearing
    # real tools (role_spec's idiom).
    def tool(named)
      Class.new(Lain::Tool) do
        define_method(:name) { named.to_s }
        define_method(:description) { "the #{named} capability" }
        define_method(:input_schema) { { type: :object, properties: {} } }
        define_method(:perform) { |_input, _invocation| Lain::Tool::Result.ok("ok") }
      end.new
    end

    it "attenuates to improvement_write, never memory_write" do
      role = Lain::Role::Catalog.fetch(:harness_improver)
      union = Lain::Toolset.new(
        %i[read_file list_files glob grep improvement_write memory_write memory_read].map { |name| tool(name) }
      )

      names = role.attenuate(union).names

      expect(names).to include("read_file", "list_files", "glob", "grep")
      expect(names).to include("improvement_write")
      expect(names).not_to include("memory_write")
    end
  end

  describe "the secret guard gates the improver's writes" do
    let(:pem) { "-----BEGIN PRIVATE KEY-----\nMIIB...\n-----END PRIVATE KEY-----" }

    it "refuses a credential-shaped write with the standard telemetry and continues the pass" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(improvement_write("k1", pem)),
                                            tool_response(improvement_write("k2", "a clean knob note")),
                                            text_response("done")
                                          ])

      improve(provider).report_for("s1")

      # The PEM write was withheld before the sink; the clean note landed.
      expect(written_improvements.map { |record| record["note"] }).to eq(["a clean knob note"])

      refusals = journal.select do |entry|
        entry.respond_to?(:to_journal) && entry.to_journal["type"] == "write_refused"
      end
      expect(refusals.size).to eq(1)
      expect(refusals.first.to_journal["pattern"]).to eq("pem private key block")
    end
  end

  describe "#report_for --dry-run" do
    it "renders the scaffold the improver would see without touching the provider" do
      provider = Lain::Provider::Mock.new(responses: [])

      report = improve(provider).report_for("s1", dry_run: true)

      expect(report).to include("would review session s1")
      expect(report).to include("rephrase_loop") # the friction render is present
      expect(provider.call_count).to eq(0)
      expect(written_improvements).to be_empty
    end
  end

  describe "resolution" do
    it "raises a loud, listing error when no session file resolves" do
      expect { improve(Lain::Provider::Mock.new).report_for("nope") }
        .to raise_error(Lain::CLI::Improve::SessionNotFound, /nope/)
    end
  end
end
