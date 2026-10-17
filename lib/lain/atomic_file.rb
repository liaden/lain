# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Lain
  # Write-then-rename, so a reader sharing the directory never opens half a file.
  #
  # The scratch name is unique per WRITER and not merely per process: subagents
  # run as threads over one process, and a name keyed on the pid alone is one
  # name for all of them, so the first rename would move the inode away from
  # the rest. The scratch is removed on every exit, so a full disk or a refused
  # rename leaves the target as it was and nothing beside it.
  module AtomicFile
    # @param path [String] the target; its parent directories are created
    # @param bytes [String]
    # @param mode [Integer, nil] applied to the file before it is renamed in; the umask-derived default when nil
    # @return [void]
    # @raise [SystemCallError] when the write or the rename is refused
    def self.write(path, bytes, mode: nil)
      FileUtils.mkdir_p(File.dirname(path))
      scratch = "#{path}.#{Process.pid}-#{SecureRandom.hex(8)}.partial"
      begin
        File.binwrite(scratch, bytes)
        File.chmod(mode, scratch) if mode
        File.rename(scratch, path)
      ensure
        FileUtils.rm_f(scratch)
      end
    end
  end
end
