# frozen_string_literal: true

# A real `lain up` cockpit against a scripted stand-in for ollama that holds or parks the model:
# what typing in the input pane does while an ask is running, parked on an approval or parked on a
# question. A held request cannot be recorded, so nothing here replays a cassette.
RSpec.describe "typing in a real cockpit while the model is busy", :e2e do
  def flags = %w[--provider ollama --model qwen3:4b --seed 1 --temperature 0]

  def line(message, done: false)
    body = { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "" }.merge(message),
             "done" => done }
    body.merge!("done_reason" => "stop", "prompt_eval_count" => 5, "eval_count" => 3) if done
    "#{JSON.generate(body)}\n"
  end

  def calling(name, arguments)
    call = { "id" => "call_1", "function" => { "index" => 0, "name" => name, "arguments" => arguments } }
    E2E::Upstream::Reply.new(lines: [line({ "tool_calls" => [call] }), line({}, done: true)])
  end

  def saying(text) = E2E::Upstream::Reply.new(lines: [line({ "content" => text }, done: true)])

  # A held reply with no lines ends as a truncated stream once released, so it carries a finished turn.
  def holding = E2E::Upstream::Reply.new(lines: saying("held").lines, hold: true)

  def chats(upstream) = upstream.requests.select { |request| request[:path] == "/api/chat" }

  def user_prompts(upstream)
    chats(upstream).filter_map do |request|
      last = request[:body].fetch("messages").last
      last["content"] if last["role"] == "user"
    end
  end

  def journey(replies)
    upstream = E2E::Upstream.start(E2E::Scripted.new(replies))
    sandbox = E2E::Sandbox.create
    cockpit = E2E::Cockpit.start(sandbox, upstream, *flags)
    yield cockpit, sandbox, upstream
  ensure
    cockpit&.stop
    upstream&.stop
  end

  def await_chats(upstream, count)
    wait_until(timeout: 20, reason: "#{count} /api/chat request(s) at the stand-in") { chats(upstream).size >= count }
  end

  def interruptions(cockpit) = cockpit.session.records("run_interrupted").map { |record| record["reason"] }

  def await_interrupted(cockpit)
    wait_until(timeout: 20, reason: "a run_interrupted record") { interruptions(cockpit).any? }
  end

  def await_stopped(cockpit)
    wait_until(timeout: 20, reason: "the stopped outcome drawn in the chat pane") do
      cockpit.capture(:chat).include?(Lain::CLI::Shutdown::STOPPED)
    end
    wait_until(timeout: 20, reason: "you> as the input pane's last line") { cockpit.prompt_back? }
  end

  def held_notes(cockpit) = cockpit.capture(:chat).scan(format(Lain::Frontend::TTY::HELD, "")).size

  def inbox_lines(cockpit) = cockpit.editor.evaluate("getbufline(bufnr('lain://inbox'), 1, '$')").join("\n")

  def parked?(cockpit) = cockpit.state.fetch("approvals_pending", 0).positive?

  it "stops an ask parked on an approval when /stop is typed, without running the call or closing the session" do
    journey([calling("bash", { "command" => "touch made-by-agent.txt" })]) do |cockpit, sandbox|
      cockpit.type("Run touch made-by-agent.txt")
      wait_until(timeout: 20, reason: "a gated call parked in nvim") { parked?(cockpit) }
      # Between the HUD counting the call and the pane switching prompts, a typed line is discarded.
      wait_until(timeout: 20, reason: "command> asked in the input pane") do
        cockpit.capture(:input).include?("command>")
      end

      cockpit.type("/stop")
      await_interrupted(cockpit)
      await_stopped(cockpit)

      expect(interruptions(cockpit)).to eq(["stopped"])
      expect(sandbox.project.join("made-by-agent.txt")).not_to exist
      expect(cockpit.session.records("session_closed")).to be_empty
      expect(cockpit.prompt_back?).to be(true)
    end
  end

  it "stops the next model call when /stop is typed after the approval was answered in nvim" do
    journey([calling("bash", { "command" => "touch made-by-agent.txt" }), holding]) do |cockpit, _sandbox, upstream|
      cockpit.type("Run touch made-by-agent.txt")
      wait_until(timeout: 20, reason: "command> asked in the input pane") do
        parked?(cockpit) && cockpit.capture(:input).include?("command>")
      end

      cockpit.approve
      await_chats(upstream, 2)
      cockpit.type("/stop")
      await_interrupted(cockpit)

      expect(interruptions(cockpit)).to eq(["stopped"])
      expect(chats(upstream).size).to eq(2)
    end
  end

  it "reaches the chat at once, before a model that never answers is released" do
    journey([holding]) do |cockpit, _sandbox, upstream|
      cockpit.type("Say anything")
      await_chats(upstream, 1)

      cockpit.type("/stop")
      await_interrupted(cockpit)
      await_stopped(cockpit)

      expect(interruptions(cockpit)).to eq(["stopped"])
      expect(chats(upstream).size).to eq(1)
    end
  end

  it "holds lines typed mid-ask and sends them once each, in order, as the next prompts" do
    replies = [holding, saying("first"), saying("second"), saying("third")]
    journey(replies) do |cockpit, _sandbox, upstream|
      cockpit.type("Start")
      await_chats(upstream, 1)
      ["/goal off", "hello", "one", "two"].each { |held| cockpit.type(held) }

      wait_until(timeout: 20, reason: "4 held notes in the chat pane") { held_notes(cockpit) >= 4 }
      expect(chats(upstream).size).to eq(1)

      upstream.release
      wait_until(timeout: 20, reason: "the third held prompt answered") { cockpit.capture(:chat).include?("third") }
      sleep(1)

      expect(user_prompts(upstream)).to eq(%w[Start hello one two])
      expect(cockpit.capture(:chat).scan("goal off -- no standing goal was driving").size).to eq(1)
      expect(chats(upstream).size).to eq(4)
    end
  end

  it "consumes the question when an ask parked on it is stopped" do
    question = { "question" => "which db?" }
    journey([calling("ask_human", question)]) do |cockpit, _sandbox, _upstream|
      cockpit.type("Ask me something")
      cockpit.session.wait_for("message") { |record| record["to"] == "human" }

      wait_until(timeout: 20, reason: "the question listed in lain://inbox") do
        inbox_lines(cockpit).include?("which db?") && cockpit.state.fetch("inbox_count").positive?
      end
      cockpit.type("/stop")
      await_interrupted(cockpit)
      await_stopped(cockpit)
      consumed = cockpit.session.wait_for("questions_consumed")

      expect(interruptions(cockpit)).to eq(["stopped"])
      expect(cockpit.session.records("turn").count { |record| record["role"] == "assistant" }).to eq(1)
      expect(consumed).to include("turn" => nil, "digests" => [a_kind_of(String)])
      expect(cockpit.state.fetch("inbox_count")).to eq(0)
      expect(inbox_lines(cockpit)).not_to include("which db")
      expect(cockpit.session.records("message").count { |record| record["to"] == "human" }).to eq(1)
    end
  end
end
