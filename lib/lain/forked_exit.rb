# frozen_string_literal: true

module Lain
  # How a fork of a loaded lain leaves: by `exit!` whatever happens, so no at_exit hook of the
  # parent runs in it and the fork never returns into the parent's code. Its status is what a
  # spawned Ruby would have exited with: the command's own on SystemExit, 1 with the message
  # written for a crash, and death by the signal for a SignalException, so the parent reads a
  # killed child rather than a refusal.
  class ForkedExit
    # Every exception a spawned Ruby prints before exiting 1. An Exception subclass defined
    # outside core is not caught: it exits 1 with no message.
    CRASHES = [StandardError, ScriptError, NoMemoryError, SecurityError, SystemStackError].freeze

    # @param out [IO] the child's stdout, flushed before it leaves
    # @param err [IO] the child's stderr, where a crash is written
    def initialize(out:, err:)
      @out = out
      @err = err
    end

    # @yield the child's setup and its command; a normal return exits 0
    # @return [void] never returns
    def call(&block)
      status = 1
      begin
        status = status_of(&block)
      rescue SignalException => e
        signalled = e.signo
      ensure
        [@out, @err].each(&:flush)
        die_by(signalled) if signalled
        exit!(status)
      end
    end

    private

    def status_of
      yield
      0
    rescue SystemExit => e
      e.status
    rescue *CRASHES => e
      @err.write(e.full_message(highlight: false))
      1
    end

    # SYSTEM_DEFAULT, the kernel's action; Ruby's own "DEFAULT" for TERM raises again.
    def die_by(signo)
      Signal.trap(signo, "SYSTEM_DEFAULT")
      Process.kill(signo, Process.pid)
    rescue ArgumentError
      nil
    end
  end
end
