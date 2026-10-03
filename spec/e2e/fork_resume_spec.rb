# frozen_string_literal: true

# A session whose skill child asked a question and got its answer, then reopened by the real
# binary two ways: forked at its head, and resumed.
RSpec.describe "forking and resuming a session whose subagent asked the human a question", :e2e do
  skill = <<~MD
    ---
    description: Ask the human which colour they like
    model: lfm2.5:latest
    ---
    Your only job is to call the ask_human tool once, with the question "Which colour do you like best?".
    After the human answers, reply with one short sentence that repeats their answer.
  MD

  once(:journey) do
    E2E::Cassette.serve("fork_resume") do |upstream, cassette|
      sandbox = E2E::Sandbox.create(files: { ".lain/skills/ask-question/skill.md" => skill })
      chat = E2E::PlainChat.start(sandbox, upstream.url, *launch_flags)
      # A role-spawn adds no parent turn, and --fork names only parent turns.
      chat.type("Reply with the single word ready and nothing else.")
      chat.session.wait_for("turn_usage", timeout: patience) { |record| record["stop_reason"] == "end_turn" }
      chat.type("@dev[/ask-question] Find out which colour I like.")
      chat.answer("green")
      chat.session.wait_for("message", timeout: patience) { |record| record.dig("payload", "final") }
      chat.quit
      session = chat.session
      name = File.basename(Dir.glob(sandbox.state_home.join("lain/sessions/*/*.ndjson").to_s).sole, ".ndjson")
      head = session.records("turn").last.fetch("digest").delete_prefix("blake3:")
      forked = reopen(sandbox, upstream, "--fork", "#{name}@#{head[0, 12]}")
      resumed = reopen(sandbox, upstream, "--resume", name)
      { cassette:, records: session.records, forked:, resumed:, parent: "#{name}.ndjson", head: "blake3:#{head}" }
    end
  end

  def launch_flags = %w[--provider ollama --model qwen3:4b --seed 1 --temperature 0 --no-nvim]

  def patience = E2E::Cassette.recording? ? 300 : 15

  def reopen(sandbox, upstream, *args)
    known = E2E::SessionFile.in(sandbox).records("session").size
    chat = E2E::PlainChat.start(E2E::Sandbox.create(share_state_with: sandbox), upstream.url, *launch_flags, *args)
    chat.quit
    { opened: E2E::SessionFile.in(sandbox).records("session").drop(known).sole }
  rescue StandardError => e
    { error: e }
  end

  it "records a child question the human answered" do
    messages = journey.fetch(:records).select { |record| record["type"] == "message" }
    payloads = messages.map { |record| record["payload"] }

    expect(payloads).to include(include("question" => "Which colour do you like best?"), { "answer" => "green" })
  end

  def reopened_from(outcome)
    raise outcome.fetch(:error) if outcome.key?(:error)

    outcome.fetch(:opened)["resumed_from"]
  end

  def expected_origin = { "file" => journey.fetch(:parent), "head" => journey.fetch(:head) }

  it "forks at the head digest, opening a session that names its parent and that digest" do
    expect(reopened_from(journey.fetch(:forked))).to eq(expected_origin)
  end

  it "resumes the session, opening one that names its parent and that digest" do
    expect(reopened_from(journey.fetch(:resumed))).to eq(expected_origin)
  end
end
