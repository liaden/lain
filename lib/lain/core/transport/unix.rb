# frozen_string_literal: true

require "socket"

module Lain
  module Core
    module Transport
      # Attaches to a daemon someone else started, such as the per-user
      # lain-daemon. It provisions no process, so {#stop} has nothing to end
      # and only reports; the client's own read-side collapse is what ends its reader.
      class Unix
        # Nothing listens at the path: no daemon was started, or it died.
        class Unreachable < Error
          def initialize(path, cause)
            super("no daemon listens at #{path}: #{cause.message}")
          end
        end

        # The socket's directory could let another local user stand in for the
        # daemon: whoever answers there is sent what this side publishes and is
        # believed in what it replies.
        class Untrusted < Error; end

        LINKED = "the socket directory %<dir>s is a symlink"
        FOREIGN = "the socket directory %<dir>s is owned by another user"
        IMPOSTOR = "the process at %<path>s is another user's (uid %<uid>d)"
        LOOSE = "the socket directory %<dir>s is open to others (mode %<mode>04o); it must be 0700"

        # @param path [String] the Unix socket the daemon listens on
        def initialize(path)
          @path = path
        end

        # @return [UNIXSocket] connected, ownership passing to the caller
        # @raise [Unreachable] naming the path when nothing accepts there
        # @raise [Untrusted] when the socket's directory is a symlink, another user's, or open to
        #   others, or another user's process answered
        def start
          trusted!(File.dirname(@path))
          ours!(UNIXSocket.new(@path))
        rescue SystemCallError => e
          raise Unreachable.new(@path, e)
        end

        # @return [String] the same description every time, since nothing was provisioned
        def stop = "detached from #{@path}"

        private

        # The directory check reads better, but the directory can be swapped
        # between it and the connect; the peer's credentials cannot.
        def ours!(socket)
          uid, = socket.getpeereid
          return socket if uid == Process.uid

          raise Untrusted, format(IMPOSTOR, path: @path, uid:)
        rescue StandardError
          socket.close
          raise
        end

        def trusted!(dir)
          stat = File.lstat(dir)
          raise Untrusted, format(LINKED, dir:) if stat.symlink?
          raise Untrusted, format(FOREIGN, dir:) unless stat.uid == Process.uid
          raise Untrusted, format(LOOSE, dir:, mode: stat.mode & 0o777) unless stat.mode.nobits?(0o077)
        end
      end
    end
  end
end
