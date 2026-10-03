# frozen_string_literal: true

# A real `lain up` cockpit (tmux, nvim, the chat and its input pane) from this checkout's exe,
# replaying model turns recorded from a local ollama that ask for a gated `bash` call: what a human
# sees and what the project holds when the parked call is approved or denied in nvim.
RSpec.describe "approving and denying a parked call in a real cockpit", :e2e do
  def prompt = "Use the bash tool to run exactly: touch made-by-agent.txt. If it is refused, do not try again."

  def flags = %w[--provider ollama --model qwen3:4b --seed 1 --temperature 0]

  def patience = E2E::Cassette.recording? ? 300 : 20

  def chats(requests) = requests.select { |request| request[:method] == "POST" && request[:path] == "/api/chat" }

  def parked?(cockpit) = cockpit.state.fetch("approvals_pending", 0).positive?

  def turn_ended?(cockpit)
    cockpit.session.records("turn_usage").any? { |record| record["stop_reason"] == "end_turn" }
  end

  def approvals_cleared?(cockpit) = cockpit.state.fetch("approvals_pending", 1).zero?

  def prompt_back?(cockpit) = cockpit.capture(:input).include?("you>")

  # Drives one cockpit from the prompt to the last reply, answering the parked call with the given
  # gesture, and keeps what the examples then read once the cockpit is gone.
  def journey_for(cassette_name, gesture)
    E2E::Cassette.serve(cassette_name) do |upstream, cassette|
      sandbox = E2E::Sandbox.create
      cockpit = E2E::Cockpit.start(sandbox, upstream, *flags)
      cockpit.type(prompt)
      wait_until(timeout: patience, reason: "a gated call parked in nvim") { parked?(cockpit) }
      cockpit.public_send(gesture)
      wait_until(timeout: patience, reason: "an end_turn usage record") { turn_ended?(cockpit) }
      wait_until(timeout: patience, reason: "approvals_pending back at 0") { approvals_cleared?(cockpit) }
      wait_until(timeout: patience, reason: "you> back in the input pane") { prompt_back?(cockpit) }
      observed(cockpit, sandbox, upstream, cassette)
    ensure
      cockpit&.stop
    end
  end

  def final_reply(cockpit)
    last = cockpit.session.records("turn").last
    last.fetch("content").filter_map { |block| block["text"] if block["type"] == "text" }.join(" ")
  end

  def observed(cockpit, sandbox, upstream, cassette)
    approval = cockpit.editor.evaluate("getbufline(bufnr('lain://approval'), 1, '$')")
    { cassette:, requests: chats(upstream.requests), approval:,
      made: sandbox.project.join("made-by-agent.txt").exist?,
      decisions: cockpit.session.records("approval_decision"),
      reply: final_reply(cockpit), chat: cockpit.capture(:chat),
      input: cockpit.capture(:input), input_height: cockpit.input_height }
  end

  context "when the human approves the call" do
    once(:journey) { journey_for("cockpit_approve", :approve) }

    it "runs the call in the project and journals an nvim approval" do
      expect(journey.fetch(:made)).to be(true)
      expect(journey.fetch(:decisions)).to contain_exactly(
        include("tool" => "bash", "surface" => "nvim", "verdict" => "approve")
      )
    end

    it "clears the approval buffer and shows the model's final reply in the chat pane" do
      expect(journey.fetch(:approval).join("\n")).to include("(no approvals pending)")
      reply_tail = journey.fetch(:reply).split.last(3).join(" ")
      expect(reply_tail).not_to be_empty
      expect(journey.fetch(:chat).squish).to include(reply_tail)
    end

    it "shows a fleet line above a you> line in an input pane at its floor height" do
      shown = journey.fetch(:input).lines.map(&:rstrip).reject(&:empty?)

      expect(journey.fetch(:input_height)).to be >= Lain::CLI::Up::INPUT_PANE_HEIGHT
      expect(shown.last).to include("you>")
      expect(shown.first).to match(/fleet:\d+/)
    end

    it "replays offline, playing every recorded call with no mismatch" do
      expect(journey.fetch(:cassette).mismatches).to be_empty
      expect(journey.fetch(:cassette).unplayed).to be_empty
    end
  end

  context "when the human denies the call" do
    once(:journey) { journey_for("cockpit_deny", :deny) }

    it "does not run the call and journals an nvim denial" do
      expect(journey.fetch(:made)).to be(false)
      expect(journey.fetch(:decisions)).to contain_exactly(
        include("tool" => "bash", "surface" => "nvim", "verdict" => "deny")
      )
    end

    it "tells the model the approval was denied" do
      sent = journey.fetch(:requests).last.fetch(:body).fetch("messages").last

      expect(sent).to include("role" => "tool")
      expect(sent.fetch("content")).to include('approval denied for tool "bash"')
    end
  end
end
