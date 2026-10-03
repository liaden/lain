# frozen_string_literal: true

require "socket"

# A real `lain chat` from this checkout's exe, on a real pseudo-terminal, against a
# scripted stand-in for ollama: what the human sees when the endpoint misbehaves.
RSpec.describe "a plain chat against a faulty upstream", :e2e do
  def line(text, done: false)
    body = { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => text }, "done" => done }
    body.merge!("done_reason" => "stop", "prompt_eval_count" => 5, "eval_count" => 3) if done
    "#{JSON.generate(body)}\n"
  end

  let(:sandbox) { E2E::Sandbox.create }
  let(:flags) { %w[--provider ollama --model qwen3:4b --no-nvim] }

  def start_chat(api_base)
    E2E::PlainChat.start(sandbox, api_base, *flags)
  end

  it "refuses a reply severed mid-stream by name, records it, and answers the next ask" do
    severed = E2E::Upstream::Reply.new(lines: [line("The answ"), line("er is")])
    whole = E2E::Upstream::Reply.new(lines: [line("Second "), line("reply", done: true)])
    upstream = E2E::Upstream.start(E2E::Scripted.new([severed, whole]))
    chat = start_chat(upstream.url)

    chat.type("first question")
    expect(chat.session.wait_for("truncated_stream")).to include("kind" => "unterminated")
    wait_until(timeout: 15, reason: "the failed turn drawn") { chat.screen.include?("error:") }
    expect(chat.screen).to match(/truncated stream/i)
    expect(chat.screen).not_to match(/\.rb:\d+:in /)

    chat.await_prompt(since: chat.screen.index("error:"))
    chat.type("second question")
    chat.session.wait_for("turn_usage") { |record| record["stop_reason"] == "end_turn" }
    wait_until(timeout: 15, reason: "the second reply drawn") { chat.screen.include?("Second reply") }
    chat.quit
  ensure
    upstream&.stop
  end

  it "names an endpoint that refuses connections at the first ask, and writes no turn_usage" do
    closed = TCPServer.new("127.0.0.1", 0)
    authority = "127.0.0.1:#{closed.addr[1]}"
    closed.close
    chat = start_chat("http://#{authority}")

    chat.type("anyone there")
    wait_until(timeout: 30, reason: "the failed ask drawn") { chat.screen.include?("error:") }
    error_line = chat.screen.lines.grep(/error:/).last
    expect(error_line).to include(authority)
    expect(error_line).not_to match(/\.rb:\d+:in /)
    expect(chat.session.records("turn_usage")).to be_empty
    chat.quit
  end

  it "runs inside its sandbox, with no credential in its environment" do
    original = ENV.fetch("ANTHROPIC_API_KEY", nil)
    ENV["ANTHROPIC_API_KEY"] = "sk-spec-not-real"
    upstream = E2E::Upstream.start(E2E::Scripted.new([]))
    chat = start_chat(upstream.url)

    environ = File.read("/proc/#{chat.pid}/environ").split("\0").to_h { |pair| pair.split("=", 2) }
    dir = sandbox.dir.to_s
    expect(environ.values_at("HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"))
      .to all(start_with(dir))
    expect(environ.keys.grep(/\A(ANTHROPIC_API_KEY|OLLAMA_API_KEY)\z|_(KEY|TOKEN|SECRET)\z/)).to be_empty
    chat.quit
  ensure
    ENV["ANTHROPIC_API_KEY"] = original
    upstream&.stop
  end

  it "fails the example, and kills the process, when one outlives its journey" do
    straggler = Process.spawn("sh", "-c", "sleep 30; :", sandbox.dir.to_s, %i[out err] => File::NULL)
    expect { E2E::Sandbox.reap_all! }.to raise_error(/#{straggler} .*#{Regexp.escape(sandbox.dir.to_s)}/)
    _, status = Process.wait2(straggler)
    expect(status.signaled?).to be(true)
  end

  it "fails an :e2e example that leaks a process, through the shared after hook" do
    leaked = nil
    leaker = RSpec::Core::ExampleGroup.subclass(RSpec::Core::ExampleGroup, "leaker", [:e2e], [])
    leaker.it("leaks") do
      leaked = Process.spawn("sh", "-c", "sleep 30; :", E2E::Sandbox.create.dir.to_s, %i[out err] => File::NULL)
    end

    expect(leaker.run(RSpec::Core::NullReporter)).to be(false)
  ensure
    Process.wait(leaked) if leaked
  end
end
