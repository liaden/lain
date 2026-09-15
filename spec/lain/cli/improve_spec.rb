# frozen_string_literal: true

require "tmpdir"

# The harness-improver pass. Offline, it renders a session's
# {Lain::Friction::Report} plus a per-turn digest summary into the
# `harness_improver` role scaffold and spawns the role ONCE (a one-shot). The
# improver's notes land in the cross-project {Lain::Improvement::Sink}, guarded
# by a dispatch chain THIS class builds with {Middleware::RefuseSecretWrites}
# mounted (the spawn seam supplies no tool middleware). Distinct from
# {CLI::Friction} by AUDIENCE: that pass tells the USER which knob to turn;
# this one tells the lain DEV what lain should grow.
RSpec.describe Lain::CLI::Improve do
  # The committed friction fixture's conversation as the session under review:
  # it produces two real friction signals (rephrase_loop on bash, tool_steering
  # on grep), so the scaffold carries genuine signal lines to assert on. The
  # fixture's own digests are placeholders a report spec asserts on, and this
  # pass reads a session whole, so its turns are re-committed to real content
  # addresses here rather than copied.
  def fixture_path = File.join(__dir__, "..", "..", "fixtures", "friction", "frustrating.ndjson")

  def write_frustrating_session(path)
    header, *turns = File.foreach(fixture_path).map { |line| JSON.parse(line) }
    toolset = Lain::Bench::Session::RecordedToolset.new(schema: header["tools"])
    records = Lain::Bench::Session.write([], timeline: recommitted(turns), context: recorded_context(header), toolset:)
    File.write(path, records.map { |record| JSON.generate(record) }.join("\n"))
  end

  def recommitted(turns)
    turns.inject(Lain::Timeline.empty) do |chain, turn|
      chain.commit(role: turn.fetch("role").to_sym, content: turn.fetch("content"), meta: turn.fetch("meta"))
    end
  end

  def recorded_context(header)
    Lain::Context.new(model: header.fetch("model"), max_tokens: header.fetch("max_tokens"), system: header["system"])
  end

  let(:context) { Lain::Context.new(model: "improver-model", max_tokens: 256) }
  let(:journal) { [] }
  let(:project_hash) { "proj-abc123" }
  let(:paths) do
    instance_double(Lain::Paths, sessions_dir: @session_dir, improvements_path: @improvements_path,
                                 project_hash:)
  end

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @session_dir = File.join(root, "sessions")
      @improvements_path = File.join(root, "improvements.ndjson")
      FileUtils.mkdir_p(@session_dir)
      write_frustrating_session(File.join(@session_dir, "s1.ndjson"))
      @slots = Lain::Prompt::Slots.load(root:)
      example.run
    end
  end

  attr_reader :slots

  def improve(provider, session: "s1")
    described_class.new(path: File.join(@session_dir, "#{session}.ndjson"), journal:, paths:,
                        profile: Lain::CLI::RunProfile.from_options({ provider: "anthropic" }),
                        backend: -> { instance_double(Lain::CLI::Backend, provider:, context:, slots:) })
  end

  # A pass whose backend is never built: a dry report that reached for one fails.
  def dry(session = "s1")
    described_class.new(path: File.join(@session_dir, "#{session}.ndjson"), journal:, paths:,
                        profile: Lain::CLI::RunProfile.from_options({ provider: "anthropic" }),
                        backend: -> { raise "a dry run built the improver's backend" })
  end

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

      report = improve(provider).report

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

      improve(provider).report

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

      improve(provider).report

      # The PEM write was withheld before the sink; the clean note landed.
      expect(written_improvements.map { |record| record["note"] }).to eq(["a clean knob note"])

      refusals = journal.select do |entry|
        entry.respond_to?(:to_journal) && entry.to_journal["type"] == "write_refused"
      end
      expect(refusals.size).to eq(1)
      expect(refusals.first.to_journal["pattern"]).to eq("pem private key block")
    end
  end

  # The improver reads the session's files, and nobody is at an out-of-chat
  # surface to release a credential region it finds there.
  describe "the read guard masks what the improver reads" do
    let(:secret) { "AKIAIOSFODNN7EXAMPLE" }

    def blocks_sent(provider) = provider.requests.flat_map { |request| request.messages.flat_map { |m| m["content"] } }

    def result_of(provider, id)
      block = blocks_sent(provider).grep(Hash).find { |b| b["type"] == "tool_result" && b["tool_use_id"] == id }
      Array(block.fetch("content")).map { |part| part.is_a?(Hash) ? part["text"] : part }.join("\n")
    end

    it "masks a credential region in a file the improver reads" do
      path = File.join(@root, "creds.txt")
      File.write(path, "harmless line\naws_access_key_id = #{secret}\ntail\n")
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_r", "read_file", { "path" => path }]),
                                                      text_response("done")])

      improve(provider).report

      expect(result_of(provider, "tu_r")).to include("<redacted:1>")
      expect(result_of(provider, "tu_r")).not_to include(secret)
    end
  end

  # A separate METHOD, not `report(dry_run: true)`: a boolean that changes what a
  # method means is the smell, and the dry surface renders a different sentence
  # from a different half of the pass.
  describe "#dry_report" do
    it "renders the scaffold the improver would see, building no backend" do
      report = dry.dry_report

      expect(report).to include("would review session s1")
      expect(report).to include("rephrase_loop") # the friction render is present
      expect(written_improvements).to be_empty
    end
  end

  # A subagent's turns are no `turn` records -- the chat recorded them as
  # `child_turn`s under a `:spawn` -- so the summary reads them through the
  # session's lineages, or the improver never sees the work a child did.
  describe "a session that spawned a subagent" do
    let(:spawned) do
      RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_s", "subagent", { "prompt" => "survey the flaky specs" }]),
                           text_response("parent done")],
        child_responses: [tool_response(["tu_e", "echo", { "text" => "spec/a_spec.rb" }]),
                          text_response("one flaky spec")]
      ).run
    end

    def child_digests = spawned.of_type(Lain::SessionRecord::CHILD_TURN_TYPE).map { |record| record["digest"] }

    it "summarizes each child's turns by digest under the parent turn that spawned it" do
      spawned.write(File.join(@session_dir, "s2.ndjson"))
      spawn = spawned.of_type("message").find { |record| record["kind"] == "spawn" }

      report = dry("s2").dry_report

      expect(report).to include(*child_digests, "survey the flaky specs", "called echo", "one flaky spec")
      expect(report).to include("spawned from #{spawn.dig("payload", "spawned_from")}")
    end

    it "reviews a resumed session that spawned, listing the child it ran" do
      prior = RecordedSpawnSession.new(parent_responses: [text_response("hello")], child_responses: []).run
      prior.write(File.join(@session_dir, "prior.ndjson"))
      resumed = RecordedSpawnSession.new(
        resuming: [prior, "prior.ndjson"],
        parent_responses: [tool_response(["tu_s", "subagent", { "prompt" => "resumed child" }]), text_response("ok")],
        child_responses: [text_response("resumed child done")]
      ).run("again")
      resumed.write(File.join(@session_dir, "resumed.ndjson"))

      expect(dry("resumed").dry_report)
        .to include("would review session resumed", "resumed child done")
    end

    it "reviews a live session whose child is still running, listing the child that completed" do
      live = RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_a", "subagent", { "prompt" => "first" }]),
                           tool_response(["tu_b", "subagent", { "prompt" => "second" }]), text_response("done")],
        child_responses: [text_response("first done"), tool_response(["tu_snap", "snapshot", {}]),
                          text_response("second done")]
      ).run
      File.write(File.join(@session_dir, "live.ndjson"), live.snapshots.first)

      report = dry("live").dry_report

      expect(report).to include("first done")
      expect(report).not_to include("second done")
    end

    it "refuses a session whose child_turn line is torn, naming the file" do
      lines = spawned.lines
      torn = lines.index { |line| JSON.parse(line)["type"] == Lain::SessionRecord::CHILD_TURN_TYPE }
      lines[torn] = "#{lines[torn][0, 40]}\n"
      File.write(File.join(@session_dir, "torn.ndjson"), lines.join)

      expect { dry("torn").dry_report }
        .to raise_error(Lain::Error, /torn\.ndjson: /)
    end
  end

  # The four-nils smell, removed: a dry run builds no backend at all, so every
  # collaborator can be required and a mis-wire is loud where it happened.
  describe "the collaborators are required at construction" do
    it "raises ArgumentError naming the keyword the wiring forgot" do
      expect { described_class.new(path: "s1.ndjson", profile: Lain::CLI::RunProfile::UNRECORDED) }
        .to raise_error(ArgumentError, /backend/)
    end

    it "keeps no MissingCollaborator: there is no nil left to check at use" do
      expect(described_class.const_defined?(:MissingCollaborator, false)).to be(false)
    end
  end

  describe ".from_options" do
    # The session under review, re-headed as a chat run on this profile.
    def recorded_on(profile)
      path = File.join(@session_dir, "s1.ndjson")
      records = File.readlines(path).map { |line| JSON.parse(line) }
                                    .map { |record| record["type"] == "session" ? record.merge(profile) : record }
      File.write(path, records.map { |record| JSON.generate(record) }.join("\n"))
    end

    def from_options(options, profile: Lain::CLI::RunProfile.from_options(options))
      described_class.from_options({ max_tokens: 64, **options }, selector: "s1", profile:, paths:)
    end

    def untyped = Lain::CLI::RunProfile.from_options({}).with_defaults(provider: "anthropic")

    before { allow(Lain::CLI::Backend).to receive(:new).and_call_original }

    it "follows the provider the session recorded when none was typed" do
      recorded_on("provider" => "ollama", "model" => "qwen3:4b")

      expect(from_options({}, profile: untyped).dry_report).to include("on ollama, model qwen3:4b (provider untouched)")
    end

    it "builds the live improver over that same profile" do
      recorded_on("provider" => "ollama", "model" => "qwen3:4b")
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" },
                   body: "#{JSON.generate("model" => "qwen3:4b", "done" => true, "done_reason" => "stop",
                                          "message" => { "role" => "assistant", "content" => "nothing to note" })}\n")

      expect(from_options({}, profile: untyped).report).to include("nothing to note")
      expect(Lain::CLI::Backend).to have_received(:new)
        .with(anything, profile: have_attributes(provider: "ollama", model: "qwen3:4b"))
    end

    it "lets a typed provider win, and says so ahead of the report" do
      recorded_on("provider" => "ollama", "model" => "qwen3:4b")

      report = from_options({ provider: "anthropic" }).dry_report

      expect(report.lines.first).to include("recorded with provider ollama; continuing with anthropic")
      expect(report).to include("on anthropic, model the provider's default")
    end

    # The dry run's promise is no key: a session recorded on the hosted arm
    # must still print its scaffold on a box that holds no credential for it.
    it "dry-runs a session recorded on ollama-cloud with no OLLAMA_API_KEY, building no backend" do
      recorded_on("provider" => "ollama-cloud", "model" => "gpt-oss:120b")

      report = with_env("OLLAMA_API_KEY" => nil, "ANTHROPIC_API_KEY" => nil) do
        from_options({}, profile: untyped).dry_report
      end

      expect(report).to include("would review session s1 on ollama-cloud", "rephrase_loop")
      expect(Lain::CLI::Backend).not_to have_received(:new)
    end

    it "refuses a mistyped --provider by name on a dry run, building no backend" do
      expect { from_options({ provider: "olama" }).dry_report }
        .to raise_error(Lain::CLI::UnknownProvider, /unknown provider "olama", expected one of.*ollama/)
      expect(Lain::CLI::Backend).not_to have_received(:new)
    end

    it "reads the scaffold from the file it resolved, not from a second resolution" do
      pass = from_options({ provider: "anthropic" })
      File.write(File.join(@session_dir, "s1"), "a file the selector would now resolve to first\n")

      expect(pass.dry_report).to include("would review session s1 ", "rephrase_loop")
    end
  end

  describe "resolution" do
    it "raises the shared SessionFile refusal, listing what it looked at" do
      expect { described_class.from_options({ max_tokens: 64 }, selector: "nope", paths:) }
        .to raise_error(Lain::CLI::SessionFile::SessionNotFound, /nope/)
    end

    it "keeps no per-class SessionNotFound of its own" do
      expect(described_class.const_defined?(:SessionNotFound, false)).to be(false)
    end
  end
end
