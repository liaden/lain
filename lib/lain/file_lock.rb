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
    # A lock file that exists and cannot be used.
    class Unreadable < Error
      def initialize(path, cause)
        super("cannot use the lock #{path}: #{Error.reason_of(cause)}")
      end
    end

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

    # A clean release truncates the file, so a line still there when the lock is
    # taken was written by a holder that died holding it.
    # @param notice [#call] told once, in words, who holds the lock when a wait outlasts the patience
    # @param reclaim [#call] given a dead holder's line once the lock is taken, before it is overwritten
    # @yieldparam note [#call] appends its text to this holder's line; each call
    #   rewrites the file, so it moves the mtime a reader may take as when the lock was taken
    # @return the block's value
    def hold(notice: Isolation::ParentLock::Silent, reclaim: Isolation::ParentLock::Silent, &)
      opened do |file|
        waited(file, notice)
        held(file, reclaim, &)
      end
    end

    # An exclusive try yields the same note as #hold, and overwrites a dead
    # holder's line without handing it to anyone.
    # @return [Boolean] true after running the block; false, without running it, when another process holds the lock
    def try(&)
      opened do |file|
        locked = file.flock(@mode | File::LOCK_NB)
        held(file, Isolation::ParentLock::Silent, &) if locked
        locked ? true : false
      end
    end

    # @return [String] the holder's pid and command, or "" when free
    # @raise [Unreadable] when the file exists and this user cannot read it
    def holder
      File.exist?(@path) ? Utf8.legible(File.binread(@path)).strip : ""
    rescue SystemCallError => e
      raise Unreadable.new(@path, e)
    end

    # Looks at the file's mode and never takes the lock, so a caller that must
    # not contend for it can still refuse a lock a drainer would die on.
    # @return [nil]
    # @raise [Unreadable] when the file exists and this user cannot write it
    def writable!
      return unless File.exist?(@path) && !File.writable?(@path)

      raise Unreadable.new(@path, Errno::EACCES.new)
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
    def held(file, reclaim, &block)
      @mode == File::LOCK_EX ? claimed(file, reclaim, &block) : yield(Isolation::ParentLock::Silent)
    end

    # Reclaim runs outside the ensure, so a reclaim that raises leaves the dead line for the next taker.
    def claimed(file, reclaim)
      previous = Utf8.legible(file.read).lines.first.to_s.strip
      reclaim.call(previous) unless previous.empty?
      begin
        line = "pid=#{Process.pid} command=#{[$PROGRAM_NAME, *ARGV].join(" ")}"
        named(file, line)
        yield ->(text) { named(file, line = "#{line} #{text}") }
      ensure
        file.truncate(0)
      end
    end

    # Written over the old line before the tail is cut, so neither a reader nor
    # a kill between the two calls ever finds the file empty.
    def named(file, line)
      bytes = "#{line}\n".b
      file.pwrite(bytes, 0)
      file.truncate(bytes.bytesize)
      nil
    end

    def waiting_on
      held = holder
      "waiting on #{held.empty? ? "a holder that has not named itself yet" : held} for #{@label} (#{@path})"
    end
  end
end
