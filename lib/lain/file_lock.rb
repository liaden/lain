# frozen_string_literal: true

module Lain
  # One path's cross-process flock, with the holder's pid and command written
  # into the file so a waiter can say who it is waiting on.
  #
  # POLLED, NOT BLOCKED. A blocking flock stalls the whole thread, reactor and
  # all, for as long as another process holds it; a non-blocking try with a
  # sleep between tries yields to the scheduler instead.
  #
  # Reentrancy is not promised: a second hold on the same path from the same
  # process waits on the first, because each opens its own file description.
  class FileLock
    # @param path [String] the lock file; created if absent
    # @param mode [Integer] the flock mode, without LOCK_NB
    # @param sleeper [#call] waits between tries while another process holds it
    # @param interval [Numeric] seconds between tries
    # @param patience [Numeric] seconds of waiting before the waiter is told who holds it
    # @param label [String] what the notice calls the lock
    def initialize(path, mode: File::LOCK_EX, sleeper: Kernel.method(:sleep), interval: 0.05, patience: 5,
                   label: "the lock")
      @path = path
      @label = label
      @mode = mode
      @sleeper = sleeper
      @interval = interval
      @told_after = [(patience / interval.to_f).ceil, 1].max
    end

    # @param notice [#call] told once, in words, who holds the lock when a wait outlasts the patience
    # @return the block's value
    def hold(notice: Isolation::ParentLock::Silent, &)
      opened do |file|
        waited(file, notice)
        held(file, &)
      end
    end

    # @return [Boolean] true after running the block; false, without running it, when another process holds the lock
    def try(&)
      opened do |file|
        locked = file.flock(@mode | File::LOCK_NB)
        held(file, &) if locked
        locked ? true : false
      end
    end

    # @return [String] the holder's pid and command, or "" when free
    def holder
      File.exist?(@path) ? File.read(@path).strip : ""
    end

    private

    # Closing the file on the way out, a cancel mid-sleep included, is what releases the flock.
    def opened
      file = open_file
      begin
        yield file
      ensure
        file.close
      end
    end

    # Only the open is rescued, so an error from the held block is never renamed.
    def open_file
      File.open(@path, File::RDWR | File::CREAT, 0o600)
    rescue SystemCallError => e
      raise Paths::Unwritable.new(@path, e)
    end

    def waited(file, notice)
      tries = 0
      until file.flock(@mode | File::LOCK_NB)
        notice.call(waiting_on) if (tries += 1) == @told_after
        @sleeper.call(@interval)
      end
    end

    # Shared holders must not overwrite one another's name, so only an exclusive one writes it.
    def held(file, &block)
      @mode == File::LOCK_EX ? claimed(file, &block) : yield
    end

    def claimed(file)
      file.truncate(0)
      file.write("pid=#{Process.pid} command=#{[$PROGRAM_NAME, *ARGV].join(" ")}\n")
      file.flush
      yield
    ensure
      file.truncate(0)
    end

    def waiting_on
      held = holder
      "waiting on #{held.empty? ? "a holder that has not named itself yet" : held} for #{@label} (#{@path})"
    end
  end
end
