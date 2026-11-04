# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Lain
  module Remote
    # The phones paired with the relay: one line per device, its name and the
    # blake3 digest of its token, in a 0600 file alone in a 0700 directory.
    # The relay may read anything in that directory, so nothing else lives
    # there, and it rereads the file when a pair or a revoke renames a new one in.
    class Devices
      # A pair or a revoke this file cannot take.
      class Refused < Lain::Error; end

      NAME = /\A[a-z0-9][a-z0-9_-]{0,31}\z/i
      BAD_NAME = "%<name>p is not a device name: up to 32 letters, digits, - and _, starting with a letter or digit"
      PAIRED = "%<name>s is already paired; revoke it first"
      UNPAIRED = "%<name>s is not paired"
      LINKED_DIR = "the devices directory %<path>s is a symlink"
      FOREIGN = "%<path>s is owned by another user"
      LOOSE_DIR = "the devices directory %<path>s is open to others"
      NOT_REGULAR = "the devices file %<path>s is not a regular file"
      LOOSE = "the devices file %<path>s must be mode 0600, not %<mode>04o"
      MALFORMED = "line %<line>d of the devices file %<path>s is not a device name and a token digest"
      LINE = /\A(?<name>\S+) (?<digest>\h{64})\z/
      TOKEN_BYTES = 32

      # @param paths [Paths] supplies the state home
      # @return [Devices]
      def self.for(paths: Paths.new) = new(File.join(paths.state_home, "remote", "devices"))

      # @return [String]
      attr_reader :path

      # @param path [String]
      def initialize(path)
        @path = path
      end

      # @param name [String]
      # @return [String] the device's new token, which is stored only as its digest
      # @raise [Refused] for a bad or already paired name, or a directory or file not this user's alone
      def pair(name)
        raise Refused, format(BAD_NAME, name:) unless NAME.match?(name)

        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        rewrite do |lines|
          raise Refused, format(PAIRED, name:) if lines.key?(name)

          lines.merge(name => Lain::Ext.blake3_hex(token))
        end
        token
      end

      # @param name [String]
      # @return [void]
      # @raise [Refused] for a name not paired, or a directory or file not this user's alone
      def revoke(name)
        rewrite do |lines|
          raise Refused, format(UNPAIRED, name:) unless lines.key?(name)

          lines.except(name)
        end
      end

      private

      def directory = File.dirname(@path)

      # Under a lock, so a pair and a revoke at once cannot lose either.
      def rewrite
        prepare_directory
        File.open(File.join(directory, ".devices.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          replace(yield(File.exist?(@path) ? entries : {}))
        end
      end

      def entries
        File.open(@path, File::RDONLY | File::NOFOLLOW) { |file| checked(file).read }
            .lines.each_with_index.to_h { |line, index| entry(line.chomp, index + 1) }
      end

      def entry(line, number)
        parts = LINE.match(line)
        raise Refused, format(MALFORMED, line: number, path: @path) unless parts

        [parts[:name], parts[:digest]]
      end

      # Staged beside the file under the dot prefix the relay allows, and
      # renamed over it, so the relay never reads half a file.
      def replace(lines)
        staged = File.join(directory, ".devices.#{SecureRandom.hex(8)}")
        File.open(staged, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(lines.map { |name, digest| "#{name} #{digest}\n" }.join)
        end
        File.rename(staged, @path)
      ensure
        FileUtils.rm_f(staged) if staged
      end

      def prepare_directory
        FileUtils.mkdir_p(directory, mode: 0o700)
        stat = File.lstat(directory)
        raise Refused, format(LINKED_DIR, path: directory) if stat.symlink?
        raise Refused, format(FOREIGN, path: directory) unless stat.uid == Process.uid
        raise Refused, format(LOOSE_DIR, path: directory) unless stat.mode.nobits?(0o077)
      end

      def checked(file)
        stat = file.stat
        raise Refused, format(NOT_REGULAR, path: @path) unless stat.file?
        raise Refused, format(FOREIGN, path: @path) unless stat.uid == Process.uid
        raise Refused, format(LOOSE, path: @path, mode: stat.mode & 0o777) unless (stat.mode & 0o777) == 0o600

        file
      end
    end
  end
end
