# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module AgendaViewSpecSupport
  Credential = Struct.new(:token)
end

# What a phone is shown of each agenda item: every text field masked for the
# board's known secrets and for any region the detector finds, and nothing of a
# call whose yes would release a file's sensitive regions.
RSpec.describe Lain::Remote::Agenda::View, :seam do
  around do |example|
    Dir.mktmpdir("agenda-view") do |dir|
      base = File.realpath(dir)
      @home = File.join(base, "home")
      @root = File.join(base, "repo")
      FileUtils.mkdir_p([@home, @root])
      SeedRepo.git(@root, "init", "-q")
      example.run
    end
  end

  let(:known) { "plumharbor4417" }
  let(:token) { "ghp_6Fz9qL2vX8mN4pR7tY1wK3sD5hJ0aB2cE4gI" }
  let(:queue) { Lain::Approval::Parked::Queue.new(journal: Lain::Journal.new(io: StringIO.new)) }
  let(:agenda) do
    Lain::Remote::Agenda.new(queue:, gates: [], replies: instance_double(Lain::CLI::HumanReplies, waiting: []))
  end
  let(:asked_at) { Time.utc(2026, 11, 4, 9, 0, 0) }

  # The board's own secrets source, built the way a chat builds it, over a .env holding `known`.
  def board_secrets
    File.write(File.join(@root, ".env"), "DB_PASSWORD=#{known}\n")
    project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)
    policy = Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: @home, cwd: @root, root: @root), home: @home, root: @root
    )
    Lain::CLI::Wiring::BoardBuild.secrets(project:, sensitivity: policy, child_env: Lain::Exec::ChildEnv.new(env: {}))
  end

  def bash(command) = Lain::Effect::ToolCall.new(tool_use_id: "tu_bash", name: "bash", input: { "command" => command })

  def listed(*parks)
    calls = []
    Sync do |task|
      parks.each { |park| task.async { park.call } }
      task.yield
      calls = agenda.snapshot
      @parked = queue.to_a
    ensure
      task.stop
    end
    calls
  end

  def strings(value)
    case value
    when String then [value]
    when Hash then value.flat_map { |key, inner| strings(key) + strings(inner) }
    when Array then value.flat_map { strings(_1) }
    else [value.to_s]
    end
  end

  def rendered(item) = strings(item.to_h)

  describe "a known secret in a command" do
    it "is masked, with the rest of the command intact" do
      secrets = board_secrets
      call, = listed(-> { queue.call(bash("deploy --password #{known} --region eu"), nil) })

      expect(described_class.of(call, secrets:).input).to eq("command" => "deploy --password <redacted:1> --region eu")
    end

    it "is shown when the board does not know it, so the board's secrets are what masked it" do
      call, = listed(-> { queue.call(bash("deploy --password #{known} --region eu"), nil) })

      expect(described_class.of(call, secrets: Lain::Sensitivity::Secrets::Source::DEFAULT).input)
        .to eq("command" => "deploy --password #{known} --region eu")
    end
  end

  describe "a literal key typed into a command" do
    it "is masked by the region detector" do
      call, = listed(-> { queue.call(bash("curl -H 'Authorization: Bearer #{token}'"), nil) })

      expect(described_class.of(call, secrets: Lain::Sensitivity::Secrets::Source::DEFAULT).input)
        .to eq("command" => "curl -H 'Authorization: Bearer <redacted:1>'")
    end
  end

  describe "a call whose yes would release a file's sensitive regions" do
    it "is left off the phone, and still waits at the desk" do
      path = File.join(@root, ".env")
      read = Lain::Effect::ToolCall.new(tool_use_id: "tu_read", name: "read_file", input: { "path" => path })
      outstanding = Lain::Approval::Parked::Queue::Outstanding.new(path:, regions: Lain::Sensitivity::Regions.detect(
        "TOKEN=#{token}\n"
      ))
      call, = listed(-> { queue.adjudicate(read, nil, outstanding:) })

      expect(call).to have_attributes(tool: "read_file", releases: 1)
      expect(described_class.of(call, secrets: Lain::Sensitivity::Secrets::Source::DEFAULT)).to be_nil
    end
  end

  describe "a value in a call's input that is not a String" do
    def shown(input)
      call = Lain::Remote::Agenda::ParkedCall.new(id: "1", requester: "agent", tool: "bash", input:, cwd: @root,
                                                  why: "", asked_at:, releases: 0)
      described_class.of(call, secrets: [known])
    end

    it "masks a Symbol value" do
      expect(rendered(shown({ "command" => token.to_sym }))).not_to include(a_string_including(token))
    end

    it "masks a Symbol key holding a known secret" do
      expect(rendered(shown({ known.to_sym => 1 }))).not_to include(a_string_including(known))
    end

    it "masks a Struct" do
      expect(rendered(shown({ "auth" => AgendaViewSpecSupport::Credential.new(token) })))
        .not_to include(a_string_including(token))
    end

    it "keeps a number, a time, true, false and nil as they are" do
      kept = { "n" => 4417, "ratio" => 0.5, "at" => asked_at, "on" => true, "off" => false, "none" => nil }

      expect(shown(kept).input).to eq(kept)
    end
  end

  describe "a humans-only call" do
    it "goes to the phone, because humans_only? bars an oracle and the phone is a human" do
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: @root, env: {}))
      barred = Lain::Middleware::WithholdAutomaticOutput::Carried.new(session, barred: true)
      call, = listed(-> { queue.call(bash("cargo test"), barred) })

      expect(@parked.map(&:humans_only?)).to eq([true])
      expect(described_class.of(call, secrets: Lain::Sensitivity::Secrets::Source::DEFAULT))
        .to have_attributes(tool: "bash", input: { "command" => "cargo test" })
    end
  end

  describe "the phone is off this box" do
    def unreadable_gate
      error = Lain::CLI::SessionJournals::Unreadable.io(
        "/home/me/.local/state/lain/sessions/s1.ndjson", StandardError.new("unexpected token at 'PASSWORD=#{known}'")
      )
      Lain::Remote::Agenda::GateQuestion.new(id: "5", requester: "epic gate", epic: "", stage: "", issues: [],
                                             question: error.message, asked_at:, releases: 0, digests: [])
    end

    def items
      both = "#{known} and #{token}"
      [Lain::Remote::Agenda::ParkedCall.new(id: "1", requester: "agent-#{token}", tool: "mcp__#{token}",
                                            input: { "command" => both, "env" => { "X_#{token}" => "1" } },
                                            cwd: File.join(@root, known), why: "it named #{both}", asked_at:,
                                            releases: 0),
       Lain::Remote::Agenda::ParkedCall.new(id: "2", requester: "agent", tool: "edit_file",
                                            input: { "path" => "config/#{known}.yml", "old_text" => "x",
                                                     "new_text" => "pass: #{known}\nkey: #{token}\n" },
                                            cwd: @root, why: "", asked_at:, releases: 0),
       Lain::Remote::Agenda::GateQuestion.new(id: "3", requester: "epic gate", epic: "alpha", stage: "issue_plan",
                                              issues: %w[a], question: "Ship #{both}?", asked_at:,
                                              releases: 0, digests: %w[d1]),
       Lain::Remote::Agenda::Question.new(id: "4", requester: "researcher", question: "Is #{both} live?",
                                          options: ["yes, #{both}"], asked_at:, releases: 0),
       unreadable_gate]
    end

    it "shows neither a known secret nor a typed key in any field of any item kind" do
      secrets = board_secrets
      shown = items.map { described_class.of(_1, secrets:) }

      expect(items.map { rendered(_1).join("\n") }).to all(include(known))
      expect(shown.flat_map { rendered(_1) }).to all(satisfy { !_1.include?(known) && !_1.include?(token) })
    end

    it "keeps each item's kind, id and time, frozen all the way down" do
      shown = items.map { described_class.of(_1, secrets: board_secrets) }

      expect(shown.map { [_1.class, _1.id, _1.asked_at] }).to eq(items.map { [_1.class, _1.id, _1.asked_at] })
      expect(shown).to all(satisfy { Ractor.shareable?(_1) })
    end

    it "shows the unreadable gate's journal path and what went wrong, with the secret masked" do
      shown = described_class.of(unreadable_gate, secrets: board_secrets)

      expect(shown.question).to eq("cannot read the session journal /home/me/.local/state/lain/sessions/s1.ndjson: " \
                                   "unexpected token at 'PASSWORD=<redacted:1>'")
    end
  end
end
