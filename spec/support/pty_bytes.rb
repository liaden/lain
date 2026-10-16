# frozen_string_literal: true

# What a PTY's other end has written, read off the master. The kernel hands a
# write across from deferred work, so bytes written a moment ago may not be
# readable yet on a loaded box, and one `read_nonblock` saw half a sequence.
module PtyBytes
  CHUNK = 4096

  # Exactly `size` bytes, waiting for each to arrive.
  def pty_read(master, size, timeout: WaitUntil::DEFAULT_TIMEOUT)
    bytes = +""
    bytes << pty_more(master, size - bytes.bytesize, timeout, after: bytes) while bytes.bytesize < size
    bytes
  end

  # Everything written before the other end closed. Linux gives the master the
  # last of it before the EIO that says the slave is gone.
  def pty_drained(master, timeout: WaitUntil::DEFAULT_TIMEOUT)
    Enumerator.produce { pty_chunk(master, CHUNK, timeout) || raise(StopIteration) }.to_a.join
  end

  private

  def pty_more(master, size, timeout, after:)
    pty_chunk(master, size, timeout) || raise("the terminal closed after #{after.inspect}")
  end

  # nil once the other end has closed and everything it wrote has been read.
  def pty_chunk(master, size, timeout)
    raise "the terminal wrote nothing within #{timeout}s" unless master.wait_readable(timeout)

    master.readpartial(size)
  rescue Errno::EIO, EOFError
    nil
  end
end

RSpec.configure { |config| config.include(PtyBytes) }
