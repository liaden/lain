# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"

# A chat killed while one of its tools runs has to come back. The tool round's
# assistant turn is committed before the tool starts, and every record the round
# writes -- its usage, its memory root, a spawn, a question -- cites that turn,
# so the file must hold it before any tool can outlive the process.
#
# Driven in a CHILD process that gets SIGKILL, because a kill is the one exit no
# `ensure` sees: an in-process stop would let the very catch-up this pins run on
# the way out. The child wires the record as a chat does -- a real fsync Journal
# under a {Lain::CLI::Chronicle}, its Scribe, its request and turn middleware and
# its memory decoration -- over a scripted model and the real `bash` tool.
module CrashMidTool
  LIB = File.expand_path("../../../lib", __dir__)

  # A third argument names a record type the child kills itself BEFORE writing,
  # which is how a kill lands between two writes no marker can separate.
  CHILD = <<~'RUBY'
    require "lain"

    state_home, marker, kill_before = ARGV
    paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home })
    path = Lain::Journal.default_path(paths:)
    journal = Class.new(Lain::Journal) do
      define_method(:record) do |entry|
        type = (entry.respond_to?(:to_journal) ? entry.to_journal : entry).transform_keys(&:to_s)["type"].to_s
        Process.kill(:KILL, Process.pid) if type == kill_before
        super(entry)
      end
      alias_method :<<, :record
    end.new(io: File.open(path, "ab"), owns_io: true, fsync: true, path:)
    chronicle = Lain::CLI::Chronicle.new(journal:, journal_path: path)
    context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
    toolset = Lain::Toolset.new([Lain::Tools::Bash.new])
    recorder = chronicle.wrap_memory(Lain::Memory::Recorder.new)
    session = chronicle.wrap_session(Lain::Session.new(memory: recorder))
    chronicle.start(context:, toolset:)
    call = { "type" => "tool_use", "id" => "tu_sleep", "name" => "bash",
             "input" => { "command" => "echo $$ > #{marker}.tmp && mv #{marker}.tmp #{marker} && exec sleep 30" } }
    provider = Lain::Provider::Mock.new(responses: [Lain::Response.new(content: [call], stop_reason: :tool_use)])
    agent = nil
    agent = Lain::Agent.new(provider:, context:, toolset:, session:, timeline: Lain::Timeline.empty,
                            instrumentation: chronicle.instrumentation
                                                      .with(turn_middleware: chronicle.turn_middleware(-> { agent.timeline })))
    agent.ask("sleep for a while")
  RUBY
end

RSpec.describe "a session killed while a tool runs", :seam do
  around do |example|
    Dir.mktmpdir("crash-mid-tool") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:state_home) { File.join(@dir, "state") }
  let(:marker) { File.join(@dir, "bash.pid") }
  let(:stderr) { File.join(@dir, "chat.err") }
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home }) }

  def session_file = Dir[File.join(paths.sessions_dir, "*.ndjson")].sole

  def records = File.foreach(session_file).map { |line| JSON.parse(line) }

  def chat(*kill_before)
    Process.spawn(RbConfig.ruby, "-I", CrashMidTool::LIB, "-e", CrashMidTool::CHILD, state_home, marker,
                  *kill_before, out: File::NULL, err: stderr)
  end

  def await_bash(pid, timeout: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until File.exist?(marker)
      raise "the chat exited before bash ran: #{File.read(stderr)}" if Process.waitpid(pid, Process::WNOHANG)
      raise "bash never started" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    Integer(File.read(marker))
  end

  # The bash grandchild outlives its SIGKILLed parent, so it is reaped by hand,
  # and so is the chat itself when the wait for bash gives out.
  def killed_mid_tool
    pid = chat
    sleeper = await_bash(pid)
  ensure
    [pid, sleeper].compact.each do |process|
      Process.kill("KILL", process)
    rescue Errno::ESRCH
      nil
    end
    reap(pid)
  end

  def reap(pid)
    Process.wait(pid) unless pid.nil?
  rescue Errno::ECHILD
    nil
  end

  it "loads without refusal, its head the tool_use turn answered as cancelled" do
    killed_mid_tool
    result = Lain::CLI::Resume.new(paths:).call

    expect(result.open?).to be(true)
    asked, cancelled = result.timeline.to_a.last(2)
    expect(asked.content.map { |block| block["type"] }).to eq(%w[tool_use])
    expect(cancelled.content).to contain_exactly(include("type" => "tool_result", "tool_use_id" => "tu_sleep",
                                                         "is_error" => true))
  end

  # Written ahead of the usage and memory root that name it, so no instant of the
  # round leaves a record citing a turn the file lacks.
  it "writes the tool_use turn before either record that cites it" do
    killed_mid_tool
    turn = records.find { |record| record["type"] == "turn" && record["role"] == "assistant" }
    position = ->(type, key) { records.index { |record| record["type"] == type && record[key] == turn["digest"] } }

    expect(turn).not_to be_nil
    expect(records.index(turn)).to be < position.call("turn_usage", "digest")
    expect(records.index(turn)).to be < position.call("memory_root", "turn_digest")
  end

  # The kill between the settled turn record and its usage record. The request
  # it answered has no usage after it, so the response log is consulted -- and
  # the turn record already on disk is the proof that response was committed.
  # Two frames a crash can leave: an Ollama log, whose bytes never reassemble
  # into what was committed, and an Anthropic stream that does; and no frame.
  describe "between the turn record and its usage" do
    def killed_before_usage
      Process.wait(chat("turn_usage"))
    end

    def committed_call = records.find { |record| record["type"] == "turn" && record["role"] == "assistant" }

    def framed(bytes)
      sent = records.reverse.find { |record| record["type"] == "request_sent" }.fetch("digest")
      wal = Lain::Provider::ResponseWal.new(Lain::Paths.wal_for(session_file))
      frame = wal.open_frame(request_digest: sent)
      frame.append(bytes)
      frame.close(complete: true)
      wal.close
    end

    def ollama_log = %({"model":"qwen","message":{"role":"assistant","content":"hi"},"done":true}\n)

    def anthropic_stream
      AnthropicSSE.body(Lain::Response.new(content: committed_call.fetch("content"), stop_reason: :tool_use,
                                           usage: Lain::Usage.new(input_tokens: 10, output_tokens: 4)))
    end

    frames = { "an Ollama response log" => :ollama_log,
               "an Anthropic stream of the committed response" => :anthropic_stream,
               "no response log at all" => nil }

    frames.each do |shape, bytes|
      it "resumes onto the settled turn with #{shape}, salvaging nothing" do
        killed_before_usage
        framed(public_send(bytes)) unless bytes.nil?
        written = records

        result = Lain::CLI::Resume.new(paths:).call

        expect(result.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
        expect(result.timeline.to_a[1].digest).to eq(written.find { |record| record["role"] == "assistant" }["digest"])
        expect(result.notices.join).not_to match(/recover|did not finish/)
        expect(records.map { |record| record["type"] }).not_to include("salvaged")
      end
    end
  end
end
