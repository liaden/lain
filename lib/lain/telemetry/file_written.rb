# frozen_string_literal: true

module Lain
  module Telemetry
    # A file's identity just after a write, by a write tool or by a path a bash
    # command names as written (a redirect): which file (device and inode) and
    # which version of it (ctime). ctime rather than mtime because `touch -d`
    # sets mtime back, and no unprivileged process can set ctime.
    #
    # `path` is the resolved file, so a write through a symlink names the file
    # it landed in, which may differ from the path the read-set keys on.
    #
    # A write that fails after truncating leaves no record. The ctime rule
    # covers that gap: the truncation itself moved the file's ctime.
    #
    # Durable journal only; nothing on the display shows it.
    FileWritten = Data.define(:tool_use_id, :path, :device, :inode, :ctime) do
      include Journalable

      # @param tool_use_id [String, nil] the `tool_use` block that wrote
      # @param path [String] the resolved path of the file written
      # @param device [Integer]
      # @param inode [Integer]
      # @param ctime [Integer] nanoseconds since the epoch
      def initialize(tool_use_id:, path:, device:, inode:, ctime:)
        super(tool_use_id: tool_use_id&.to_s&.-@, path: -path.to_s, device:, inode:, ctime:)
      end

      # @param stat [File::Stat] the written file's, taken after the write
      # @param path [String] the resolved path of the file written
      # @param tool_use_id [String, nil] the `tool_use` block that wrote
      # @return [FileWritten]
      def self.from_stat(stat, path:, tool_use_id:)
        new(tool_use_id:, path:, device: stat.dev, inode: stat.ino,
            ctime: (stat.ctime.tv_sec * 1_000_000_000) + stat.ctime.tv_nsec)
      end
    end
  end
end
