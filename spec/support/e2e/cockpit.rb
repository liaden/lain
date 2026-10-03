# frozen_string_literal: true

require "io/console"
require "json"
require "open3"
require "pty"
require "securerandom"
require_relative "../wait_until"

module E2E
  # `exe/lain up` on a pseudo-terminal: tmux, nvim, the chat and its input pane, driven the way a
  # person drives them. Each cockpit owns its tmux server, so stopping one never touches another.
  class Cockpit
    include WaitUntil

    EXE = File.expand_path("../../../exe/lain", __dir__)
    SESSION = "e2e"
    BOOT_SECONDS = 45
    STOP_SECONDS = 10
    APPROVAL_BUFFER = "lain://approval"
    ROWS = 24
    COLUMNS = 220
    PANES = { chat: Lain::CLI::Up::Panes::CHAT, input: Lain::CLI::Up::Panes::INPUT,
              editor: Lain::CLI::Up::Panes::EDITOR }.freeze

    attr_reader :session

    # A tmux server's socket lives under the sandbox's TMPDIR, so the name only has to be unique
    # among cockpits that share a sandbox.
    # The default is a terminal's own: the input pane collapsed at every height below 50, so a
    # taller cockpit could not show it.
    def self.start(sandbox, upstream, *chat_flags, rows: ROWS)
      new(sandbox, "lain-e2e-#{SecureRandom.hex(4)}").tap { |cockpit| cockpit.launch(upstream.url, chat_flags, rows) }
    end

    def initialize(sandbox, socket)
      @sandbox = sandbox
      @socket = socket
      @session = SessionFile.in(sandbox)
    end

    def launch(api_base, chat_flags, rows)
      @reader, @writer, @pid = PTY.spawn(@sandbox.env, EXE, "up", "--session", SESSION, "--socket", @socket,
                                         @sandbox.project.to_s, "--", *chat_flags, "--api-base", api_base,
                                         chdir: @sandbox.project.to_s, unsetenv_others: true)
      @writer.winsize = [rows, COLUMNS]
      @sandbox.track(@pid)
      @drain = drain(@reader)
      await_prompt
    end

    # A line is sent only once the input pane shows it, so an Enter can never overtake its text.
    def type(line)
      tmux("send-keys", "-l", "-t", pane(:input), line)
      wait_until(timeout: 10, reason: "#{line.inspect} shown in the input pane") { capture(:input).include?(line) }
      tmux("send-keys", "-t", pane(:input), "Enter")
    end

    def capture(name) = tmux("capture-pane", "-p", "-t", pane(name))

    def input_height = tmux("display-message", "-p", "-t", pane(:input), "\#{pane_height}").to_i

    def state = JSON.parse(File.read(state_path))

    def editor
      @editor ||= HeadlessEditor.connect(editor_socket)
    end

    def approve(line = 1) = answer("LainApprove", line)

    def deny(line = 1) = answer("LainDeny", line)

    # Only the descriptors are guaranteed to close; a step that raises skips the ones after it and
    # leaves the processes to the sandbox's reaper.
    def stop
      @editor&.shutdown
      tmux("kill-server")
      await_client
      wait_until(timeout: STOP_SECONDS, reason: "the cockpit's processes gone") { processes_gone? }
    ensure
      close_terminal
    end

    private

    def answer(command, line)
      window = await_approval_window
      editor.call_function("win_gotoid", [window])
      editor.command(line.to_s)
      editor.command(command)
    end

    # The status feed counts a pending call before nvim has drawn it, so a caller that saw the count
    # can still be early.
    def await_approval_window
      window = 0
      wait_until(timeout: BOOT_SECONDS, reason: "#{APPROVAL_BUFFER} in a window listing a call") do
        window = editor.evaluate("bufwinid(bufnr('#{APPROVAL_BUFFER}'))").to_i
        window.positive? && editor.evaluate("getbufvar(bufnr('#{APPROVAL_BUFFER}'), 'lain_approval_calls', [])").any?
      end
      window
    end

    # Nothing reads the terminal otherwise, and a client whose writes block cannot hear the server go.
    def drain(reader)
      Thread.new do
        Thread.current.report_on_exception = false
        loop { reader.readpartial(4096) }
      rescue IOError, Errno::EIO
        nil
      end
    end

    def await_client
      waiter = Thread.new { Process.wait(@pid) }
      raise "the up client outlived kill-server by #{STOP_SECONDS}s" unless waiter.join(STOP_SECONDS)
    rescue Errno::ECHILD
      nil
    end

    def close_terminal
      @drain&.kill
      [@reader, @writer].each { |io| io.close unless io.closed? }
    end

    def await_prompt
      wait_until(timeout: BOOT_SECONDS, reason: "a you> line in the input pane") do
        !tmux("show-options", "-v", "-t", SESSION, PANES.fetch(:input)).empty? && capture(:input).include?("you>")
      end
    end

    def pane(name) = tmux("show-options", "-v", "-t", SESSION, PANES.fetch(name))

    # The sandbox's environment, because tmux finds its server through TMPDIR.
    def tmux(*)
      Open3.capture3(@sandbox.env, "tmux", "-L", @socket, *, unsetenv_others: true).first.strip
    end

    def processes_gone?
      Dir.glob("/proc/[0-9]*/cmdline").none? do |file|
        File.read(file).include?(@sandbox.dir.to_s)
      rescue SystemCallError
        false
      end
    end

    def sockets = Dir.glob(@sandbox.dir.join("run", "lain", "*.sock").to_s)

    def editor_socket
      found = nil
      wait_until(timeout: BOOT_SECONDS, reason: "an nvim socket") do
        found = sockets.find { |path| File.basename(path).start_with?("nvim-") }
      end
      found
    end

    def state_path
      Dir.glob(@sandbox.state_home.join("lain", "status", "*", "state.json").to_s).first ||
        raise("no state.json under #{@sandbox.state_home}")
    end
  end
end
