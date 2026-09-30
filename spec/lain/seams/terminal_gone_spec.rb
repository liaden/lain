# frozen_string_literal: true

require "pty"
require "socket"
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

  # Answers every request but the chat itself with an empty JSON object; each
  # chat request is held open and announced on `parked`.
  class ParkingOllama
    attr_reader :parked

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @parked = Thread::Queue.new
      @held = []
      @thread = Thread.new { serve }
    end

    def api_base = "http://127.0.0.1:#{@server.addr[1]}"

    def close
      @server.close
      @thread.join
      @held.each { |client| client.close unless client.closed? }
    end

    private

    def serve
      loop { answer(@server.accept) }
    rescue IOError, Errno::EBADF
      nil
    end

    # A chat that ends mid-request leaves a broken pipe behind, which is its
    # business, not a failure of the stand-in.
    def answer(client)
      respond(client)
    rescue Errno::EPIPE, Errno::ECONNRESET
      client.close
    end

    def respond(client)
      request = client.gets.to_s
      length = headers(client).fetch("content-length", "0").to_i
      client.read(length)
      request.start_with?("POST /api/chat") ? hold(client) : empty(client)
    end

    def headers(client)
      lines = Enumerator.produce { client.gets }.take_while { |line| line && line != "\r\n" }
      lines.to_h { |line| line.split(":", 2).then { |key, value| [key.downcase, value.strip] } }
    end

    def hold(client)
      @held << client
      @parked << true
    end

    def empty(client)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n" \
                   "Connection: close\r\n\r\n{}")
      client.close
    end
  end
end

RSpec.describe "a chat whose terminal is gone", :seam do
  around do |example|
    Dir.mktmpdir("terminal-gone") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  let(:ollama) { TerminalGone::ParkingOllama.new }

  def chat(*extra)
    env = { "XDG_STATE_HOME" => File.join(@dir, "state"), "HOME" => @dir, "TERM" => "xterm" }
    @output, @input, @pid = PTY.spawn(env, TerminalGone::EXE, "chat", "--provider", "ollama", "--no-journal",
                                      "--api-base", ollama.api_base, *extra, chdir: @dir)
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
    @pid = nil if reaped
    !reaped.nil?
  end

  def reap_leftover
    Process.kill("KILL", @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  after do
    [@output, @input].compact.reject(&:closed?).each(&:close)
    reap_leftover if @pid
  ensure
    ollama.close
  end

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
