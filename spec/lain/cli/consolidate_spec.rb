# frozen_string_literal: true

require "tmpdir"

# `lain consolidate <session>`: the on-demand surface over {Lain::Consolidation}.
# It resolves a session file ONCE, reads its lineages whole, hands them to the
# clerk pass, and returns a String (only the frontend prints).
#
# Everything durable about the pass is assembled here rather than in the domain
# class: the project's memory store the clerk writes into, and the pass's own
# journal under `$XDG_STATE_HOME/lain/consolidation/<project hash>/`. Both are
# driven over a real tmp XDG tree, because "the memory reached the next chat"
# and "the refusal was recorded" are claims about files.
RSpec.describe Lain::CLI::Consolidate do
  let(:context) { Lain::Context.new(model: "clerk-model", max_tokens: 256) }
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
  let(:anthropic) { Lain::CLI::RunProfile.from_options({ provider: "anthropic" }) }

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @state = File.join(root, "state")
      @project = File.join(root, "project")
      FileUtils.mkdir_p(@project)
      @session_dir = paths.sessions_dir
      session.write(session_path)
      @slots = Lain::Prompt::Slots.load(root:)
      example.run
    end
  end

  attr_reader :slots

  def paths = Lain::Paths.new(env: { "HOME" => @root, "XDG_STATE_HOME" => @state })

  def project_dir = Lain::ProjectDir.new(root: @project, paths:)

  def session_path(name = "s1") = File.join(@session_dir, "#{name}.ndjson")

  def memory_write(id, body) = ["tu_#{id}", "memory_write", { "id" => id, "description" => "finding", "body" => body }]

  # The pass's own journal directory: the sibling of `sessions` and `status`
  # under the state home, keyed by project.
  def pass_journals
    dir = project_dir.container(Lain::CLI::Consolidate::JOURNAL_KIND)
    Dir.exist?(dir) ? Dir.children(dir).sort.map { |name| File.join(dir, name) } : []
  end

  def journaled(type)
    pass_journals.flat_map { |path| Lain::Journal.records(File.foreach(path), type:).to_a }
  end

  def consolidation(provider, recorder: Lain::Memory::Recorder.new, journal: Lain::Channel::Null.instance)
    Lain::Consolidation.new(provider:, recorder:, context:, slots:, journal:)
  end

  def cli(provider, session: "s1")
    described_class.new(path: session_path(session), profile: anthropic, project_dir:,
                        consolidation: ->(journal) { consolidation(provider, journal:) })
  end

  # Every text block across every request the provider was handed -- the
  # scaffold the clerk actually saw.
  def prompts_seen(provider)
    provider.requests.flat_map do |request|
      request.messages.flat_map { |message| Array(message["content"]).grep(Hash).map { |block| block["text"] } }
    end.compact
  end

  describe "#report" do
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
      pass = described_class.new(path: session_path, profile: anthropic, project_dir:,
                                 consolidation: ->(_journal) { raise "a dry run built the clerk" })

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
      File.write(session_path("torn"), lines.join)

      expect { cli(Lain::Provider::Mock.new, session: "torn").dry_report }
        .to raise_error(Lain::Error, /torn\.ndjson: line \d+ is torn/)
    end

    it "keeps no per-class SessionNotFound of its own" do
      expect(described_class.const_defined?(:SessionNotFound, false)).to be(false)
    end

    # A pass that CLERKED lineages but wrote no memory used to read as a plain
    # success, indistinguishable from one that stored something -- the same
    # words for a store that moved and one that did not.
    it "says the pass stored nothing when no clerk wrote a memory" do
      provider = Lain::Provider::Mock.new(responses: [
                                            text_response("A: nothing worth keeping"),
                                            text_response("B: nothing worth keeping")
                                          ])

      report = cli(provider).report

      expect(report).to include("2 lineage", "stored nothing")
    end

    it "names how many lineages were clerked and that memories were written when at least one clerk wrote" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", "a")), text_response("A done"),
                                            text_response("B: nothing worth keeping")
                                          ])

      report = cli(provider).report

      expect(report).to include("2 lineage", "memories")
      expect(report).not_to include("stored nothing")
    end

    # AC scenario 3: a session with no completed subagent lineages at all is a
    # THIRD, unchanged outcome, distinct from both "clerked and stored nothing"
    # and "clerked and wrote" -- no clerk ever spawns, so there is nothing to
    # ask the recorder about.
    it "reports no completed subagent lineages found, unchanged, when the session spawned none" do
      quiet = RecordedSpawnSession.new(parent_responses: [text_response("no spawn")], child_responses: []).run
      quiet.write(session_path("quiet"))

      report = cli(Lain::Provider::Mock.new, session: "quiet").report

      expect(report).to eq("consolidate: no completed subagent lineages found.")
    end
  end

  # The pass is not a chat, so its record is not a session: it lands in its own
  # kind beside `sessions`, keyed by project, and a reader listing this
  # project's chats never finds a clerk pass among them.
  describe "the pass keeps its own journal" do
    it "records the clerk's turn usage under the consolidation kind, keyed by project" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", "a")), text_response("A done"),
                                            tool_response(memory_write("lineage-b", "b")), text_response("B done")
                                          ])

      cli(provider).report

      expect(pass_journals.size).to eq(1)
      expect(pass_journals.first)
        .to start_with(File.join(@state, "lain", "consolidation", paths.project_hash(@project)))
      expect(journaled("turn_usage")).not_to be_empty
    end

    # A Journal that created its file and wrote no record removes it on close,
    # so a dry pass leaves nothing behind -- and, more to the point, opens no
    # file while it is still deciding whether to spawn at all.
    it "leaves no journal behind for a dry run" do
      described_class.new(path: session_path, profile: anthropic, project_dir:,
                          consolidation: ->(_journal) { raise "a dry run built the clerk" }).dry_report

      expect(pass_journals).to be_empty
    end

    it "records a refused credential-shaped write where a later reader can find it" do
      pem = "-----BEGIN PRIVATE KEY-----\nMIIB...\n-----END PRIVATE KEY-----"
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("lineage-a", pem)), text_response("A done"),
                                            tool_response(memory_write("lineage-b", "clean")), text_response("B done")
                                          ])

      cli(provider).report

      expect(journaled("write_refused").map { |record| record["pattern"] }).to eq(["pem private key block"])
    end
  end

  # The clerk's `memory_write` is the whole point of the pass, and a memory
  # that outlives nothing is not a memory. It lands in the ONE project memory
  # store, which is what the NEXT chat in this project opens its view on.
  describe "what the clerk writes is durable" do
    def backend_for(provider) = instance_double(Lain::CLI::Backend, provider:, context:, slots:)

    def from_options(options = {}, provider:)
      allow(Lain::CLI::Backend).to receive(:new).and_return(backend_for(provider))
      described_class.from_options({ max_tokens: 64, **options },
                                   selector: "s1", profile: anthropic, paths:, project_dir:)
    end

    it "lands the clerk's memory in the project store, where a fresh chat's manifest lists it" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("login-ttl", "the token TTL was zero")),
                                            text_response("clerked A"),
                                            tool_response(memory_write("retry-bound", "the retry was unbounded")),
                                            text_response("clerked B")
                                          ])

      from_options(provider:).report

      fresh = Lain::Memory::ProjectStore.new(project_dir:).view
      expect(Lain::Memory::Manifest.new(fresh.index).lines.join("\n")).to include("login-ttl", "retry-bound")
    end

    it "stamps the clerk's rows with the lineage's spawn digest" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("login-ttl", "the token TTL was zero")),
                                            text_response("clerked A"), text_response("nothing for B")
                                          ])

      from_options(provider:).report

      row = File.readlines(Lain::Memory::ProjectStore.new(project_dir:).path).map { |line| JSON.parse(line) }.last
      expect(row["author"]).to eq("kind" => "clerk", "spawn" => spawn_a)
    end

    it "writes those items to the store file itself, not only to the view the pass held" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_response(memory_write("login-ttl", "the token TTL was zero")),
                                            text_response("clerked A"), text_response("nothing for B")
                                          ])

      from_options(provider:).report

      store = Lain::Memory::ProjectStore.new(project_dir:)
      expect(File.read(store.path)).to include("login-ttl")
    end
  end

  # A release put real bytes on the record for THAT session's model; this pass
  # is a second reader, out of chat, with nobody at a surface to release
  # anything -- {CLI::ToolGuard::Unreleased}'s posture, applied to the prompt
  # instead of to a tool result.
  describe "the scaffold is masked before any provider sees it" do
    let(:secret) { "AKIAIOSFODNN7EXAMPLE" }
    let(:session) do
      RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_a", "subagent", { "prompt" => "read the deploy notes" }]),
                           text_response("orchestrated")],
        child_responses: [text_response("the deploy key is #{secret} and it works")]
      ).run
    end

    it "withholds a released credential a child echoed into its text" do
      provider = Lain::Provider::Mock.new(responses: [text_response("clerked")])

      cli(provider).report

      seen = prompts_seen(provider).join("\n")
      expect(seen).to include("<redacted:1>")
      expect(seen).not_to include(secret)
    end

    # The dry surface renders the same {Scaffold} objects the live pass asks,
    # so this bites on the masking walk rather than on the absence of a
    # transcript: the report carries the child's text, and the withheld region
    # has to be IN it.
    it "withholds it on the dry surface too, which is where a human reads the scaffold" do
      report = cli(Lain::Provider::Mock.new).dry_report

      expect(report).to include("the deploy key is <redacted:1> and it works")
      expect(report).not_to include(secret)
    end

    # The frame is lain's own, and a turn digest is a high-entropy token the
    # detector would withhold: a scaffold that asked the clerk to cite evidence
    # it had just masked would be useless. So only the RECORD's bytes are
    # masked, never the lineage address around them.
    it "leaves the lineage spawn the clerk is told to cite intact" do
      provider = Lain::Provider::Mock.new(responses: [text_response("clerked")])

      cli(provider).report

      expect(prompts_seen(provider).join("\n")).to include(lineages.first.spawn.digest)
    end
  end

  # Project memory and compaction are separate subsystems. A cut's replacement
  # text is a derived view of the chat's own history, and a clerk that read one
  # would distill a SUMMARY into durable memory and cite it as what the chat
  # said.
  describe "a compaction replacement never reaches the clerk" do
    it "renders no part of a compaction_cut the source session recorded" do
      cut = { "ts" => "2026-09-15T00:00:00.000000Z", "type" => "compaction_cut", "digest" => spawn_a,
              "head" => spawn_b, "strategy" => "summarize", "kind" => "handoff", "parent" => nil,
              "supersedes" => [], "plan_step_completions" => 0,
              "collapses" => [{ "span" => [spawn_a, spawn_b],
                                "content" => [{ "type" => "text", "text" => "SUMMARY-MARKER" }] }] }
      File.write(session_path("cut"), session.lines.join + "#{JSON.generate(cut)}\n")

      expect(cli(Lain::Provider::Mock.new, session: "cut").dry_report).not_to include("SUMMARY-MARKER")
    end
  end

  describe ".from_options" do
    # The session under review, re-headed as a chat run on this profile.
    def recorded_on(profile)
      records = File.readlines(session_path).map { |line| JSON.parse(line) }
      reheaded = records.map { |record| record["type"] == "session" ? record.merge(profile) : record }
      File.write(session_path, reheaded.map { |record| JSON.generate(record) }.join("\n"))
    end

    def from_options(options, profile: Lain::CLI::RunProfile.from_options(options))
      described_class.from_options({ max_tokens: 64, **options },
                                   selector: "s1", profile:, paths:, project_dir:)
    end

    def untyped = Lain::CLI::RunProfile.from_options({}).with_defaults(provider: "anthropic")

    before { allow(Lain::CLI::Backend).to receive(:new).and_call_original }

    # The environment's default provider is what an untyped flag holds by the
    # time it reaches here, and the recording still outranks it.
    it "follows the provider the session recorded when none was typed" do
      recorded_on("provider" => "ollama", "model" => "qwen3:4b")

      expect(from_options({}, profile: untyped).dry_report)
        .to start_with("consolidate: would run on ollama, model qwen3:4b")
    end

    it "builds the live clerk over that same profile" do
      recorded_on("provider" => "ollama", "model" => "qwen3:4b")
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" },
                   body: "#{JSON.generate("model" => "qwen3:4b", "done" => true, "done_reason" => "stop",
                                          "message" => { "role" => "assistant", "content" => "clerked" })}\n")

      from_options({}, profile: untyped).report

      expect(Lain::CLI::Backend).to have_received(:new)
        .with(anything, profile: have_attributes(provider: "ollama", model: "qwen3:4b"), root: @project)
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
        from_options({}, profile: untyped).dry_report
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
      expect { described_class.from_options({ max_tokens: 64 }, selector: "nope", paths:, project_dir:) }
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
