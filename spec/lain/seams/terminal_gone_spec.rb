# frozen_string_literal: true

require "fileutils"
require "pty"
require "tmpdir"

# A chat whose terminal goes away must still end. The real `lain chat` from this
# checkout's exe, on a real pseudo-terminal: closing the terminal's side is the
# hangup a killed tmux server delivers. A chat that outlived it once sat forever
# with no terminal and dropped every later HUP and TERM, and only SIGKILL ended
# it. Every child is reaped in an ensure, killed first if it is still there.
#
# Every chat talks to a local stand-in for ollama the spec owns, never to a real
# one: it answers the status polls and holds a chat request open, so a grace
# window can be opened on a run that is really in flight.
module TerminalGone
  EXE = File.expand_path("../../../exe/lain", __dir__)

  class Parking
    attr_reader :parked

    def initialize
      @parked = Thread::Queue.new
      @upstream = E2E::Upstream.start(method(:hold))
    end

    def api_base = @upstream.url

    def close = @upstream.stop

    private

    def hold(_request)
      @parked << true
      E2E::Upstream::Reply.new(lines: [], hold: true)
    end
  end

  # A `lain chat` booted ahead of its example, already on its way to `you>`
  # with a stand-in provider of its own, and the directory it runs in. What an
  # example decides, the flags, is the key it is taken by.
  class Warm
    attr_reader :dir, :ollama, :output, :input
    attr_accessor :pid

    def self.boot(flags)
      dir = File.realpath(Dir.mktmpdir("terminal-gone"))
      ollama = Parking.new
      env = { "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir, "TERM" => "xterm" }
      output, input, pid = PTY.spawn(env, EXE, "chat", "--provider", "ollama", "--no-journal",
                                     "--api-base", ollama.api_base, *flags, chdir: dir)
      new(dir, ollama, output, input, pid)
    end

    def initialize(dir, ollama, output, input, pid)
      @dir = dir
      @ollama = ollama
      @output = output
      @input = input
      @pid = pid
    end

    def reap
      [output, input].reject(&:closed?).each(&:close)
      kill if pid
      ollama.close
      FileUtils.rm_rf(dir)
    end

    private

    def kill
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end

RSpec.describe "a chat whose terminal is gone", :seam do
  warm_pool(:chats, expected: { [] => 2, %w[--grace 60] => 1 }) { |flags| TerminalGone::Warm.boot(flags) }

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  let(:ollama) { @warm.ollama }

  def chat(*extra)
    @warm = chats.take(extra)
    @output = @warm.output
    @input = @warm.input
    @pid = @warm.pid
  end

  def await_prompt(timeout: 30)
    seen = +""
    deadline = monotonic + timeout
    until seen.include?("you>")
      raise "no you> within #{timeout}s: #{(seen[-400..] || seen).inspect}" if monotonic > deadline

      seen << @output.read_nonblock(4096) if @output.wait_readable(0.2)
    end
  rescue Errno::EIO, EOFError
    raise "the chat ended before you>, having printed: #{(seen[-400..] || seen).inspect}"
  end

  def hang_up
    @output.close
    @input.close
  end

  # Reaps the chat if it ends within `bound` seconds; false while it is still there.
  def ends_within?(bound)
    deadline = monotonic + bound
    sleep(0.05) until (reaped = Process.waitpid(@pid, Process::WNOHANG)) || monotonic > deadline
    @warm.pid = @pid = nil if reaped
    !reaped.nil?
  end

  after { @warm&.reap }

  it "ends at its prompt once the terminal is closed" do
    chat
    await_prompt
    hang_up

    expect(ends_within?(10)).to be(true)
  end

  it "ends on a TERM that arrives after the terminal has gone" do
    chat
    await_prompt
    hang_up
    Process.kill("TERM", @pid)

    expect(ends_within?(10)).to be(true)
  end

  context "with an ask in flight" do
    # Closing the terminal is itself a HUP, so the second signal is the hangup
    # a killed tmux server delivers, and the explicit one beside it is a spare.
    it "opens the grace window on the first signal and ends at once on a second" do
      chat("--grace", "60")
      await_prompt
      @input.write("hello\r")
      ollama.parked.pop(timeout: 30) or raise "the ask never reached the provider"
      Process.kill("TERM", @pid)

      expect(ends_within?(1)).to be(false)
      hang_up
      Process.kill("HUP", @pid)
      expect(ends_within?(10)).to be(true)
    end
  end
end
