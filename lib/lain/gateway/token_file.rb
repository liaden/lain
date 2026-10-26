# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Lain
  module Gateway
    # Where a running gateway leaves its token for the chat on the same box: a
    # 0600 file named for its port, so the token never rides a command line,
    # where any process could read it and a lock's holder line would keep it.
    class TokenFile
      # The file is missing, or is not one only this user could have written.
      class Unusable < Lain::Error; end

      MISSING = "no gateway token at %<path>s; is `lain gateway` running on that port?"
      NOT_REGULAR = "the gateway token path %<path>s is not a regular file"
      FOREIGN = "the gateway token file %<path>s is owned by another user"
      LOOSE = "the gateway token file %<path>s must be mode 0600, not %<mode>04o"
      EMPTY = "the gateway token file %<path>s is empty"
      LINKED_DIR = "the gateway token file %<path>s sits in a directory that is a symlink"
      FOREIGN_DIR = "the gateway token file %<path>s sits in a directory owned by another user"
      LOOSE_DIR = "the gateway token file %<path>s sits in a directory writable by others"
      UNWRITABLE = "the gateway token file %<path>s cannot be written: %<reason>s"
      UNREADABLE = "the gateway token file %<path>s cannot be read: %<reason>s"
      # Opened without following a link and without waiting on a FIFO.
      READ_FLAGS = File::RDONLY | File::NOFOLLOW | File::NONBLOCK

      # @param port [Integer] the port the gateway listens on
      # @param paths [Paths] supplies the state home
      # @return [TokenFile]
      def self.for(port, paths: Paths.new) = new(File.join(paths.state_home, "gateway", "#{port}.token"))

      # @return [String]
      attr_reader :path

      # @param path [String]
      def initialize(path)
        @path = path
      end

      # Written whole beside the target and renamed over it, so a reader never
      # sees half a token.
      #
      # @param token [String]
      # @return [void]
      # @raise [Unusable] when the directory or the path is not this user's alone, or the write fails
      def write(token)
        prepare_directory
        refuse_occupied
        sweep_staged
        staged = "#{staged_prefix}#{SecureRandom.hex(8)}"
        File.open(staged, File::WRONLY | File::CREAT | File::EXCL, 0o600) { _1.write(token) }
        File.chmod(0o600, staged)
        File.rename(staged, @path)
      rescue SystemCallError => e
        raise Unusable, format(UNWRITABLE, path: @path, reason: Error.reason_of(e))
      ensure
        FileUtils.rm_f(staged) if staged
      end

      # Only the file holding this token, so a gateway since started on the
      # same port keeps its own.
      #
      # @param token [String]
      # @return [void]
      def remove(token)
        File.delete(@path) if File.lstat(@path).file? && File.read(@path) == token
      rescue Errno::ENOENT
        nil
      end

      # Checked on the open file itself, so the path cannot be swapped between
      # the check and the read.
      #
      # @return [String] the token
      # @raise [Unusable] for a missing, foreign, loose, linked or empty file, or a loose directory,
      #   naming the path and never the token
      def read
        refuse_directory(File.lstat(directory))
        File.open(@path, READ_FLAGS) { |file| checked(file).read.strip }
            .tap { raise Unusable, format(EMPTY, path: @path) if _1.empty? }
      rescue Errno::ENOENT
        raise Unusable, format(MISSING, path: @path)
      rescue Errno::ELOOP
        raise Unusable, format(NOT_REGULAR, path: @path)
      rescue SystemCallError => e
        raise Unusable, format(UNREADABLE, path: @path, reason: Error.reason_of(e))
      end

      private

      def directory = File.dirname(@path)

      def staged_prefix = File.join(directory, ".#{File.basename(@path)}.")

      def prepare_directory
        FileUtils.mkdir_p(directory, mode: 0o700)
        refuse_directory(File.lstat(directory))
        File.chmod(0o700, directory)
      end

      def refuse_directory(stat)
        raise Unusable, format(LINKED_DIR, path: @path) if stat.symlink?
        raise Unusable, format(FOREIGN_DIR, path: @path) unless stat.uid == Process.uid
        raise Unusable, format(LOOSE_DIR, path: @path) unless stat.mode.nobits?(0o022)
      end

      # A gateway killed mid-write leaves its staged file behind.
      def sweep_staged
        Dir.glob("#{staged_prefix}*").each do |stale|
          stat = File.lstat(stale)
          File.delete(stale) if stat.file? && stat.uid == Process.uid
        end
      end

      def refuse_occupied
        refuse(File.lstat(@path))
      rescue Errno::ENOENT
        nil
      end

      def checked(file)
        stat = file.stat
        refuse(stat)
        raise Unusable, format(LOOSE, path: @path, mode: stat.mode & 0o777) unless (stat.mode & 0o777) == 0o600

        file
      end

      def refuse(stat)
        raise Unusable, format(NOT_REGULAR, path: @path) unless stat.file?
        raise Unusable, format(FOREIGN, path: @path) unless stat.uid == Process.uid
      end
    end
  end
end
