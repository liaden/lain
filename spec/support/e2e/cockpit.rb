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
    HANGUP_GRACE_SECONDS = 2
    APPROVAL_BUFFER = "lain://approval"
    INBOX_BUFFER = "lain://inbox"
    ROWS = 24
    COLUMNS = 220
    PANES = { chat: Lain::CLI::Up::Panes::CHAT, input: Lain::CLI::Up::Panes::INPUT,
              editor: Lain::CLI::Up::Panes::EDITOR }.freeze

    attr_reader :session

    # A tmux server's socket lives under the sandbox's TMPDIR, so the name only has to be unique
    # among cockpits that share a sandbox.
    # The default is a terminal's own: the input pane collapsed at every height below 50, so a
    # taller cockpit could not show it.
    def self.start(sandbox, upstream, *chat_flags, rows: ROWS, boot_seconds: BOOT_SECONDS)
      new(sandbox, "lain-e2e-#{SecureRandom.hex(4)}").tap do |cockpit|
        cockpit.launch(upstream.url, chat_flags, rows, boot_seconds)
      end
    end

    # The project key is lain's own, so the paths below are the ones the binary writes even when
    # several projects share the sandbox's XDG tree.
    def initialize(sandbox, socket)
      @sandbox = sandbox
      @socket = socket
      @paths = Lain::Paths.new(env: sandbox.env)
      @key = @paths.project_hash(sandbox.project.to_s)
      @session = SessionFile.new(sandbox.state_home, project_key: @key)
    end

    def launch(api_base, chat_flags, rows, boot_seconds = BOOT_SECONDS)
      @reader, @writer, @pid = PTY.spawn(@sandbox.env, EXE, "up", "--session", SESSION, "--socket", @socket,
                                         @sandbox.project.to_s, "--", *chat_flags, "--api-base", api_base,
                                         chdir: @sandbox.project.to_s, unsetenv_others: true)
      @writer.winsize = [rows, COLUMNS]
      @sandbox.track(@pid)
      @drain = drain(@reader)
      await_prompt(boot_seconds)
    rescue StandardError => e
      raise "#{e.message}\neditor pane:\n#{abandon}"
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

    # The question is named by its row in the listing, because :LainReply answers the set under the cursor.
    def reply(text, question = 1)
      window = await_inbox_window
      editor.call_function("win_gotoid", [window])
      editor.command(question.to_s)
      editor.command("LainReply #{text}")
    end

    # Only the descriptors are guaranteed to close; a step that raises skips the ones after it and
    # leaves the processes to the sandbox's reaper.
    def stop
      return if @stopped

      @stopped = true
      @editor&.shutdown
      tmux("kill-server")
      await_client
      await_processes_gone
    ensure
      close_terminal
    end

    private

    # A process that ignores the server's hangup (an editor that is not running) is killed after a
    # short grace, so a journey that already failed is not held past its budget.
    def await_processes_gone
      wait_until(timeout: HANGUP_GRACE_SECONDS, reason: "the cockpit's processes gone") { processes_gone? }
    rescue RuntimeError
      own_processes.each do |pid|
        Process.kill("KILL", pid)
      rescue StandardError
        nil
      end
      wait_until(timeout: STOP_SECONDS, reason: "the cockpit's processes gone") { processes_gone? }
    end

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

    def await_inbox_window
      window = 0
      wait_until(timeout: BOOT_SECONDS, reason: "#{INBOX_BUFFER} in a window listing a question") do
        window = inbox_window
        window.positive? && inbox_lists_question?
      end
      window
    end

    # The buffer is created by its first rendering and may sit in no window until a gesture shows it.
    def inbox_window
      return 0 unless editor.evaluate("bufexists('#{INBOX_BUFFER}')").to_i.positive?

      editor.command("sbuffer #{INBOX_BUFFER}") if editor.evaluate("bufwinid('#{INBOX_BUFFER}')").to_i.negative?
      editor.evaluate("bufwinid('#{INBOX_BUFFER}')").to_i
    end

    def inbox_lists_question?
      editor.evaluate("getbufline('#{INBOX_BUFFER}', 1, '$')") != Lain::Frontend::Neovim::InboxView::EMPTY
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

    # What a launch that never reached its prompt leaves to read, taken before its processes go.
    def abandon
      capture(:editor).tap { stop_quietly }
    end

    # The launch's own failure is the one worth reporting; the reaper still names anything left behind.
    def stop_quietly
      stop
    rescue StandardError
      nil
    end

    def await_prompt(boot_seconds)
      wait_until(timeout: boot_seconds, reason: "a you> line in the input pane") do
        !tmux("show-options", "-v", "-t", SESSION, PANES.fetch(:input)).empty? && capture(:input).include?("you>")
      end
    end

    def pane(name) = tmux("show-options", "-v", "-t", SESSION, PANES.fetch(name))

    # The sandbox's environment, because tmux finds its server through TMPDIR.
    def tmux(*)
      Open3.capture3(@sandbox.env, "tmux", "-L", @socket, *, unsetenv_others: true).first.strip
    end

    def processes_gone? = own_processes.empty?

    def own_processes
      Dir.glob("/proc/[0-9]*/cmdline").filter_map do |file|
        file[/\d+/].to_i if File.read(file).then { |text| text.include?(@socket) || text.include?(@key) }
      rescue SystemCallError
        nil
      end
    end

    def editor_socket
      path = File.join(@paths.runtime_dir, "nvim-#{@key}.sock")
      wait_until(timeout: BOOT_SECONDS, reason: "an nvim socket") { File.exist?(path) }
      path
    end

    def state_path = Lain::ProjectDir.new(root: @sandbox.project.to_s, paths: @paths).state_path
  end
end
