# frozen_string_literal: true

module Lain
  module Frontend
    class InputPane
      # The pane's terminal with its line discipline off and its signals on,
      # for the length of a block: keys arrive as typed and unechoed, a Ctrl-C
      # still reaches the pane's trap without flushing the keys written beside
      # it, and a paste arrives bracketed, so its line ends are text. Linux's
      # `struct termios` by ioctl, as TCGETS and TCSETS move it: four flag
      # words and the line discipline, then the control characters. Anywhere
      # else the terminal stays as it was, cooked, and the pane cannot see a
      # draft.
      class Uncooked
        TCGETS = 0x5401
        TCSETS = 0x5402
        LFLAG_AT = 12
        ICANON = 0o2
        ECHO = 0o10
        NOFLSH = 0o200
        VTIME_AT = 17 + 5
        VMIN_AT = 17 + 6
        PASTE_ON = "\e[?2004h"
        PASTE_OFF = "\e[?2004l"

        # How often a wait looks at the mode again: a shell puts a stopped and
        # resumed job's terminal back cooked without a word to the job.
        RECHECK = 0.1

        # @param io [IO] the pane's keyboard, which is also its terminal
        def initialize(io) = @io = io

        # The mode found is put back as the block ends.
        #
        # @yieldparam terminal [Uncooked] this terminal, uncooked or not
        def around
          @before = termios
          @mine = @before && owned(@before)
          yield self
        ensure
          given_back if @mine
        end

        def uncooked? = !@mine.nil?

        # The terminal keeps unread keys when it raises a Ctrl-C, for the
        # length of the block: a draft typed in the write that carries the
        # interrupt is not lost. Left as found when it already does.
        #
        # Only the bit is given back, so a mode change made during the block
        # survives. SIGKILL and SIGTERM skip the restore, as they do for
        # {#around}; there is no trap.
        def keeping_keys
          set = (found = termios) && !flag?(found, NOFLSH) && written(with_flag(found, NOFLSH))
          yield
        ensure
          given_up_flush if set
        end

        # Each read off the terminal, until the task is stopped or the terminal dies.
        #
        # @yieldparam bytes [String] what one read found
        def reads
          loop do
            reclaimed
            read = waited && @io.read_nonblock(StdinPump::Typeahead::READ_LIMIT, exception: false)
            yield(read) if read.is_a?(String)
          end
        rescue IOError, SystemCallError
          nil
        end

        private

        # The io_uring selector fails a pending wait with EINVAL when the
        # terminal's mode changes under it, as a resumed job's does; the next
        # look takes the terminal back rather than leaving the pane deaf. The
        # pause keeps a failure that repeats from spinning.
        def waited
          @mine ? @io.wait_readable(RECHECK) : @io.wait_readable
        rescue Errno::EINVAL
          sleep(RECHECK)
          nil
        end

        def reclaimed
          now = termios
          @mine = owned(now) if @mine && now && now != @mine
        end

        def owned(found)
          set = with_flag(found, NOFLSH, clear: ICANON | ECHO)
          set.setbyte(VMIN_AT, 1)
          set.setbyte(VTIME_AT, 0)
          written(set).tap { |mine| told(PASTE_ON) if mine }
        end

        def with_flag(found, flag, clear: 0)
          found.dup.tap { |set| set[LFLAG_AT, 4] = [(set.unpack1("L<", offset: LFLAG_AT) & ~clear) | flag].pack("L<") }
        end

        def flag?(found, flag) = found.unpack1("L<", offset: LFLAG_AT).anybits?(flag)

        def given_up_flush
          now = termios
          written(with_flag(now, 0, clear: NOFLSH)) if now && flag?(now, NOFLSH)
        end

        def given_back
          written(@before)
          told(PASTE_OFF)
        end

        def termios
          return nil unless RUBY_PLATFORM.include?("linux") && @io.respond_to?(:ioctl)

          ("\0".b * 64).tap { |buffer| @io.ioctl(TCGETS, buffer) }
        rescue SystemCallError, IOError, NotImplementedError
          nil
        end

        # The mode as the kernel holds it once written, so a later look compares like with like.
        def written(set)
          @io.ioctl(TCSETS, set)
          termios
        rescue SystemCallError, IOError, NotImplementedError
          nil
        end

        # A terminal setting goes to the terminal, which the keyboard's descriptor also is.
        def told(setting)
          @terminal ||= IO.for_fd(@io.fileno, "w", autoclose: false)
          @terminal.write(setting)
          @terminal.flush
        rescue SystemCallError, IOError
          nil
        end
      end
    end
  end
end
