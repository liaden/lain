# frozen_string_literal: true

require "fileutils"
require "pty"
require "rbconfig"
require "tmpdir"

# The processes of a cockpit seam, booted before any example claims them: the
# directory they meet in, a chat child parked until it is told its shape, and
# the terminal a human types at. The terminal is a `lain input` pane running
# THIS checkout's `exe/lain`, or the chat's own PTY; a pane that finds no chat
# on its socket says so and tries again every tick, so one booted early meets
# the chat as a slow one would.
module WarmCockpit
  LIB = File.expand_path("../../lib", __dir__)
  EXE = File.expand_path("../../exe/lain", __dir__)

  # `$HOME` is left alone deliberately: the children run under this runner's
  # bundle, and a moved home is a bundler that cannot find its own gems. The XDG
  # variables keep the pane's history and state out of the human's directories.
  def self.env(dir, **extra)
    { "XDG_STATE_HOME" => File.join(dir, "state"), "XDG_RUNTIME_DIR" => File.join(dir, "run"),
      "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_CACHE_HOME" => File.join(dir, "cache"),
      "TERM" => "xterm", "INPUTRC" => File.join(dir, "no-inputrc") }.merge(extra)
  end

  def self.pane(prefix:, **extra)
    dir = Dir.mktmpdir(prefix)
    Booted.new(dir, nil, *pane_in(dir, env(dir, **extra)))
  end

  def self.pair(prefix:, script:)
    dir = Dir.mktmpdir(prefix)
    env = env(dir, **WarmPool.park_env(dir))
    Booted.new(dir, chat_in(dir, env, script), *pane_in(dir, env))
  end

  # `term` is fixed at spawn because Reline reads it once, at load.
  def self.terminal(prefix:, script:, term: "xterm", flags: ["-W0"])
    dir = Dir.mktmpdir(prefix)
    env = env(dir, **WarmPool.park_env(dir), "TERM" => term)
    Booted.new(dir, nil, *PTY.spawn(env, RbConfig.ruby, *flags, *chat_argv(script)))
  end

  def self.chat(prefix:, script:)
    dir = Dir.mktmpdir(prefix)
    pid = Process.spawn(WarmPool.park_env(dir), RbConfig.ruby, *chat_argv(script),
                        out: File::NULL, err: File.join(dir, "chat.err"))
    Booted.new(dir, pid)
  end

  def self.chat_argv(script) = ["-I", LIB, "-e", WarmPool.parked(script)]

  def self.chat_in(dir, env, script)
    Process.spawn(env, RbConfig.ruby, *chat_argv(script), out: File.join(dir, "chat.err"), err: %i[child out])
  end

  def self.pane_in(dir, env)
    PTY.spawn(env, RbConfig.ruby, EXE, "input", "--socket", File.join(dir, "input.sock"))
  end

  Booted = Struct.new(:dir, :chat, :reader, :writer, :pid) do
    def release(shape) = tell(dir, shape, File.join(dir, "input.sock"))

    def tell(*argv) = WarmPool.release(dir, argv)

    def reap
      [chat, pid].compact.each { |child| kill(child) }
      [writer, reader].compact.each { |io| io.close unless io.closed? }
      FileUtils.rm_rf(dir)
    end

    private

    # A child the example already waited for is gone, and its pid may be
    # someone else's by now: only one still unwaited is killed.
    def kill(child)
      return unless Process.waitpid(child, Process::WNOHANG).nil?

      Process.kill("KILL", child)
      Process.wait(child)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
