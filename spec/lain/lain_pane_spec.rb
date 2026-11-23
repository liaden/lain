# frozen_string_literal: true

require "open3"
require "pty"
require "rbconfig"
require "socket"
require "tmpdir"
require "timeout"

RSpec.describe "exe/lain-pane", :seam do
  let(:client) { File.expand_path("../../exe/lain-pane", __dir__) }
  let(:patience) { 30 }

  around do |example|
    Dir.mktmpdir("pane") do |dir|
      @dir = dir
      @pids = []
      example.run
    ensure
      @pids.each { |pid| stopped(pid) }
    end
  end

  def stopped(pid)
    Process.kill(:KILL, pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def sock = File.join(@dir, "s.sock")

  def env = { "RUBYOPT" => nil, "RUBYLIB" => nil }

  # A stand-in spawner that takes the request and its terminal, then answers as told.
  def answering(*lines)
    server = UNIXServer.new(sock)
    Thread.new do
      conn = server.accept
      nil until conn.recvmsg(4096, scm_rights: true).drop(3).any?
      lines.each { |line| conn.write("#{line}\n") }
      conn.close
    end
  end

  # A fake spawner that takes the request and terminal, then runs the block on the connection.
  def serving
    server = UNIXServer.new(sock)
    Thread.new do
      conn = server.accept
      nil until conn.recvmsg(4096, scm_rights: true).drop(3).any?
      yield conn
    end
  end

  # lain-pane as a pane's session leader; returns what the fallback printed, its status, and the seconds taken.
  def drained(reader)
    reader.read_nonblock(65_536)
  rescue Errno::EIO, IO::EAGAINWaitReadable, EOFError
    ""
  end

  def in_pty(*fallback)
    began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    reader, _writer, pid = PTY.spawn(env, RbConfig.ruby, client, sock, "--", *fallback)
    status = Timeout.timeout(patience) { Process.wait2(pid).last }
    out = drained(reader)
    [out, status.exitstatus, Process.clock_gettime(Process::CLOCK_MONOTONIC) - began]
  end

  it "keeps a controlling terminal for the fallback after giving it up" do
    serving { |conn| conn.write("{\"error\":\"no\"}\n") }
    code = 'puts((File.open("/dev/tty") { true } rescue false))'
    out, = in_pty(RbConfig.ruby, "-e", code)

    expect(out.strip).to eq("true")
  end

  it "execs the fallback with SIGHUP no longer ignored" do
    serving { |conn| conn.write("{\"error\":\"no\"}\n") }
    code = 'puts File.read("/proc/self/status")[/SigIgn:\s*(\h+)/, 1].hex.anybits?(1)'
    out, = in_pty(RbConfig.ruby, "-e", code)

    expect(out.strip).to eq("false")
  end

  it "runs the fallback when no pid comes within the wait" do
    serving { |conn| conn.wait_readable(6) }
    out, _, seconds = in_pty("echo", "fallback")

    expect([out.strip, seconds]).to match(["fallback", be < 4.5])
  end

  it "does not fall back once the program has started and the connection breaks" do
    serving { |conn| conn.write("{\"pid\":1}\n") && conn.close }
    out, status = in_pty("echo", "fallback")

    expect([out.strip, status]).to eq(["", 255])
  end

  it "does not fall back once the program has started and the status line is garbage" do
    serving { |conn| conn.write("{\"pid\":1}\nnot json\n") && conn.close }
    out, status = in_pty("echo", "fallback")

    expect([out.strip, status]).to eq(["", 255])
  end

  it "runs the fallback when no spawner listens" do
    out, status = Open3.capture2(env, RbConfig.ruby, client, sock, "--", "echo", "fallback")

    expect([out, status.exitstatus]).to eq(["fallback\n", 0])
  end

  it "runs the fallback when the spawner answers stale" do
    answering('{"stale":true}')
    out, = Open3.capture2(env, RbConfig.ruby, client, sock, "--", "echo", "fallback")

    expect(out).to eq("fallback\n")
  end

  it "runs the fallback when the spawner answers an error" do
    answering('{"error":"no"}')
    out, = Open3.capture2(env, RbConfig.ruby, client, sock, "--", "echo", "fallback")

    expect(out).to eq("fallback\n")
  end

  it "loads no file of lain" do
    answering('{"pid":1}', '{"pid":1,"status":0}')
    probe = "at_exit { puts $LOADED_FEATURES.grep(%r{/lib/lain}) }; load ARGV.shift"
    out, = Open3.capture2(env, RbConfig.ruby, "-e", probe, client, sock, "--", "echo", "x")

    expect(out).to eq("")
  end

  it "exits with the status the spawner relays, under a pty, from a real spawner" do
    skip "this host cannot fork" unless Process.respond_to?(:fork)
    ours, theirs = UNIXSocket.pair
    listener = Lain::Daemon::Spawner::PaneListener.listen(sock)
    @pids << fork do
      ours.close
      Lain::Daemon::Spawner.new(socket: theirs, starter: ->(argv) { exit(argv.first.to_i) },
                                pane_listener: listener).call
    end
    theirs.close
    listener.forget

    reader, _writer, pid = PTY.spawn(env, RbConfig.ruby, client, sock, "--", "lain", "3")
    status = Timeout.timeout(patience) { Process.wait2(pid).last }
    reader.close

    expect(status.exitstatus).to eq(3)
  end
end
