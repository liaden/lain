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
        .to eq(improve.send(:guard_stack).to_a.map(&:class))
    end
  end

  describe ".dry_run" do
    it "names the lineages that would be clerked, asked of the class so nothing is built" do
      report = described_class.dry_run(lineages)

      expect(report).to include(spawn_a, spawn_b)
      expect(report).to include("2 lineage")
    end

    it "says so when a session holds no completed subagent lineages" do
      expect(described_class.dry_run([])).to include("no completed subagent lineages")
    end
  end

  # The on-demand CLI surface: it resolves a session file once, reads its
  # lineages whole, and hands them to the pass, returning a String (only the
  # frontend prints).
  describe Lain::CLI::Consolidate do
    let(:paths) { instance_double(Lain::Paths, sessions_dir: @session_dir) }
    let(:anthropic) { Lain::CLI::RunProfile.from_options({ provider: "anthropic" }) }

    around do |example|
      Dir.mktmpdir do |session_dir|
        @session_dir = session_dir
        session.write(File.join(session_dir, "s1.ndjson"))
        example.run
      end
    end

    def cli(provider, session: "s1")
      described_class.new(path: File.join(@session_dir, "#{session}.ndjson"), profile: anthropic,
                          consolidation: -> { consolidation(provider) })
    end

    it "renders the clerk outcomes for the session it was given" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", "a")), text_response("A done"),
                                            tool_response(memory_write("lineage-b", "b")), text_response("B done")
                                          ])

      report = cli(provider).report

      expect(report).to include("2 lineage", spawn_a, spawn_b, "A done", "B done")
    end

    # A separate METHOD, not `report(dry_run: true)`: the dry surface reports on
    # a different half of the pass, and a pass that is never BUILT proves "no
    # spawn" by construction rather than by counting calls afterwards.
    it "renders the dry-run plan without building the pass" do
      pass = described_class.new(path: File.join(@session_dir, "s1.ndjson"), profile: anthropic,
                                 consolidation: -> { raise "a dry run built the clerk" })

      expect(pass.dry_report).to include("would each get one court_clerk pass", "2 lineage(s)", spawn_a, spawn_b)
    end

    it "names the backend a dry run would clerk on" do
      expect(cli(Lain::Provider::Mock.new).dry_report)
        .to start_with("consolidate: would run on anthropic, model the provider's default")
    end

    # A Lain::Error, which the exe maps to a refusal and exit status 1. Reading
    # past the damage would report fewer lineages than the chat ran, with nothing
    # to say why.
    it "refuses a session with a torn child_turn line, naming the file and the damage" do
      lines = session.lines
      torn = lines.index { |line| JSON.parse(line)["type"] == Lain::SessionRecord::CHILD_TURN_TYPE }
      lines[torn] = "#{lines[torn][0, 40]}\n"
      File.write(File.join(@session_dir, "torn.ndjson"), lines.join)

      expect { cli(Lain::Provider::Mock.new, session: "torn").dry_report }
        .to raise_error(Lain::Error, /torn\.ndjson: line \d+ is torn/)
    end

    it "keeps no per-class SessionNotFound of its own" do
      expect(described_class.const_defined?(:SessionNotFound, false)).to be(false)
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

      before { allow(Lain::CLI::Backend).to receive(:new).and_call_original }

      # The environment's default provider is what an untyped flag holds by the
      # time it reaches here, and the recording still outranks it.
      it "follows the provider the session recorded when none was typed" do
        recorded_on("provider" => "ollama", "model" => "qwen3:4b")
        untyped = Lain::CLI::RunProfile.from_options({}).with_defaults(provider: "anthropic")

        expect(from_options({}, profile: untyped).dry_report)
          .to start_with("consolidate: would run on ollama, model qwen3:4b")
      end

      it "builds the live clerk over that same profile" do
        recorded_on("provider" => "ollama", "model" => "qwen3:4b")
        stub_request(:post, "http://localhost:11434/api/chat")
          .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" },
                     body: "#{JSON.generate("model" => "qwen3:4b", "done" => true, "done_reason" => "stop",
                                            "message" => { "role" => "assistant", "content" => "clerked" })}\n")

        from_options({}, profile: Lain::CLI::RunProfile.from_options({}).with_defaults(provider: "anthropic")).report

        expect(Lain::CLI::Backend).to have_received(:new)
          .with(anything, profile: have_attributes(provider: "ollama", model: "qwen3:4b"))
      end

      it "lets a typed provider win, and says so ahead of the report" do
        recorded_on("provider" => "ollama", "model" => "qwen3:4b")

        report = from_options({ provider: "anthropic" }).dry_report

        expect(report.lines.first).to include("recorded with provider ollama; continuing with anthropic")
        expect(report).to include("would run on anthropic")
      end

      it "says nothing about the profile when the typed flags agree with the recording" do
        recorded_on("provider" => "ollama")

        expect(from_options({ provider: "ollama" }).dry_report).not_to include("recorded with")
      end

      # The dry run's promise is no key: a session recorded on the hosted arm
      # must still print its plan on a box that holds no credential for it.
      it "dry-runs a session recorded on ollama-cloud with no OLLAMA_API_KEY, building no backend" do
        recorded_on("provider" => "ollama-cloud", "model" => "gpt-oss:120b")

        report = with_env("OLLAMA_API_KEY" => nil, "ANTHROPIC_API_KEY" => nil) do
          from_options({}, profile: Lain::CLI::RunProfile.from_options({}).with_defaults(provider: "anthropic"))
            .dry_report
        end

        expect(report).to include("would run on ollama-cloud", "would each get one court_clerk pass")
        expect(Lain::CLI::Backend).not_to have_received(:new)
      end

      # Building no backend is not the same as checking no flag: a typo in the
      # provider's name is refused by name on a dry run too, still without a
      # key or a tier.
      it "refuses a mistyped --provider by name on a dry run, building no backend" do
        report = lambda do
          with_env("ANTHROPIC_API_KEY" => nil, "OLLAMA_API_KEY" => nil) do
            from_options({ provider: "olama" }).dry_report
          end
        end

        expect(&report).to raise_error(Lain::CLI::UnknownProvider, /unknown provider "olama", expected one of.*ollama/)
        expect(Lain::CLI::Backend).not_to have_received(:new)
      end

      it "refuses an unknown session before it reads anything else" do
        expect { described_class.from_options({ max_tokens: 64 }, selector: "nope", paths:) }
          .to raise_error(Lain::CLI::SessionFile::SessionNotFound, /nope/)
      end

      # Resolved once: the file the profile was read from is the file the
      # lineages are read from, whatever lands in the directory in between.
      it "reads the lineages from the file it resolved, not from a second resolution" do
        pass = from_options({ provider: "anthropic" })
        File.write(File.join(@session_dir, "s1"), "a file the selector would now resolve to first\n")

        expect(pass.dry_report).to include("2 lineage(s)", spawn_a, spawn_b)
      end
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
