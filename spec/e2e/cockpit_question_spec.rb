# frozen_string_literal: true

# A real `lain up` cockpit whose skill child, on a second local model, asks the human a question:
# the question parks in nvim's inbox, is answered there, and every reader of the inbox then agrees.
RSpec.describe "answering a subagent's question in a real cockpit", :e2e do
  skill = <<~MD
    ---
    description: Ask the human which colour they like
    model: lfm2.5:latest
    ---
    Your only job is to call the ask_human tool once, with the question "Which colour do you like best?".
    After the human answers, reply with one short sentence that repeats their answer.
  MD

  def question = "Which colour do you like best?"

  def flags = %w[--provider ollama --model qwen3:4b --seed 1 --temperature 0]

  def patience = E2E::Cassette.recording? ? 300 : 20

  def inbox_lines(cockpit) = cockpit.editor.evaluate("getbufline(bufnr('#{E2E::Cockpit::INBOX_BUFFER}'), 1, '$')")

  def inbox_count(cockpit) = cockpit.state.fetch("inbox_count")

  def fleet_size(cockpit) = cockpit.state.fetch("fleet").size

  def finished?(cockpit)
    cockpit.session.records("message").any? { |record| record.dig("payload", "final") }
  end

  once(:journey) do
    E2E::Cassette.serve("cockpit_question") do |upstream, _cassette|
      sandbox = E2E::Sandbox.create(files: { ".lain/skills/ask-question/skill.md" => skill })
      cockpit = E2E::Cockpit.start(sandbox, upstream, *flags)
      cockpit.type("@dev[/ask-question] Find out which colour I like.")
      wait_until(timeout: patience, reason: "the question counted in state.json") { inbox_count(cockpit) == 1 }
      wait_until(timeout: patience, reason: "the question listed in lain://inbox") do
        inbox_lines(cockpit).join("\n").include?(question)
      end
      parked = { listed: inbox_lines(cockpit), count: inbox_count(cockpit) }
      cockpit.reply("green")
      wait_until(timeout: patience, reason: "the child finished") { finished?(cockpit) }
      wait_until(timeout: patience, reason: "inbox_count back at 0") { inbox_count(cockpit).zero? }
      wait_until(timeout: patience, reason: "fleet back at 0") { fleet_size(cockpit).zero? }
      wait_until(timeout: patience, reason: "you> as the input pane's last line") { cockpit.prompt_back? }
      cockpit.type("/inbox")
      wait_until(timeout: patience, reason: "/inbox answered in the chat pane") do
        cockpit.capture(:chat).include?("(no questions pending)")
      end
      { parked:, after: inbox_lines(cockpit), chat: cockpit.capture(:chat),
        counts: { inbox: inbox_count(cockpit), fleet: fleet_size(cockpit) },
        payloads: cockpit.session.records("message").map { |record| record["payload"] } }
    ensure
      cockpit&.stop
    end
  end

  it "lists the parked question in lain://inbox and counts it in state.json" do
    expect(journey.fetch(:parked).fetch(:count)).to eq(1)
    expect(journey.fetch(:parked).fetch(:listed).join("\n")).to include("Which colour do you like best?")
  end

  it "journals the human's answer to the child's question" do
    expect(journey.fetch(:payloads)).to include({ "answer" => "green" })
  end

  it "leaves inbox_count and fleet at 0 and lain://inbox with no open question" do
    expect(journey.fetch(:counts)).to eq(inbox: 0, fleet: 0)
    expect(journey.fetch(:after).join("\n")).to include("(no questions pending)")
    expect(journey.fetch(:after).join("\n")).not_to include("Which colour do you like best?")
  end

  it "reports none open in the chat pane when /inbox is typed in the input pane" do
    expect(journey.fetch(:chat)).to include("(no questions pending)")
  end
end
