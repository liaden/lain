# frozen_string_literal: true

require "io/console"
require "pty"
require_relative "../wait_until"

module E2E
  # `exe/lain chat` on a pseudo-terminal, driven the way a person types at it.
  class PlainChat
    include WaitUntil

    EXE = File.expand_path("../../../exe/lain", __dir__)
    BOOT_SECONDS = 30
    QUIT_SECONDS = 15

    attr_reader :pid, :session

    def self.start(sandbox, api_base, *flags)
      env = sandbox.env.merge("COLUMNS" => "200")
      reader, writer, pid = PTY.spawn(env, EXE, "chat", "--api-base", api_base, *flags,
                                      chdir: sandbox.project.to_s, unsetenv_others: true)
      sandbox.track(pid)
      new(reader, writer, pid, SessionFile.in(sandbox)).tap(&:await_prompt)
    end

    def initialize(reader, writer, pid, session)
      @reader = reader
      @writer = writer
      @pid = pid
      @session = session
      @seen = +""
    end

    def screen
      drain
      @seen.dup
    end

    def await_prompt(since: 0) = wait_for_screen("you>", since:)

    # A line is sent only once the terminal has echoed it, so an Enter can never overtake its text.
    def type(line)
      echo = line.b
      before = screen.scan(echo).size
      @writer.write(line)
      wait_until(timeout: 10, reason: "#{line.inspect} echoed") { screen.scan(echo).size > before }
      @writer.write("\r")
    end

    def answer(text)
      wait_for_screen(%r{\[y/N\]|human>}, since: screen.size)
      type(text)
    end

    def quit
      type("/quit")
      waiter = Thread.new { Process.wait2(pid).last }
      status = waiter.join(QUIT_SECONDS)&.value
      raise "the chat did not exit after /quit: #{screen.chars.last(300).join.inspect}" if status.nil?
      raise "chat exited #{status.inspect}" unless status.success?
    end

    private

    # A chat that exits before the pattern shows (a refused flag) will never print it, so waiting
    # out the clock would only hide the refusal behind a timeout.
    def wait_for_screen(pattern, since: 0)
      wait_until(timeout: BOOT_SECONDS, reason: "#{pattern.inspect} on the screen") do
        screen[since..].to_s.match?(pattern) || exited?
      end
      return if screen[since..].to_s.match?(pattern)

      raise "the chat exited #{@exit.inspect} before #{pattern.inspect}: #{screen.inspect}"
    end

    def exited?
      @exit ||= Process.wait2(pid, Process::WNOHANG)&.last
    rescue Errno::ECHILD
      true
    end

    def drain
      loop { @seen << @reader.read_nonblock(4096) }
    rescue IO::WaitReadable, EOFError, Errno::EIO
      nil
    end
  end
end
