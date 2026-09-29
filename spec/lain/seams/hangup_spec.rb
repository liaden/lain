# frozen_string_literal: true

require "fileutils"
require "json"
require "mixlib/shellout"
require "rbconfig"
require "tmpdir"

# A closed terminal sends SIGHUP, and a chat that dies of it while a subagent is
# mid-spawn must leave the record a terminate leaves: the spawn's ending, the
# session's close, and the child's checkout returned. Driven in a CHILD process
# because the signal's default action ends the process, which no in-process
# example can survive to observe.
#
# The child is the real {Lain::CLI::ChatLaunch} over a real git repository and a
# real session file, with `--isolation worktree`. Only the model is scripted: its
# first answer calls the subagent, and the child's own first request never returns.
module Hangup
  LIB = File.expand_path("../../../lib", __dir__)

  CHILD = <<~'RUBY'
    require "lain"

    marker = ARGV.fetch(0)

    hanging = Class.new(Lain::Provider::Mock) do
      define_method(:complete) do |request, on_stream_started: nil|
        return super(request, on_stream_started:) if call_count.zero?

        File.write("#{marker}.tmp", "")
        File.rename("#{marker}.tmp", marker)
        Async::Task.current.sleep
      end
    end
    call = { "type" => "tool_use", "id" => "tu_spawn", "name" => "subagent", "input" => { "prompt" => "work" } }
    provider = hanging.new(responses: [Lain::Response.new(content: [call], stop_reason: :tool_use)])

    backend_class = Class.new(Lain::CLI::Backend) do
      define_method(:provider) { |**| provider }
      define_method(:num_ctx) { nil }
    end
    launch = Class.new(Lain::CLI::ChatLaunch) do
      define_method(:backend) { @backend ||= backend_class.new(@options, root: Dir.pwd) }
    end

    options = { provider: "anthropic", model: "claude-opus-4-8", max_tokens: 256, journal: true, btw: false,
                nvim: false, windows: false, non_interactive: true, prompt: "spawn one", isolation: "worktree",
                grace: 5 }
    launch.new(options).call { |_notice| nil }
  RUBY
end

RSpec.describe "a chat hung up on mid-spawn", :seam do
  around do |example|
    Dir.mktmpdir("hangup") do |dir|
      @dir = File.realpath(dir)
      @repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(@repo)
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @repo)
      example.run
    end
  end

  let(:marker) { File.join(@dir, "parked") }
  let(:state_home) { File.join(@dir, "state") }
  let(:stderr) { File.join(@dir, "chat.err") }

  def records
    file = Dir[File.join(state_home, "**", "sessions", "**", "*.ndjson")].sole
    File.foreach(file).map { |line| JSON.parse(line) }
  end

  def chat
    env = { "XDG_STATE_HOME" => state_home, "ANTHROPIC_API_KEY" => "sk-hangup", "HOME" => @dir }
    Process.spawn(env, RbConfig.ruby, "-I", Hangup::LIB, "-e", Hangup::CHILD, marker,
                  chdir: @repo, in: File::NULL, out: File::NULL, err: stderr)
  end

  def await_parked(pid, timeout: 60)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until File.exist?(marker)
      raise "the chat exited before the spawn parked: #{File.read(stderr)}" if Process.waitpid(pid, Process::WNOHANG)
      raise "the spawn never parked: #{File.read(stderr)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def hung_up
    pid = chat
    await_parked(pid)
    Process.kill("HUP", pid)
    Timeout.timeout(30) { Process.wait(pid) }
    pid = nil
  ensure
    if pid
      begin
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  it "ends the spawn, closes the record and returns the lease, as a terminate does" do
    hung_up
    written = records
    ended = written.select { |record| record["type"] == "message" && record["payload"]&.key?("final") }
    leases = written.select { |record| record["type"] == "isolation_lease" }.map { |record| record["kind"] }

    expect(ended).not_to be_empty
    expect(written.map { |record| record["type"] }).to include("session_closed")
    expect(leases).to eq(%w[acquired released])
  end
end
